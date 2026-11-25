# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""CLI uploads publish acknowledged progress to an attached private frontend."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from private_session_e2e import PrivateClient

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get("GRAFFITTY_TEST_BINARY", ROOT / "target/debug/gft"))


class Observer(PrivateClient):
    def __init__(self, *args, **kwargs):
        self.progress = []
        super().__init__(*args, **kwargs)

    def track(self, message):
        super().track(message)
        if message.get("type") == "notification" and "upload" in message:
            self.progress.append(message["upload"])


def main():
    with tempfile.TemporaryDirectory(prefix="gft-up-") as directory:
        root = Path(directory)
        descriptor_path = root / "server.json"
        env = dict({k: v for k, v in os.environ.items() if not k.startswith("GRAFFITTY_")}, GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor_path),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"))
        with (root / "server.log").open("w") as log:
            server = subprocess.Popen([str(BINARY), "server", "--connection", str(descriptor_path),
                                       "--auth-file", str(root / "auth.json"), "--shell", "/bin/sh"],
                                      env=env, stdout=log, stderr=log)
        observer = None
        try:
            for _ in range(200):
                if descriptor_path.exists(): break
                assert server.poll() is None, (root / "server.log").read_text()
                time.sleep(.05)
            descriptor = json.loads(descriptor_path.read_text())
            observer = Observer(descriptor["local"])
            pane = observer.topology["panes"][0]["id"]
            for size in [512 * 1024 + 7, 0]:
                fixture = root / f"fixture-{size}.bin"
                data = bytes(range(256)) * (size // 256) + bytes(range(size % 256))
                fixture.write_bytes(data)
                result = subprocess.run([str(BINARY), "terminal", "put", "-t", f"t{pane}",
                                         "--json", str(fixture)], env=env, capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, result.stderr
                assert Path(json.loads(result.stdout)["path"]).read_bytes() == data
                observer.until(lambda m: m.get("upload", {}).get("name") == fixture.name
                               and m["upload"]["state"] == "complete")
                events = [e for e in observer.progress if e["name"] == fixture.name]
                assert len({e["id"] for e in events}) == 1
                assert [e["received"] for e in events] == sorted(e["received"] for e in events)
                assert all(e["total"] == size for e in events)
                assert events[-1]["received"] == size and events[-1]["state"] == "complete"
                if size: assert any(e["state"] == "receiving" for e in events)
                print(f"PASS CLI {size}-byte upload: exact file, stable ID, acknowledged progress and completion")
            upload = dict(id=str(uuid.uuid4()), name="interrupted.bin", size=2, offset=0,
                          data=base64.b64encode(b"a").decode(), paste=False)
            assert observer.action("rpc", pane, method="terminal.put", params={"upload": upload})["type"] == "ack"
            upload["offset"] = 2
            assert observer.action("rpc", pane, method="terminal.put", params={"upload": upload})["type"] == "error"
            observer.until(lambda m: m.get("upload", {}).get("id") == upload["id"]
                           and m["upload"]["state"] == "failed")
            print("PASS interrupted upload publishes failure")
        except Exception:
            print((root / "server.log").read_text(), file=sys.stderr)
            raise
        finally:
            if observer: observer.socket.close()
            # This process is the disposable server created above, never the user's server.
            server.terminate()
            server.wait(timeout=15)


if __name__ == "__main__":
    main()
