"""Native-process tests: watching a live parent must never signal or kill it."""

import json
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ProcessLifetimeTests(unittest.TestCase):
    def observer(self, pid):
        return subprocess.Popen(
            [sys.executable, "-u", "-c",
             "from flygym_bridge.process_lifetime import wait_for_parent_exit; "
             "print('watching', flush=True); "
             f"wait_for_parent_exit({pid}, 0.05); print('gone', flush=True)"],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

    def test_watch_live_parent_then_detect_exit(self):
        parent = subprocess.Popen(
            [sys.executable, "-u", "-c", "import sys; print('ready', flush=True); sys.stdin.read()"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        observer = None
        try:
            self.assertEqual(parent.stdout.readline().strip(), "ready")
            observer = self.observer(parent.pid)
            self.assertEqual(observer.stdout.readline().strip(), "watching")
            time.sleep(0.3)
            self.assertIsNone(parent.poll(), "monitor killed a live parent")
            self.assertIsNone(observer.poll(), "monitor returned while parent is alive")
            parent.stdin.close()
            parent.wait(timeout=5)
            out, err = observer.communicate(timeout=5)
            self.assertEqual(observer.returncode, 0, err)
            self.assertEqual(out.strip(), "gone")
        finally:
            for proc in (observer, parent):
                if proc is not None:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait(timeout=5)
                    for stream in (proc.stdin, proc.stdout, proc.stderr):
                        if stream and not stream.closed:
                            stream.close()

    def test_backend_exits_when_app_is_killed(self):
        owner = subprocess.Popen(
            [sys.executable, "-u", "-c",
             "from pathlib import Path; from desktop_lab.session import Session; "
             "import json,sys; s=Session(Path.cwd(), mock=True, render=False).start(); "
             "print(json.dumps({'pid':s.process.pid, 'log':str(s.log_path)}), flush=True); "
             "sys.stdin.read(); s.close()"],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        observer = None
        try:
            line = owner.stdout.readline()
            self.assertTrue(line, owner.stderr.read() if owner.poll() is not None else "no startup reply")
            backend = json.loads(line)
            observer = self.observer(backend["pid"])
            self.assertEqual(observer.stdout.readline().strip(), "watching")
            time.sleep(0.3)
            self.assertIsNone(owner.poll(), "backend watcher killed its owner")
            self.assertIsNone(observer.poll())
            owner.kill()
            owner.wait(timeout=5)
            out, err = observer.communicate(timeout=10)
            self.assertEqual(observer.returncode, 0, err)
            self.assertEqual(out.strip(), "gone")
            self.assertIn("exited; stopping", Path(backend["log"]).read_text(encoding="utf-8"))
        finally:
            if owner.poll() is None:
                owner.stdin.close()
                owner.wait(timeout=15)
            if observer and observer.poll() is None:
                observer.kill()
                observer.wait(timeout=5)
            for proc in (observer, owner):
                if proc:
                    for stream in (proc.stdin, proc.stdout, proc.stderr):
                        if stream and not stream.closed:
                            stream.close()


if __name__ == "__main__":
    unittest.main()
