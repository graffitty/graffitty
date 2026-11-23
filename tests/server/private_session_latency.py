"""Measure a key through a private server to its committed echo on a real PTY.

Run GRAFFITTY_TEST_SERVER=/path/to/gft python3 tests/server/private_session_latency.py.
Use the same build profile and host load for both runs.
"""
import json
import os
from pathlib import Path
import pty
import select
import statistics
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from e2e_server import PrivateServer
from local_media_e2e import LocalClient


def summary(samples):
    ordered = sorted(samples)
    return dict(median_ms=round(statistics.median(samples), 3),
                p95_ms=round(ordered[(95 * len(samples) + 99) // 100 - 1], 3),
                max_ms=round(max(samples), 3), samples=len(samples))


def direct_latency(echo, env):
    master, slave = pty.openpty()
    try:
        with subprocess.Popen([echo], stdin=slave, stdout=slave, stderr=slave, env=env) as child:
            try:
                def receive(marker):
                    output = b""
                    while marker not in output:
                        assert select.select([master], [], [], 5)[0], "Direct PTY timed out"
                        output += os.read(master, 4096)

                receive(b"READY")
                samples = []
                for i in range(220):
                    start = time.perf_counter_ns()
                    os.write(master, b"k")
                    receive(f"E{i:04}K".encode())
                    if i >= 20:
                        samples.append((time.perf_counter_ns() - start) / 1e6)
                return summary(samples)
            finally:
                child.terminate()
    finally:
        os.close(slave)
        os.close(master)


def main():
    with tempfile.TemporaryDirectory(prefix="gr-latency-", dir="/tmp") as directory:
        root = Path(directory)
        echo = root / "echo.py"
        echo.write_text(f"#!{sys.executable}\n"
                        "import os, tty\n"
                        "tty.setraw(0)\n"
                        "os.write(1, b'READY')\n"
                        "i = 0\n"
                        "while os.read(0, 1):\n"
                        "    os.write(1, f'\\r\\nE{i:04}K'.encode())\n"
                        "    i += 1\n")
        echo.chmod(0o700)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "XDG_"))}
        env.update(HOME=directory, CODEX_HOME=str(root/"codex"), CLAUDE_CONFIG_DIR=str(root/"claude"))
        for kind in ("CONFIG", "STATE", "DATA", "CACHE"):
            env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        direct = direct_latency(echo, env)
        with PrivateServer(env, root, str(echo)) as owner:
            client = LocalClient(json.loads(owner.descriptor.read_text()))
            try:
                pane = client.topology["panes"][0]
                client.subscribe(pane["id"])
                client.until(lambda: b"READY" in client.terminal_bytes(pane["id"]))
                header = json.dumps(dict(type="input", session=pane["id"])).encode()
                data = b"GRT2" + struct.pack("<I", len(header)) + header + b"k"
                frame = struct.pack("<BI", 2, len(data)) + data
                host_pids = subprocess.check_output(["ps", "-A", "-o", "pid="]).split()
                samples = []
                for i in range(220):
                    marker = f"E{i:04}K".encode()
                    start = time.perf_counter_ns()
                    client.socket.sendall(frame)
                    client.until(lambda: marker in client.terminal_bytes(pane["id"]))
                    if i >= 20:
                        samples.append((time.perf_counter_ns() - start) / 1e6)
                    time.sleep(.03)
                request = root / "scan.json"
                request.write_text(json.dumps(dict(op="scan", roots=[dict(node="%1", pid=pane["pid"])])))
                scans = []
                for i in range(22):
                    start = time.perf_counter_ns()
                    result = subprocess.check_output([owner.binary, "internal", "agent-worker",
                                                      "--request", request], env=env)
                    elapsed = (time.perf_counter_ns() - start) / 1e6
                    assert json.loads(result) == {}, result
                    if i >= 2:
                        scans.append(elapsed)
                print(json.dumps(dict(process_count=len(host_pids), direct_pty=direct, private_core=summary(samples),
                                      scan_with_launch=summary(scans)), indent=2))
            finally:
                client.close()


if __name__ == "__main__":
    main()
