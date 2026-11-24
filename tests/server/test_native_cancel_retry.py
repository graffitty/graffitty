# /// script
# requires-python = ">=3.11"
# dependencies = ["websocket-client"]
# ///
"""A real owner retries the original Codex submission after a conversation switch."""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/support"))
from e2e_server import PrivateServer
from test_session_transfer import Peer


def write_json(path, value):
    staged = path.with_suffix(".next")
    staged.write_text(json.dumps(value))
    staged.replace(path)


def worker(folder, request):
    """Model two native queues and enforce the provider's current-thread check."""
    active = json.loads((folder / "active").read_text())
    op = request["op"]
    if op == "scan":
        sample = folder / "scan"
        result = json.loads(sample.read_text()) if sample.exists() else {}
        for node in result.values():
            if node["pid"] == 202:
                node["session_id"] = active
    elif op == "codex_completion":
        result = {"turn_id":"turn","completion_checkpoint":70,"size":70,"last_message":"Queued answer"}
    elif op == "codex_queue":
        submission = "submission-" + request["event_id"]
        write_json(folder / "A", [submission])
        result = {"queuedSubmission":{"id":submission}}
    elif op in ("codex_queue_status", "codex_cancel"):
        if request["target"]["session_id"] != active:
            result = {"error":{"message":"Codex frontend thread binding changed"}}
        else:
            queue = folder / active
            entries = json.loads(queue.read_text())
            if op == "codex_queue_status":
                result = {"queued_ids":entries}
            else:
                submission = request["submission_id"]
                result = {"deleted":submission in entries}
                write_json(queue, [item for item in entries if item != submission])
    else:
        result = {}
    with (folder / "operations").open("a") as log:
        log.write(json.dumps({"request":request,"active":active,"result":result}) + "\n")
    print(json.dumps(result))


@unittest.skipUnless(os.name == "posix", "Private PTYs and executable worker fixture")
class NativeCancelRetryTests(unittest.TestCase):
    def test_cancel_only_original_submission_after_receiver_returns(self):
        def wait(check, description):
            deadline = time.monotonic() + 25
            while time.monotonic() < deadline:
                if value := check():
                    return value
                time.sleep(.05)
            self.fail(f"Timed out waiting for {description}")

        with tempfile.TemporaryDirectory(prefix="gft-native-") as tmp:
            folder = Path(tmp)
            binary = Path(os.environ.get("GRAFFITTY_TEST_SERVER", ROOT / "target/debug/gft")).resolve()
            private_cli = folder / "gft"
            shutil.copy2(binary, private_cli)
            env = {k:v for k,v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
            for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
                env[f"XDG_{kind}_HOME"] = str(folder / kind.lower())
            write_json(folder / "active", "A")
            with patch.dict(os.environ, GRAFFITTY_TEST_SERVER=str(private_cli)), PrivateServer(env,folder,"/bin/sh") as owner:
                peer = Peer(json.loads(owner.descriptor.read_text())["local"], "retry", new=True)
                try:
                    source = peer.topology["panes"][0]["id"]
                    target = peer.action("create", source, kind="pane")["created"]
                    # The owner uses its own executable path to start provider workers.
                    # Replace only the private path, once the real owner and PTYs are up.
                    shim = folder / "worker-launcher"
                    shim.write_text("#!/bin/sh\n" +
                        'if [ "$1" = internal ] && [ "$2" = agent-worker ]; then\n' +
                        "exec " + shlex.join([sys.executable, str(Path(__file__).resolve()), "--worker", str(folder)]) + ' "$@"\nfi\n' +
                        "exec " + shlex.quote(str(binary)) + ' "$@"\n')
                    shim.chmod(0o755)
                    shim.replace(private_cli)

                    def operations(name):
                        return [row for line in (folder / "operations").read_text().splitlines()
                                if (row := json.loads(line))["request"]["op"] == name]

                    sample = {
                        f"t{source}":{"provider":"codex","pid":201,"started":"source","session_id":"source",
                                      "transcript_path":str(folder / "turn.jsonl"),"status":"busy",
                                      "observed_turn":{"id":"turn","status":"inProgress"}},
                        f"t{target}":{"provider":"codex","pid":202,"started":"target","session_id":"A","status":"idle"},
                    }
                    write_json(folder / "scan", sample)

                    def has_target(session):
                        return any(row["node"] == f"t{target}" and row.get("session_id") == session
                                   for row in peer.sync()["graph"]["nodes"])

                    wait(lambda: has_target("A"), "first conversation")
                    linked = peer.action("rpc",source,method="graph.connect",
                                         params={"from":f"t{source}","to":f"t{target}","turn_completed":True})
                    self.assertEqual(linked["type"],"ack",linked)
                    turn = {"id":"turn","status":"completed","completion_checkpoint":70}
                    sample[f"t{source}"].update(status="idle",observed_turn=turn,turn_outcomes=[turn])
                    write_json(folder / "scan", sample)
                    wait(lambda: operations("codex_queue_status"), "accepted submission in A")
                    queued, = operations("codex_queue")
                    submission = queued["result"]["queuedSubmission"]["id"]
                    event = queued["request"]["event_id"]
                    self.assertEqual(queued["request"]["target"]["session_id"], "A")
                    self.assertIn("Queued answer", queued["request"]["text"])
                    # Even a provider ID collision in B must leave its entry alone.
                    write_json(folder / "B", [submission])
                    write_json(folder / "active", "B")
                    wait(lambda: has_target("B"), "replacement conversation")
                    rejected = wait(lambda: [row for row in operations("codex_cancel") if row["active"] == "B"],
                                    "provider rejection while B is active")
                    self.assertIn("error", rejected[0]["result"])
                    self.assertEqual(json.loads((folder / "A").read_text()), [submission])
                    write_json(folder / "active", "A")
                    wait(lambda: has_target("A"), "restored original conversation")
                    wait(lambda: any(row["event_id"] == event and row["status"] == "cancelled in Codex"
                                     for row in peer.sync()["graph"]["receipts"]), "confirmed cancellation in A")
                    scans = len(operations("scan"))
                    wait(lambda: len(operations("scan")) >= scans + 2, "two polls after cancellation")
                    cancels = operations("codex_cancel")
                    self.assertTrue(all(row["request"]["submission_id"] == submission and
                                        row["request"]["target"]["session_id"] == "A" for row in cancels))
                    self.assertEqual([row["result"] for row in cancels if row["active"] == "A"], [{"deleted":True}])
                    self.assertEqual(len(operations("codex_queue")), 1)
                    self.assertEqual(json.loads((folder / "A").read_text()), [])
                    self.assertEqual(json.loads((folder / "B").read_text()), [submission])
                finally:
                    peer.socket.close()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--worker"]:
        worker(Path(sys.argv[2]), json.loads(Path(sys.argv[-1]).read_text()))
    else:
        unittest.main()
