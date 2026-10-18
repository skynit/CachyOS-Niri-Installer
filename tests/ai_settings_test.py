#!/usr/bin/env python3
"""Exercise the public AI settings CLI without touching the user's configuration."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
CLI = PROJECT / "bin/cachyos-ai-settings"
GO_BINARY = os.environ.get("AI_SETTINGS_TEST_BINARY")
LOADER = PROJECT / "assets/lib/ai-settings.sh"
DEFAULTS = {
    "CACHYOS_DSH_PROFILE": "web",
    "CACHYOS_AGENT_NOTIFY_MIN_SECONDS": "15",
    "CACHYOS_ASK_SESSION": "day",
    "CACHYOS_ASK_MAX_CHARS": "12000",
    "CACHYOS_CRASH_ACTION": "1",
    "CACHYOS_CRASH_DEDUPE_SECONDS": "60",
    "CACHYOS_CRASH_IGNORE": "",
    "CACHYOS_OOM_ACTION": "1",
    "CACHYOS_OOM_DEDUPE_SECONDS": "300",
    "CACHYOS_OOM_PSI_ENABLED": "1",
    "CACHYOS_OOM_PSI_FULL_AVG60": "10",
    "CACHYOS_OOM_PSI_INTERVAL_SECONDS": "15",
}
BUILTINS = ("explain", "fix", "review", "summarize", "translate", "commit", "shell")

# Every mutable external command points here. Logs are JSON argv arrays so spaces,
# punctuation, and malicious-looking prompt text cannot hide quoting regressions.
STUB = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["AI_TEST_CALLS"], "a") as stream:
    stream.write(json.dumps([command, *args]) + "\\n")
failures = json.loads(os.environ.get("AI_TEST_FAILURES", "[]"))
if [command, *args] in failures:
    print("stub service operation failed", file=sys.stderr)
    sys.exit(7)
state_path = Path(os.environ["AI_TEST_SERVICES"])
services = json.loads(state_path.read_text())
if command == "systemctl":
    operation = args[1]
    unit = args[-1]
    if operation == "is-active":
        active = services.get(unit, False)
        print("active" if active else "inactive")
        sys.exit(0 if active else 3)
    if operation == "is-enabled":
        active = services.get(unit, False)
        print("enabled" if active else "disabled")
        sys.exit(0 if active else 1)
    if operation in ("enable", "disable"):
        services[unit] = operation == "enable"
        state_path.write_text(json.dumps(services))
    elif operation != "try-restart":
        print("unexpected systemctl operation", file=sys.stderr)
        sys.exit(99)
elif command == "cachyos-default-agent":
    print("codex")
elif command in ("cachyos-toggle-crash-capture", "cachyos-toggle-oom-capture"):
    kind = "crash" if "crash" in command else "oom"
    flag = Path.home() / ".local/state/cachyos-desktop/toggles" / (kind + "-capture-off")
    flag.parent.mkdir(parents=True, exist_ok=True)
    enabled = args == ["on"]
    if enabled:
        flag.unlink(missing_ok=True)
    else:
        flag.touch()
    if os.environ.get("AI_TEST_TOGGLE_NO_EFFECT") != "1":
        services["cachyos-" + kind + "-watch.service"] = enabled
        state_path.write_text(json.dumps(services))
elif command not in ("codex", "claude", "opencode", "dsh"):
    print("unexpected command", file=sys.stderr)
    sys.exit(99)
'''


class AISettingsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cachyos-ai-settings-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.xdg = self.root / "xdg"
        self.config = self.xdg / "cachyos-desktop"
        self.settings = self.config / "ai-settings.conf"
        self.actions = self.config / "ask-actions.conf"
        self.calls_file = self.root / "calls.jsonl"
        self.services_file = self.root / "services.json"
        self.services_file.write_text("{}")
        self.home.mkdir()
        stub_dir = self.root / "bin"
        stub_dir.mkdir()
        for name in ("systemctl", "cachyos-default-agent", "cachyos-toggle-crash-capture",
                     "cachyos-toggle-oom-capture", "codex", "claude", "opencode", "dsh"):
            path = stub_dir / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.share = self.root / "share"
        template = self.share / "assets/cachyos-desktop/ask-actions.conf"
        template.parent.mkdir(parents=True)
        template.write_text("".join(f"{key}\tdefault {key}\n" for key in BUILTINS))
        # Do not inherit CACHYOS_*, XDG_*, or shell-initialization settings from the
        # desktop/session that runs the suite. Executables still use the host toolchain.
        self.env = {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.xdg),
            "CACHYOS_DESKTOP_SHARE_DIR": str(self.share),
            "PATH": os.pathsep.join((str(stub_dir), str(Path(sys.executable).parent),
                                    "/usr/bin", "/bin")),
            "LANG": "C.UTF-8",
            "AI_TEST_CALLS": str(self.calls_file),
            "AI_TEST_SERVICES": str(self.services_file),
        }

    def cli(self, *args, ok=True, extra_env=None):
        command = [GO_BINARY] if GO_BINARY else [sys.executable, str(CLI)]
        result = subprocess.run([*command, *args], env=self.env | (extra_env or {}),
                                capture_output=True, text=True, timeout=10)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(result.stderr.strip(), "failure must have a user-visible reason")
        return result

    def state(self, **kwargs):
        return self.cli("state", **kwargs)

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def calls(self):
        if not self.calls_file.exists():
            return []
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]

    def loader(self, extra_env=None):
        # Pass the filename as argv, never interpolate paths/config text into Bash code.
        script = 'source "$1"; exec "$2" -c \'import json, os; print(json.dumps(dict(os.environ)))\''
        result = subprocess.run([shutil.which("bash"), "--noprofile", "--norc", "-eu", "-c",
                                 script, "loader-test", str(LOADER), sys.executable],
                                env=self.env | (extra_env or {}), text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_state_defaults_and_no_preferences_written(self):
        state = self.state()
        fields = {field["key"]: field["value"] for group in state["groups"] for field in group["fields"]}
        self.assertEqual(fields, DEFAULTS)
        self.assertEqual(state["defaultAgent"], "codex")
        self.assertEqual(state["notifyMode"], "auto")
        self.assertEqual(state["actionsPath"], str(self.actions))
        self.assertEqual([item["id"] for item in state["actions"]], list(BUILTINS))
        self.assertTrue(all(item["builtin"] for item in state["actions"]))
        self.assertEqual([item["id"] for item in state["agents"]], ["codex", "claude", "opencode", "dsh"])
        self.assertTrue(all(item["installed"] for item in state["agents"]))
        services = {item["key"]: item for item in state["services"]}
        self.assertTrue(services["crash"]["enabled"])
        self.assertTrue(services["oom"]["enabled"])
        self.assertFalse(services["theme"]["enabled"])
        self.assertFalse(any(item["active"] for item in services.values()))
        self.assertFalse(self.config.exists(), "reading state must not create preferences")

    def test_state_uses_persisted_flags_and_values(self):
        self.write(self.settings, "CACHYOS_ASK_SESSION=new\nUNKNOWN=ignored\n")
        flag = self.home / ".local/state/cachyos-desktop/toggles/oom-capture-off"
        self.write(flag, "")
        self.services_file.write_text(json.dumps({"cachyos-agent-theme.path": True}))
        state = self.state()
        fields = {field["key"]: field["value"] for group in state["groups"] for field in group["fields"]}
        self.assertEqual(fields["CACHYOS_ASK_SESSION"], "new")
        self.assertNotIn("UNKNOWN", fields)
        services = {item["key"]: item for item in state["services"]}
        self.assertFalse(services["oom"]["enabled"])
        self.assertTrue(services["theme"]["enabled"])
        self.assertTrue(services["theme"]["active"])

    def test_prompt_override_reset_and_custom_action(self):
        self.cli("prompt-set", "explain", "  override explain  ")
        state = {item["id"]: item for item in self.state()["actions"]}
        self.assertEqual(state["explain"], {"id": "explain", "prompt": "override explain", "builtin": True})
        self.assertEqual(len(state), 7)
        self.cli("prompt-set", "custom_1-check", "custom prompt")
        state = {item["id"]: item for item in self.state()["actions"]}
        self.assertEqual(state["custom_1-check"]["prompt"], "custom prompt")
        self.assertFalse(state["custom_1-check"]["builtin"])
        self.cli("prompt-reset", "explain")
        self.cli("prompt-reset", "custom_1-check")
        state = {item["id"]: item for item in self.state()["actions"]}
        self.assertEqual(state["explain"]["prompt"], "default explain")
        self.assertNotIn("custom_1-check", state)

    def test_prompt_updates_preserve_other_lines_and_remove_duplicates(self):
        untouched = "# comment\n\nfix\tkeep this\nbroken line\nother=keep=value\n"
        self.write(self.actions, untouched + "explain\told one\nexplain=old two\n")
        self.cli("prompt-set", "explain", "replacement")
        self.assertEqual(self.actions.read_text(), untouched + "explain\treplacement\n")
        self.cli("prompt-reset", "explain")
        self.assertEqual(self.actions.read_text(), untouched)

    def test_prompt_invalid_values_do_not_change_existing_file(self):
        original = "# preserve\nfix\tuntouched\n"
        self.write(self.actions, original)
        for key, value in (("bad id", "text"), ("1bad", "text"), ("x;touch", "text"),
                           ("ok", ""), ("ok", "  "), ("ok", "a\tb"),
                           ("ok", "a\nb"), ("ok", "a\rb")):
            with self.subTest(key=key, value=value):
                self.cli("prompt-set", key, value, ok=False)
                self.assertEqual(self.actions.read_text(), original)
        self.cli("prompt-reset", "bad id", ok=False)
        self.assertEqual(self.actions.read_text(), original)
        self.assertEqual(self.calls(), [])

    def test_actions_path_override_and_xdg_priority(self):
        custom = self.root / "custom actions.conf"
        self.cli("prompt-set", "fix", "explicit file", extra_env={"CACHYOS_ASK_ACTIONS": str(custom)})
        self.assertEqual(custom.read_text(), "fix\texplicit file\n")
        self.assertFalse(self.actions.exists())
        self.assertEqual(self.state(extra_env={"CACHYOS_ASK_ACTIONS": str(custom)})["actionsPath"], str(custom))
        self.cli("set", "CACHYOS_ASK_MAX_CHARS", "123")
        self.assertTrue(self.settings.exists())
        self.assertFalse((self.home / ".config/cachyos-desktop").exists())

    def test_settings_validation_rejects_bad_values_without_write_or_service_calls(self):
        original = "CACHYOS_ASK_SESSION=day\n"
        self.write(self.settings, original)
        invalid = (("UNKNOWN", "1"), ("CACHYOS_DSH_PROFILE", "invalid"),
                   ("CACHYOS_ASK_SESSION", "weekly"), ("CACHYOS_OOM_ACTION", "true"),
                   ("CACHYOS_ASK_MAX_CHARS", "0"), ("CACHYOS_ASK_MAX_CHARS", "1000001"),
                   ("CACHYOS_OOM_DEDUPE_SECONDS", "-1"), ("CACHYOS_OOM_DEDUPE_SECONDS", "0"),
                   ("CACHYOS_OOM_PSI_FULL_AVG60", "101"), ("CACHYOS_OOM_PSI_FULL_AVG60", "5.5"),
                   ("CACHYOS_OOM_PSI_INTERVAL_SECONDS", "3601"),
                   ("CACHYOS_CRASH_IGNORE", "["), ("CACHYOS_CRASH_IGNORE", "a\nb"),
                   ("CACHYOS_CRASH_IGNORE", "a\rb"))
        for key, value in invalid:
            with self.subTest(key=key, value=value):
                self.cli("set", key, value, ok=False)
                self.assertEqual(self.settings.read_text(), original)
        self.assertFalse(self.actions.exists())
        self.assertFalse((self.config / "agent-notify").exists())
        self.assertEqual(self.calls(), [])

    def test_valid_setting_normalization_and_preservation(self):
        self.write(self.settings, "CACHYOS_ASK_SESSION=new\nCACHYOS_DSH_PROFILE=web\n")
        self.cli("set", "CACHYOS_ASK_MAX_CHARS", "00025")
        self.assertIn("CACHYOS_ASK_MAX_CHARS=25\n", self.settings.read_text())
        self.assertIn("CACHYOS_ASK_SESSION=new\n", self.settings.read_text())
        self.assertIn("CACHYOS_DSH_PROFILE=web\n", self.settings.read_text())
        self.cli("set", "CACHYOS_AGENT_NOTIFY_MIN_SECONDS", "0")
        self.assertEqual(self.calls(), [])

    def test_notify_mode_uses_legacy_file(self):
        notify = self.config / "agent-notify"
        for mode in ("always", "off", "auto"):
            with self.subTest(mode=mode):
                self.cli("set", "notify-mode", mode)
                self.assertEqual(notify.read_text(), mode + "\n")
                self.assertEqual(self.state()["notifyMode"], mode)
        self.assertFalse(self.settings.exists())
        self.cli("set", "notify-mode", "invalid", ok=False)
        self.assertEqual(notify.read_text(), "auto\n")
        self.write(notify, "malformed\n")
        self.assertEqual(self.state()["notifyMode"], "auto")

    def test_watcher_settings_only_try_restart_the_affected_service(self):
        for key, value, unit in (("CACHYOS_CRASH_ACTION", "0", "cachyos-crash-watch.service"),
                                 ("CACHYOS_OOM_PSI_ENABLED", "0", "cachyos-oom-watch.service")):
            with self.subTest(key=key):
                previous = len(self.calls())
                self.cli("set", key, value)
                self.assertEqual(self.calls()[previous:], [["systemctl", "--user", "try-restart", unit]])
        self.assertEqual(json.loads(self.services_file.read_text()), {},
                         "setting a preference must not start disabled watchers")

    def test_try_restart_error_is_visible_even_when_preference_was_saved(self):
        failure = ["systemctl", "--user", "try-restart", "cachyos-oom-watch.service"]
        result = self.cli("set", "CACHYOS_OOM_ACTION", "0", ok=False,
                          extra_env={"AI_TEST_FAILURES": json.dumps([failure])})
        self.assertIn("stub service operation failed", result.stderr)
        self.assertIn("CACHYOS_OOM_ACTION=0\n", self.settings.read_text())

    def test_service_toggles_and_systemd_calls(self):
        for kind in ("crash", "oom"):
            for value in ("on", "off"):
                with self.subTest(kind=kind, value=value):
                    self.cli("service", kind, value)
                    self.assertIn([f"cachyos-toggle-{kind}-capture", value], self.calls())
                    flag = self.home / f".local/state/cachyos-desktop/toggles/{kind}-capture-off"
                    self.assertEqual(flag.exists(), value == "off")
        self.cli("service", "theme", "on")
        self.cli("service", "usage", "off")
        self.assertIn(["systemctl", "--user", "enable", "--now", "cachyos-agent-theme.path"], self.calls())
        self.assertIn(["systemctl", "--user", "disable", "--now", "cachyos-agent-usage.timer"], self.calls())

    def test_service_rejects_bad_requests_without_invoking_helpers(self):
        for key, value in (("unknown", "on"), ("oom", "true"), ("usage", "")):
            with self.subTest(key=key, value=value):
                self.cli("service", key, value, ok=False)
        self.assertEqual(self.calls(), [])

    def test_service_error_is_surfaced(self):
        failure = ["systemctl", "--user", "enable", "--now", "cachyos-agent-theme.path"]
        result = self.cli("service", "theme", "on", ok=False,
                          extra_env={"AI_TEST_FAILURES": json.dumps([failure])})
        self.assertIn("stub service operation failed", result.stderr)
        result = self.cli("service", "crash", "on", ok=False,
                          extra_env={"AI_TEST_TOGGLE_NO_EFFECT": "1"})
        self.assertIn("服务未达到请求状态", result.stderr)

    def test_toggle_helper_error_is_surfaced(self):
        failure = ["cachyos-toggle-oom-capture", "on"]
        result = self.cli("service", "oom", "on", ok=False,
                          extra_env={"AI_TEST_FAILURES": json.dumps([failure])})
        self.assertIn("stub service operation failed", result.stderr)
        self.assertEqual(self.calls(), [failure])

    def test_crash_ignore_uses_valid_ere_and_restarts_only_crash_watcher(self):
        expression = "^(foo|bar)[[:digit:]]+$"
        self.cli("set", "CACHYOS_CRASH_IGNORE", expression)
        self.assertEqual(self.settings.read_text(), f"CACHYOS_CRASH_IGNORE={expression}\n")
        self.assertEqual(self.calls(), [["systemctl", "--user", "try-restart", "cachyos-crash-watch.service"]])
        self.assertEqual(self.loader()["CACHYOS_CRASH_IGNORE"], expression)

    def test_default_agent_error_is_surfaced_in_state(self):
        result = self.cli("state", ok=False,
                          extra_env={"AI_TEST_FAILURES": json.dumps([["cachyos-default-agent"]])})
        self.assertIn("stub service operation failed", result.stderr)

    def test_loader_missing_file_is_a_noop(self):
        loaded = self.loader()
        self.assertNotIn("CACHYOS_ASK_SESSION", loaded)
        self.assertFalse(self.config.exists())
        self.assertEqual(self.calls(), [])

    def test_loader_xdg_environment_precedence_and_empty_override(self):
        self.write(self.settings, "CACHYOS_ASK_SESSION=new\nCACHYOS_ASK_MAX_CHARS=345\nCACHYOS_CRASH_IGNORE=saved\n")
        self.write(self.home / ".config/cachyos-desktop/ai-settings.conf", "CACHYOS_ASK_MAX_CHARS=999\n")
        loaded = self.loader({"CACHYOS_ASK_SESSION": "day", "CACHYOS_CRASH_IGNORE": ""})
        self.assertEqual(loaded["CACHYOS_ASK_SESSION"], "day")
        self.assertEqual(loaded["CACHYOS_CRASH_IGNORE"], "")
        self.assertEqual(loaded["CACHYOS_ASK_MAX_CHARS"], "345")
        self.assertEqual(self.calls(), [])

    def test_home_config_fallback_without_xdg(self):
        home_config = self.home / ".config/cachyos-desktop"
        self.write(home_config / "ai-settings.conf", "CACHYOS_ASK_MAX_CHARS=777\n")
        self.env.pop("XDG_CONFIG_HOME")
        self.assertEqual(self.loader()["CACHYOS_ASK_MAX_CHARS"], "777")
        self.cli("prompt-set", "fix", "home fallback prompt")
        self.assertEqual((home_config / "ask-actions.conf").read_text(), "fix\thome fallback prompt\n")
        self.assertEqual(self.state()["actionsPath"], str(home_config / "ask-actions.conf"))
        self.assertFalse(self.config.exists())

    def test_empty_path_environment_uses_home_fallback(self):
        home_config = self.home / ".config/cachyos-desktop"
        self.env["XDG_CONFIG_HOME"] = ""
        self.env["CACHYOS_ASK_ACTIONS"] = ""
        self.cli("set", "CACHYOS_ASK_MAX_CHARS", "777")
        self.assertEqual(self.loader()["CACHYOS_ASK_MAX_CHARS"], "777")
        self.cli("prompt-set", "fix", "empty environment fallback")
        self.assertEqual(self.state()["actionsPath"], str(home_config / "ask-actions.conf"))
        self.assertFalse(self.config.exists())

    def test_muted_programs_use_shared_legacy_list(self):
        muted = self.home / ".local/state/cachyos-desktop/agents/crash-muted.txt"
        self.write(muted, "node\nexample\n")
        self.assertEqual(self.state()["mutedPrograms"], ["node", "example"])
        self.assertEqual(muted.read_text(), "node\nexample\n")

    def test_loader_preserves_shell_injection_as_literal_data(self):
        marker = self.root / "must-not-exist"
        payload = f'$(touch "{marker}"); `touch "{marker}"`; a=b==; "quotes" \\ path'
        self.write(self.settings, f"CACHYOS_CRASH_IGNORE={payload}\nUNKNOWN=$(touch {marker})\n"
                                 f"export CACHYOS_ASK_SESSION=$(touch {marker})\n")
        loaded = self.loader()
        self.assertEqual(loaded["CACHYOS_CRASH_IGNORE"], payload)
        self.assertNotIn("UNKNOWN", loaded)
        self.assertNotIn("CACHYOS_ASK_SESSION", loaded)
        self.assertFalse(marker.exists(), "loader executed configuration as shell code")
        self.assertEqual(self.calls(), [])

    def test_loader_preserves_equals_and_final_line_without_newline(self):
        self.write(self.settings, "CACHYOS_ASK_SESSION=new\nCACHYOS_CRASH_IGNORE=a=b==")
        loaded = self.loader()
        self.assertEqual(loaded["CACHYOS_ASK_SESSION"], "new")
        self.assertEqual(loaded["CACHYOS_CRASH_IGNORE"], "a=b==")

    def test_cli_prompt_shell_text_is_not_executed(self):
        marker = self.root / "prompt-must-not-exist"
        payload = f'$(touch "{marker}"); `touch "{marker}"`; echo literal'
        self.cli("prompt-set", "custom", payload)
        self.assertEqual(self.actions.read_text(), f"custom\t{payload}\n")
        self.assertFalse(marker.exists())
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
