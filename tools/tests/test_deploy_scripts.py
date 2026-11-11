"""deploy/daoc-server.sh, admin-socket.sh and daoc-admin themselves, against a fake CoreServer.

stdlib only. Run from the repository root: python3 -m unittest discover -s tools/tests
"""
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

DEPLOY = Path(__file__).resolve().parents[2] / "deploy"

FAKE_SERVER = """\
import os, signal, socket, sys, time
if os.environ.get("FAKE_SERVER") == "die":
    print("fake server: boom", flush=True)
    sys.exit(3)
if os.environ.get("FAKE_SERVER") == "slow-die":
    time.sleep(2)
    print("fake server: late boom", flush=True)
    sys.exit(3)
if os.environ.get("FAKE_SERVER") == "slow":
    time.sleep(2)
path = os.environ["DAOC_ADMIN_SOCKET"]
sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
def stop(*_):
    os.unlink(path)
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
print("Server is now listening", flush=True)
while True:
    time.sleep(0.2)
"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ServerFolderCase(unittest.TestCase):
    """A server folder with a fake CoreServer; subclasses choose where it lives."""

    def make_dir(self):
        """Return (the folder to clean up, the server folder)."""
        # Short path: a unix socket path must stay under 104 bytes.
        root = Path(tempfile.mkdtemp(dir="/tmp", prefix="daocsrv."))
        return root, root

    def setUp(self):
        root, self.dir = self.make_dir()
        self.addCleanup(shutil.rmtree, root, True)
        shutil.copy2(DEPLOY / "daoc-server.sh", self.dir / "daoc-server.sh")
        shutil.copy2(DEPLOY / "admin-socket.sh", self.dir / "admin-socket.sh")
        core = self.dir / "bin" / "CoreServer"
        core.parent.mkdir()
        core.write_text(f"#!{sys.executable}\n{FAKE_SERVER}")
        core.chmod(0o755)
        (self.dir / "navmesh").mkdir()
        (self.dir / "navmesh" / "zone000.nav").write_bytes(b"")
        defaults = self.dir / "defaults"
        defaults.mkdir()
        (defaults / "world.sqlite").write_bytes(b"")
        (defaults / "serverconfig.xml").write_text(f"<Server><Port>{free_port()}</Port></Server>\n")
        for name in ("logconfig.xml", "invalidnames.txt"):
            (defaults / name).write_text("")
        admin = self.dir / "daoc-admin"
        admin.write_text("#!/bin/sh\necho ADMIN-SCREEN\n")
        admin.chmod(0o755)
        self.addCleanup(self.kill)

    def kill(self):
        pid_file = self.dir / "run" / "server.pid"
        if pid_file.is_file():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGKILL)
            except (OSError, ValueError):
                pass

    def env(self, **extra):
        environ = {k: v for k, v in os.environ.items() if k not in ("DAOC_HOME", "DAOC_ADMIN_SOCKET")}
        environ.update(extra)
        return environ

    def sh(self, *args, **env):
        return subprocess.run([str(self.dir / "daoc-server.sh"), *args], stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, env=self.env(**env), timeout=60)


class DetachTest(ServerFolderCase):
    def test_detach_returns_once_ready_without_the_admin_screen(self):
        result = self.sh("start", "--detach")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ADMIN-SCREEN", result.stdout)
        self.assertTrue(self.sh("status").stdout.startswith("running (pid "))
        self.assertEqual(self.sh("stop").returncode, 0)

    def test_detach_on_a_running_server_exits_0(self):
        self.assertEqual(self.sh("start", "--detach").returncode, 0)
        again = self.sh("start", "--detach")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already running", again.stdout)
        self.assertNotIn("ADMIN-SCREEN", again.stdout)

    def start_in_background(self, mode):
        first = subprocess.Popen([str(self.dir / "daoc-server.sh"), "start", "--detach"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, env=self.env(FAKE_SERVER=mode))
        self.addCleanup(first.wait)
        pid_file = self.dir / "run" / "server.pid"
        deadline = time.time() + 10
        while not pid_file.is_file() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(pid_file.is_file(), "the first start never launched the server")

    def test_detach_on_a_booting_server_waits_until_it_is_ready(self):
        self.start_in_background("slow")
        sock = self.dir / "run" / "admin.sock"
        self.assertFalse(sock.exists(), "the fake server must still be booting")
        again = self.sh("start", "--detach")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already running", again.stdout)
        self.assertTrue(sock.exists(), "returned before the server was listening")
        self.assertIn("Server is now listening", (self.dir / "logs" / "console.out").read_text())

    def test_detach_on_a_booting_server_that_dies_exits_1(self):
        self.start_in_background("slow-die")
        again = self.sh("start", "--detach")
        self.assertEqual(again.returncode, 1)
        self.assertIn("stopped before it was ready", again.stderr)
        self.assertIn("fake server: late boom", again.stderr)

    def test_detach_reports_a_server_that_dies(self):
        result = self.sh("start", "--detach", FAKE_SERVER="die")
        self.assertEqual(result.returncode, 1)
        self.assertIn("fake server: boom", result.stderr)


def admin_socket(folder):
    """The path admin-socket.sh gives a server folder."""
    out = subprocess.run(["bash", "-c", '. "$1/admin-socket.sh"; admin_socket "$1"', "_", str(folder)],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


# The fallback socket: in this user's private temp folder (getconf ends it with "/"), not world-writable /tmp.
USER_TEMP_SOCKET = "^" + re.escape(subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True,
                                                   text=True, check=True).stdout.strip()) + r"daoc-\d+\.sock$"


class LongFolderTest(ServerFolderCase):
    """A server folder deep enough that run/admin.sock would not fit a unix socket path."""

    def make_dir(self):
        root = Path(tempfile.mkdtemp(dir="/tmp", prefix="daocsrv."))
        folder = root / ("x" * 80)
        folder.mkdir()
        return root, folder

    def test_the_socket_falls_back_to_a_short_path_in_the_user_temp_folder(self):
        self.assertGreater(len(str(self.dir / "run" / "admin.sock")), 100)
        expected = admin_socket(self.dir)
        self.assertRegex(expected, USER_TEMP_SOCKET)
        self.addCleanup(lambda: os.path.lexists(expected) and os.unlink(expected))
        result = self.sh("start", "--detach")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.sh("status").stdout.startswith("running (pid "))
        self.assertTrue(os.path.exists(expected), "no socket at the short user-temp path")
        self.assertFalse((self.dir / "run" / "admin.sock").exists())
        self.assertEqual(self.sh("stop").returncode, 0)


class AdminScriptSocketTest(unittest.TestCase):
    """daoc-admin finds the same socket path daoc-server.sh uses."""

    def folder(self, parent):
        folder = parent / "srv"
        (folder / "bin").mkdir(parents=True)
        for name in ("daoc-admin", "admin-socket.sh"):
            shutil.copy2(DEPLOY / name, folder / name)
        stub = folder / "bin" / "DaocAdmin"
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$DAOC_ADMIN_SOCKET"\n')
        stub.chmod(0o755)
        return folder

    def run_admin(self, folder, **extra):
        environ = {k: v for k, v in os.environ.items() if k != "DAOC_ADMIN_SOCKET"}
        environ.update(extra)
        result = subprocess.run([str(folder / "daoc-admin")], capture_output=True, text=True,
                                env=environ, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir="/tmp", prefix="daocadm."))
        self.addCleanup(shutil.rmtree, self.root, True)

    def test_short_folder_uses_run_admin_sock(self):
        folder = self.folder(self.root)
        self.assertEqual(self.run_admin(folder), f"{folder}/run/admin.sock")

    def test_long_folder_uses_the_same_temp_path_as_the_server_script(self):
        long_parent = self.root / ("x" * 80)
        long_parent.mkdir()
        folder = self.folder(long_parent)
        printed = self.run_admin(folder)
        self.assertRegex(printed, USER_TEMP_SOCKET)
        self.assertEqual(printed, admin_socket(folder))

    def test_an_explicit_socket_wins(self):
        folder = self.folder(self.root)
        self.assertEqual(self.run_admin(folder, DAOC_ADMIN_SOCKET="/x"), "/x")


if __name__ == "__main__":
    unittest.main()
