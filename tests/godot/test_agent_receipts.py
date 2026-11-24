"""Two independent Godot clients share real server receipts over encrypted sockets."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "tests/server"), str(ROOT / "tools")]
from test_terminal_scene import Owner
from check_godot import failed


class Client:
    def __init__(self, owner, name):
        self.path = owner.path / name
        self.path.mkdir()
        self.control = {}
        env = {k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(self.path / kind.lower())
        env["GRAFFITTY_TEST_PEER_DIRECTORY"] = str(self.path)
        env["GRAFFITTY_TEST_REMOTE_DESCRIPTOR"] = str(owner.descriptor)
        self.log = (self.path / "client.log").open("w")
        self.process = subprocess.Popen(
            ["godot", "--headless", "--path", str(ROOT / "frontends/godot/project"),
             "--script", "res://tests/agent_receipts_peer.gd"],
            env=env, stdout=self.log, stderr=subprocess.STDOUT,
        )

    def command(self, **values):
        self.control.update(values)
        source = self.path / "control.tmp"
        source.write_text(json.dumps(self.control))
        source.replace(self.path / "control.json")

    def state(self):
        path = self.path / "state.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def until(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.process.poll() is None:
            state = self.state()
            if predicate(state):
                return state
            time.sleep(.025)
        raise AssertionError(f"Client did not reach expected state: {self.state()}\n{self.output()}")

    def output(self):
        return (self.path / "client.log").read_text()

    def close(self):
        self.command(stop=True, release=True)
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        self.log.close()


@unittest.skipUnless(shutil.which("godot"), "Godot is required")
class AgentReceiptTests(unittest.TestCase):
    def test_panning_to_offscreen_completion_acknowledges_only_when_it_enters_view(self):
        with (
            tempfile.TemporaryDirectory(prefix="gft-pan-", dir="/tmp" if os.name == "posix" else None) as scratch,
            patch.dict(os.environ, {"GRAFFITTY_SCENE_EVIDENCE": scratch}),
            Owner(network=True) as owner,
        ):
            client = Client(owner, "viewer")
            try:
                client.until(lambda state: state.get("connected") and state.get("presented"))
                client.command(viewed=True, pan_away=True)
                client.until(lambda state: state.get("control", {}).get("pan_away") and not state["presented"])
                owner.output(b"\x1b]7501;state=working:app=pi\x07")
                client.until(lambda state: state.get("status") == "working")
                owner.output(b"\x1b]7501;state=idle:app=pi\x07")
                unseen = client.until(lambda state: state.get("marker") == "completed"
                    and state.get("status") == "done" and state.get("projected_event")
                    and (state.get("attention") or {}).get("event") == state["projected_event"])
                self.assertFalse(unseen["attention"]["seen"])
                self.assertEqual(unseen["sent"], [])
                event = unseen["attention"]["event"]
                client.command(pan_away=False)
                client.until(lambda state: state["presented"] and event in state["sent"] and
                             state["attention"]["seen"] and state["marker"] == "" and state["status"] == "idle")
            finally:
                client.close()

    def test_osc_clear_preserves_a_read_until_the_interrupted_receipt_retries(self):
        with (
            tempfile.TemporaryDirectory(prefix="gft-osc-", dir="/tmp" if os.name == "posix" else None) as scratch,
            patch.dict(os.environ, {"GRAFFITTY_SCENE_EVIDENCE": scratch}),
            Owner(network=True) as owner,
        ):
            clients = []
            try:
                for name in ("viewer", "observer"):
                    clients.append(Client(owner, name))
                    clients[-1].until(lambda state: state.get("connected") and state.get("presented"))
                viewer, observer = clients

                def report(state):
                    owner.output(f"\x1b]7501;state={state}:app=pi\x07".encode())

                report("working")
                viewer.until(lambda state: state.get("status") == "working")
                report("idle")
                completion = viewer.until(lambda state: state.get("marker") == "completed"
                    and (state.get("attention") or {}).get("event"))
                event = completion["attention"]["event"]

                def catalog_row(state):
                    return next((row for session in state.get("sessions", []) for row in session["agents"]
                                 if (row.get("attention") or {}).get("event") == event), {})

                viewer.command(viewed=True, hold=True)
                viewer.until(lambda state: event in state.get("held", []))
                viewer.command(viewed=False)
                viewer.until(lambda state: state.get("control", {}).get("viewed") is False)
                report("clear")
                for client in clients:
                    state = client.until(lambda state: bool(catalog_row(state)) and catalog_row(state)["program"] is None
                        and (state.get("attention") or {}).get("event") == event)
                    self.assertFalse(state["attention"]["seen"])
                    self.assertEqual(state["marker"], "completed" if client is observer else "")

                viewer.command(release=True, hold=False, reject_held=True)
                viewer.until(lambda state: event in state.get("rejected", []))
                report("idle")
                for client in clients:
                    state = client.until(lambda state: (catalog_row(state).get("program") or {}).get("state") == "idle"
                        and catalog_row(state)["attention"]["seen"] and (state.get("attention") or {}).get("seen"))
                    self.assertEqual(state["attention"]["event"], event)
                    self.assertEqual(state["marker"], "")
                self.assertIn(event, viewer.state()["sent"])
            finally:
                for client in clients:
                    client.close()
            for client in clients:
                self.assertFalse(failed(client.process.returncode, client.output()), client.output())

    def test_mobile_read_clears_desktop_and_stale_receipt_keeps_new_completion(self):
        # Owner and both clients have independent storage; no installed app or
        # user server is touched. OSC exercises an agent without provider hooks.
        # Keep private Unix socket paths within macOS's length limit.
        with (
            tempfile.TemporaryDirectory(prefix="gft-seen-", dir="/tmp" if os.name == "posix" else None) as scratch,
            patch.dict(os.environ, {"GRAFFITTY_SCENE_EVIDENCE": os.environ.get("GRAFFITTY_SCENE_EVIDENCE", scratch)}),
            Owner(network=True) as owner,
        ):
            clients = []
            try:
                desktop = Client(owner, "desktop")
                clients.append(desktop)
                phone = Client(owner, "phone")
                clients.append(phone)
                for client in clients:
                    client.until(lambda s: s.get("connected"))

                def report(word):
                    owner.output(f"\x1b]7501;state={word}:app=pi\x07".encode())

                def finish_turn():
                    report("working")
                    for client in clients:
                        client.until(lambda s: s.get("status") == "working")
                    report("idle")
                    # The panel may already show the catalog completion while its
                    # independently delivered graph still holds the previous turn.
                    states = [client.until(lambda s: s.get("status") == "done" and s.get("projected_event")
                        and (s.get("attention") or {}).get("event") == s["projected_event"]) for client in clients]
                    self.assertEqual(states[0]["attention"], states[1]["attention"])
                    for state in states:
                        self.assertEqual(state["marker"], "completed")
                        self.assertEqual(state["provider"], "shell")
                    return states[0]["attention"]["event"]

                first = finish_turn()
                phone.command(viewed=True)
                for client in clients:
                    state = client.until(lambda s: (s.get("attention") or {}).get("seen") is True)
                    self.assertEqual(state["status"], "idle")
                    self.assertEqual(state["marker"], "")
                    self.assertEqual(state["attention"]["event"], first)
                    # The catalog is a separate message and may follow the graph.
                    client.until(lambda s: any((a.get("attention") or {}).get("seen") is True
                        for session in s.get("sessions", []) for a in session.get("agents", [])))

                phone.command(viewed=False, hold=True)
                phone.until(lambda s: s.get("control", {}).get("hold") is True)
                previous = finish_turn()
                phone.command(viewed=True)
                phone.until(lambda s: previous in s.get("held", []))
                self.assertFalse(desktop.state()["attention"]["seen"])
                phone.command(viewed=False)
                phone.until(lambda s: s.get("control", {}).get("viewed") is False)
                latest = finish_turn()
                self.assertNotEqual(previous, latest)
                phone.command(release=True, hold=False)
                phone.until(lambda s: previous in s.get("sent", []))
                # The real server acknowledged the stale receipt. Repeating an
                # unchanged OSC report must not recreate the current event.
                report("idle")
                for client in clients:
                    state = client.state()
                    self.assertEqual(state["attention"], {"event": latest, "kind": "completed", "seen": False})
                    self.assertEqual(state["status"], "done")
                    self.assertEqual(state["marker"], "completed")
                phone.command(viewed=True)
                desktop.until(lambda s: (s.get("attention") or {}).get("seen") is True)

                # Losing a receipt and leaving its session must not lose the
                # read. Retry using catalog evidence while viewing another one.
                phone.command(viewed=False, hold=True, release=False)
                phone.until(lambda s: s.get("control", {}).get("release") is False)
                queued = finish_turn()
                old_workspace = phone.state()["workspace"]
                phone.command(viewed=True)
                phone.until(lambda s: queued in s.get("held", []))
                phone.command(viewed=False, create_session=True)
                phone.until(lambda s: s.get("workspace") not in (None, "", old_workspace))
                phone.command(hold=False, release=True, reject_held=True)
                phone.until(lambda s: queued in s.get("rejected", []))
                phone.until(lambda s: queued in s.get("sent", []))
                state = desktop.until(lambda s: (s.get("attention") or {}).get("seen") is True)
                self.assertEqual(state["attention"]["event"], queued)
                self.assertEqual(state["status"], "idle")
                self.assertEqual(state["marker"], "")
                self.assertNotEqual(phone.state()["workspace"], old_workspace)
                # A fresh process also sees the server's read state immediately.
                newcomer = Client(owner, "reconnected")
                clients.append(newcomer)
                state = newcomer.until(lambda s: (s.get("attention") or {}).get("seen") is True)
                self.assertEqual(state["status"], "idle")
                self.assertEqual(state["marker"], "")
            finally:
                for client in clients:
                    client.close()
            for client in clients:
                self.assertFalse(failed(client.process.returncode, client.output()), client.output())


if __name__ == "__main__":
    unittest.main()
