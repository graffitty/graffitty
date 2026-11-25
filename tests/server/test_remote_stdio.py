"""Exercise GUI tunnel ownership with an isolated fake OpenSSH executable."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(os.name == "nt", "Executable script fixture uses a Unix shebang")
class StdioTunnelTests(unittest.TestCase):
    def test_pipe_close_reaps_tunnel_and_prompts_request_terminal(self):
        with tempfile.TemporaryDirectory(prefix="gft-stdio-") as tmp:
            directory = Path(tmp)
            ssh = directory / "ssh"
            ssh.write_text("""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
assert 'BatchMode=yes' in args and 'StrictHostKeyChecking=yes' in args
if os.environ.get('FIXTURE_AUTH_FAIL'):
    sys.exit(255)
if '-N' in args:
    Path(os.environ['FIXTURE_PID']).write_text(str(os.getpid()))
    while True: time.sleep(.05)
command = args[-1]
if command == 'exit 0': pass
elif command == 'uname -s; uname -m': print('Linux\\nx86_64')
elif '--ssh-attach' in command:
    print(json.dumps({'url':'ws://127.0.0.1:12345','protocol':1,'token':'fixture'}))
else: print('installed\\n/fixture/gft')
""")
            ssh.chmod(0o700)
            env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'],
                       FIXTURE_PID=str(directory / "pid"))
            command = [str(ROOT / "target/debug/gft"), "remote", "connect", "--stdio", "fixture"]
            process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(selector.select(10), "CLI did not return a handshake")
                packet = json.loads(process.stdout.readline())
                self.assertEqual(packet['connections'][0]['credential_id'], 'ssh:fixture')
                deadline = time.monotonic() + 5
                while not (directory / 'pid').exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.01)
                pid = int((directory / 'pid').read_text())
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
                with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
            finally:
                if not process.stdin.closed: process.stdin.close()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                process.stdout.close()
                process.stderr.close()
            failed = subprocess.run(command, env=dict(env, FIXTURE_AUTH_FAIL='1'),
                                    input='', capture_output=True, text=True, timeout=5)
            self.assertEqual(failed.returncode, 77)
            self.assertEqual(failed.stdout, '')


if __name__ == '__main__':
    unittest.main()
