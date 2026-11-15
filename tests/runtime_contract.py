#!/usr/bin/env python3
"""Contract probes using stub Kitty; they inspect argv, not live REPL behavior."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCH = ROOT / "bin/repl-launch"
RESTART = ROOT / "bin/slime-repl-restart"


class RuntimeContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repl-runtime-contract-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.log = self.work / "calls.jsonl"
        self.kitty = self.work / "kitty"
        self.kitty.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['REPL_TEST_LOG'], 'a') as f: f.write(json.dumps(args) + '\\n')\n"
            "if args[0] == '@': sys.exit(1 if '--match' in args or os.environ.get('REPL_TEST_COLD') else 0)\n"
        )
        self.kitty.chmod(0o755)

    def environment(self, **updates):
        env = os.environ.copy()
        env.update({
            "REPL_TEST_LOG": str(self.log),
            "NVIM_SLIME_KITTY_BIN": str(self.kitty),
            "DL_REPL_SOCKET": "unix:/tmp/repl-contract.sock",
            "DL_REPL_WINDOW_TITLE": "test-repl-1",
            "DL_REPL_NO_FOCUS": "0",
        })
        env.update(updates)
        return env

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_generic_launcher_command_is_not_a_python_override(self):
        env = self.environment(DL_REPL_COMMAND=f"{RESTART} start-ipython")
        env.pop("NVIM_REPL_COMMAND", None)
        env.pop("NVIM_SLIME_IPYTHON_START_COMMAND", None)
        probe = (
            "import importlib.machinery, json; "
            f"m=importlib.machinery.SourceFileLoader('restart', {str(RESTART)!r}).load_module(); "
            "print(json.dumps(m.configured_repl_command()))"
        )
        result = subprocess.run(["python3", "-c", probe], env=env, check=True, capture_output=True, text=True)
        self.assertIsNone(json.loads(result.stdout))

    def test_restart_appends_ipython_flags_and_bundled_peek_server(self):
        capture = self.work / "ipython.json"
        fake_ipython = self.work / "ipython"
        fake_ipython.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "open(os.environ['IPYTHON_CAPTURE'], 'w').write(json.dumps({'argv': sys.argv[1:], 'role': os.environ['DL_ROLE']}))\n"
        )
        fake_ipython.chmod(0o755)
        env = self.environment(NVIM_REPL_COMMAND=str(fake_ipython), IPYTHON_CAPTURE=str(capture))
        subprocess.run([str(RESTART), "start-ipython"], env=env, check=True)
        result = json.loads(capture.read_text())
        self.assertEqual(result["argv"][:2], ["--no-autoindent", "--TerminalInteractiveShell.term_title=False"])
        peek = result["argv"][result["argv"].index("-i") + 1]
        self.assertEqual(Path(peek), ROOT / "python/repl_peek_server.py")
        self.assertEqual(result["role"], "repl")

    def test_r_warm_launch_uses_r_command_and_forwards_environment(self):
        env = self.environment(
            DL_REPL_FAMILY="r",
            DL_REPL_COMMAND="R --quiet --no-save",
            NVIM_REPL_COMMAND="stale python command",
            NVIM_REPL_ENVS_CONFIG="/tmp/repl-env-map.json",
            PYTHONPATH="/tmp/repl-project",
        )
        subprocess.run([str(LAUNCH)], env=env, check=True)
        launch = self.calls()[-1]
        self.assertEqual(launch[launch.index("-lc") + 1], "export KITTY_SHELL_INTEGRATION=no-title; exec R --quiet --no-save")
        joined = " ".join(launch)
        self.assertIn("DL_REPL_COMMAND=R --quiet --no-save", joined)
        self.assertIn("NVIM_REPL_COMMAND", joined)
        self.assertIn("NVIM_REPL_ENVS_CONFIG=/tmp/repl-env-map.json", joined)
        self.assertIn("PYTHONPATH=/tmp/repl-project", joined)
        self.assertNotIn("--no-autoindent", joined)
        self.assertNotIn("repl_peek_server.py", joined)

    def test_lua_cold_launch_does_not_route_through_python(self):
        env = self.environment(DL_REPL_FAMILY="lua", DL_REPL_COMMAND="lua", REPL_TEST_COLD="1")
        subprocess.run([str(LAUNCH)], env=env, check=True)
        launch = self.calls()[-1]
        self.assertIn("--listen-on", launch)
        self.assertEqual(launch[launch.index("-lc") + 1], "export KITTY_SHELL_INTEGRATION=no-title; exec lua")
        if os.uname().sysname == "Darwin":
            self.assertNotIn("--class", launch)
        else:
            self.assertIn("--class", launch)
        self.assertNotIn("start-ipython", " ".join(launch))
        self.assertNotIn("NVIM_REPL_COMMAND=", " ".join(launch))

    def test_python_warm_launch_forwards_only_explicit_custom_command(self):
        env = self.environment(
            DL_REPL_FAMILY="python",
            DL_REPL_COMMAND="/plugin/bin/slime-repl-restart start-ipython",
            NVIM_REPL_COMMAND="systemd-run --user --scope -p MemoryMax=1G ipython",
        )
        subprocess.run([str(LAUNCH)], env=env, check=True)
        launch = self.calls()[-1]
        joined = " ".join(launch)
        self.assertIn("NVIM_REPL_COMMAND=systemd-run --user --scope -p MemoryMax=1G ipython", joined)
        self.assertIn("exec /", launch[launch.index("-lc") + 1])
        self.assertNotIn("DL_REPL_COMMAND=/plugin", joined)


if __name__ == "__main__":
    unittest.main()
