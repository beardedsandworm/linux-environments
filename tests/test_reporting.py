#!/usr/bin/env python3
"""Behavior and repository-contract tests for host reporting cleanup."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class ReportingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.home = self.root / "home"
        self.config = self.root / "config"
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        for directory in (self.home, self.config / "dotfiles", self.state, self.bin):
            directory.mkdir(parents=True, exist_ok=True)

        (self.config / "dotfiles" / "machine-id").write_text("test01\n", encoding="utf-8")
        (self.config / "dotfiles" / "n8n-webhook").write_text(
            "https://n8n.invalid/webhook/events\n", encoding="utf-8"
        )

        self.payload = self.root / "payload.json"
        self.curl_log = self.root / "curl.log"
        self.dead_letter = self.state / "notify-dead-letter"
        write_executable(
            self.bin / "curl",
            """#!/usr/bin/env bash
set -euo pipefail
payload_file=""
while (($#)); do
  case "$1" in
    --data-binary|-d|--data)
      value="$2"
      if [[ "$value" == @* ]]; then
        payload_file="${value#@}"
        cp "$payload_file" "$MOCK_CURL_PAYLOAD"
      else
        printf '%s' "$value" >"$MOCK_CURL_PAYLOAD"
        payload_file="$MOCK_CURL_PAYLOAD"
      fi
      shift 2
      ;;
    --write-out|-w) shift 2 ;;
    *) shift ;;
  esac
done
event_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["event"]["event_id"])' "$payload_file")"
printf '%s\n' "$event_id" >>"$MOCK_CURL_LOG"
if [[ "${MOCK_CURL_STATUS:-0}" != 0 ]]; then
  exit "$MOCK_CURL_STATUS"
fi
if [[ -n "${MOCK_POISON_EVENT_ID:-}" && "$event_id" == "$MOCK_POISON_EVENT_ID" ]]; then
  printf '422'
else
  printf '204'
fi
""",
        )

        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.config),
                "XDG_STATE_HOME": str(self.state),
                "PATH": f"{self.bin}:{self.env['PATH']}",
                "MOCK_CURL_LOG": str(self.curl_log),
                "MOCK_CURL_PAYLOAD": str(self.payload),
                "NOTIFY_OUTBOX_DIR": str(self.state / "notify-outbox"),
                "NOTIFY_DEAD_LETTER_DIR": str(self.dead_letter),
            }
        )

    def run_script(self, script: Path, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        merged = self.env.copy()
        if env:
            merged.update(env)
        return subprocess.run(
            ["bash", str(script), *args],
            cwd=REPO,
            env=merged,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_notify_emits_versioned_event_and_legacy_adapter_to_n8n_only(self) -> None:
        result = self.run_script(
            SCRIPTS / "notify.sh",
            "--producer", "linux-environments.package-export",
            "--kind", "observation",
            "--domain", "packages",
            "--event-type", "package_inventory.changed",
            "--severity", "info",
            "--state", "observed",
            "--dedupe-key", "package-inventory:test01",
            "--title", "Package inventory changed",
            "--summary", "apt.txt changed",
            "--details-json", '{"changed_files":["apt.txt"]}',
            "--event-id", "event-test-1",
            "--occurred-at", "2026-11-19T18:00:00Z",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(self.payload.read_text(encoding="utf-8"))
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["event"]["event_id"], "event-test-1")
        self.assertEqual(payload["event"]["producer_id"], "linux-environments.package-export")
        self.assertEqual(payload["event"]["details"]["changed_files"], ["apt.txt"])
        self.assertEqual(payload["severity"], "ok")
        self.assertEqual(payload["check_name"], "linux-environments.package-export")
        self.assertNotIn("discord", (SCRIPTS / "notify.sh").read_text(encoding="utf-8").lower())

    def test_notify_rejects_invalid_details_json_before_transport(self) -> None:
        result = self.run_script(
            SCRIPTS / "notify.sh",
            "--producer", "test",
            "--kind", "observation",
            "--domain", "host",
            "--event-type", "test.event",
            "--severity", "info",
            "--state", "observed",
            "--dedupe-key", "test",
            "--title", "Test",
            "--summary", "Test",
            "--details-json", "not-json",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.payload.exists())

    def test_failed_delivery_remains_in_outbox(self) -> None:
        result = self.run_script(
            SCRIPTS / "notify.sh",
            "--producer", "test",
            "--kind", "incident",
            "--domain", "host",
            "--event-type", "test.failed",
            "--severity", "error",
            "--state", "open",
            "--dedupe-key", "test:failed",
            "--title", "Test failure",
            "--summary", "Transport should retain this event",
            "--event-id", "event-test-failed",
            env={"MOCK_CURL_STATUS": "22"},
        )
        self.assertNotEqual(result.returncode, 0)
        queued = list((self.state / "notify-outbox").glob("*.json"))
        self.assertEqual(len(queued), 1)
        self.assertEqual(json.loads(queued[0].read_text(encoding="utf-8"))["event"]["event_id"], "event-test-failed")

    def test_outbox_replays_chronologically_and_dead_letters_permanent_rejections(self) -> None:
        outbox = self.state / "notify-outbox"
        outbox.mkdir(parents=True)

        def queued(event_id: str, occurred_at: str) -> dict[str, object]:
            return {
                "schema_version": 1,
                "event": {
                    "event_id": event_id,
                    "occurred_at": occurred_at,
                    "producer_id": "test",
                },
            }

        (outbox / "z-old.json").write_text(
            json.dumps(queued("z-old", "2026-11-19T17:00:00Z")), encoding="utf-8"
        )
        (outbox / "x-offset.json").write_text(
            json.dumps(queued("x-offset", "2026-11-19T18:30:00+01:00")), encoding="utf-8"
        )
        (outbox / "a-poison.json").write_text(
            json.dumps(queued("a-poison", "2026-11-19T18:00:00Z")), encoding="utf-8"
        )

        result = self.run_script(
            SCRIPTS / "notify.sh",
            "--producer", "test",
            "--kind", "observation",
            "--domain", "host",
            "--event-type", "test.new",
            "--severity", "info",
            "--state", "observed",
            "--dedupe-key", "test:new",
            "--title", "New event",
            "--summary", "Must not be blocked by a permanent rejection",
            "--event-id", "m-new",
            "--occurred-at", "2026-11-19T19:00:00Z",
            env={"MOCK_POISON_EVENT_ID": "a-poison"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.curl_log.read_text(encoding="utf-8").splitlines(),
            ["z-old", "x-offset", "a-poison", "m-new"],
        )
        self.assertFalse(list(outbox.glob("*.json")))
        self.assertTrue((self.dead_letter / "a-poison.json").exists())

    def test_current_event_permanent_rejection_returns_failure(self) -> None:
        result = self.run_script(
            SCRIPTS / "notify.sh",
            "--producer", "test",
            "--kind", "observation",
            "--domain", "host",
            "--event-type", "test.poison",
            "--severity", "info",
            "--state", "observed",
            "--dedupe-key", "test:poison",
            "--title", "Poison event",
            "--summary", "The caller must know this event was rejected",
            "--event-id", "current-poison",
            env={"MOCK_POISON_EVENT_ID": "current-poison"},
        )
        self.assertEqual(result.returncode, 65)
        self.assertTrue((self.dead_letter / "current-poison.json").exists())

    def test_notify_rejects_timestamp_without_timezone(self) -> None:
        result = self.run_script(
            SCRIPTS / "notify.sh",
            "--producer", "test",
            "--kind", "observation",
            "--domain", "host",
            "--event-type", "test.timestamp",
            "--severity", "info",
            "--state", "observed",
            "--dedupe-key", "test:timestamp",
            "--title", "Timestamp test",
            "--summary", "Naive timestamps are ambiguous",
            "--occurred-at", "2026-11-19T18:00:00",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.payload.exists())

    def test_disk_check_reports_only_capacity_breach_with_distinct_identity(self) -> None:
        notify_args = self.root / "notify-args.txt"
        fake_home_notify = self.home / "dotfiles" / "scripts" / "notify.sh"
        fake_home_notify.parent.mkdir(parents=True)
        write_executable(fake_home_notify, '#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$MOCK_NOTIFY_ARGS"\n')
        write_executable(
            self.bin / "df",
            '#!/usr/bin/env bash\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/mock 100 91 9 91%% /\\n"\n',
        )
        result = self.run_script(
            SCRIPTS / "disk-space-check.sh",
            "85",
            env={"MOCK_NOTIFY_ARGS": str(notify_args)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = notify_args.read_text(encoding="utf-8")
        self.assertIn("--producer\nlinux-environments.disk-space-check", args)
        self.assertIn("--severity\nwarning", args)
        self.assertIn("--event-type\nfilesystem.capacity", args)

    def test_remaining_reporters_use_notify_and_not_discord(self) -> None:
        package_export = (SCRIPTS / "package-export.sh").read_text(encoding="utf-8")
        system_update = (SCRIPTS / "system-update.sh").read_text(encoding="utf-8")
        self.assertIn("linux-environments.package-export", package_export)
        self.assertIn("linux-environments.system-update", system_update)
        self.assertIn("notify.sh", system_update)
        self.assertNotIn("discord-webhook", system_update)

    def test_retired_services_are_absent_except_from_temporary_cleanup(self) -> None:
        retired = ("repo-update-check", "dotfiles-change-check")
        allowed = {REPO / "scripts" / "update-reporting-services.sh", Path(__file__).resolve()}
        for path in REPO.rglob("*"):
            if not path.is_file() or path in allowed or ".git" in path.parts:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for name in retired:
                self.assertNotIn(name, text, f"retired service reference remains in {path.relative_to(REPO)}")
        for name in retired:
            self.assertFalse((SCRIPTS / f"{name}.sh").exists())
            self.assertFalse((REPO / "systemd" / f"{name}.service").exists())
            self.assertFalse((REPO / "systemd" / f"{name}.timer").exists())

    def test_system_update_emits_aggregate_ready_result(self) -> None:
        state_file = self.root / "package-state"
        state_file.write_text("old\n", encoding="utf-8")
        notify_args = self.root / "system-update-notify-args.txt"
        root_helper = self.root / "system-update-root"
        notify = self.root / "notify"
        no_reboot_file = self.root / "no-reboot-required"

        write_executable(
            self.bin / "sudo",
            '#!/usr/bin/env bash\n[[ "${1:-}" == "-n" ]] && shift\nexec "$@"\n',
        )
        write_executable(
            self.bin / "dpkg-query",
            f'''#!/usr/bin/env bash
if [[ "$(<{state_file})" == old ]]; then
  printf "base\\t1.0\\n"
else
  printf "base\\t2.0\\n"
fi
''',
        )
        write_executable(
            self.bin / "apt-get",
            '''#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
  printf "Inst pending [1.0] (2.0 repo)\\n"
fi
''',
        )
        write_executable(
            self.bin / "snap",
            f'''#!/usr/bin/env bash
if [[ "${{1:-}}" == list ]]; then
  printf "Name Version Rev Tracking Publisher Notes\\n"
  if [[ "$(<{state_file})" == old ]]; then
    printf "core 1.0 10 latest vendor -\\n"
  else
    printf "core 1.0 11 latest vendor -\\n"
  fi
elif [[ "${{1:-}} ${{2:-}}" == "refresh --list" ]]; then
  printf "Name Version Rev Size Publisher Notes\\n"
fi
''',
        )
        write_executable(
            self.bin / "flatpak",
            f'''#!/usr/bin/env bash
if [[ "${{1:-}}" == list ]]; then
  [[ "$*" == *"--columns=installation,ref,active"* ]] || exit 1
  if [[ "$(<{state_file})" == old ]]; then
    printf "system\\truntime/org.example.Platform/x86_64/stable\\tcommit-old\\n"
  else
    printf "system\\truntime/org.example.Platform/x86_64/stable\\tcommit-new\\n"
  fi
elif [[ "${{1:-}}" == remote-ls ]]; then
  exit 0
elif [[ "${{1:-}}" == update ]]; then
  exit 0
fi
''',
        )
        write_executable(
            root_helper,
            f'#!/usr/bin/env bash\nprintf "new\\n" >"{state_file}"\n',
        )
        write_executable(notify, '#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$MOCK_NOTIFY_ARGS"\n')

        result = self.run_script(
            SCRIPTS / "system-update.sh",
            env={
                "NOTIFY_SCRIPT": str(notify),
                "MOCK_NOTIFY_ARGS": str(notify_args),
                "SYSTEM_UPDATE_ROOT_HELPER": str(root_helper),
                "SYSTEM_UPDATE_REBOOT_REQUIRED_FILE": str(no_reboot_file),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = notify_args.read_text(encoding="utf-8").splitlines()
        pairs = dict(zip(args[0::2], args[1::2]))
        self.assertEqual(pairs["--producer"], "linux-environments.system-update")
        self.assertEqual(pairs["--event-type"], "system_update.completed")
        details = json.loads(pairs["--details-json"])
        self.assertEqual(details["updates_applied"], 3)
        self.assertEqual(details["updates_applied_by_manager"], {"apt": 1, "flatpak": 1, "snap": 1})
        self.assertEqual(details["updates_remaining"], 1)
        self.assertFalse(details["reboot_required"])

    def test_system_update_reports_unknown_when_remaining_probe_fails(self) -> None:
        notify_args = self.root / "system-update-probe-error-args.txt"
        root_helper = self.root / "system-update-root"
        notify = self.root / "notify"
        no_reboot_file = self.root / "no-reboot-required"

        write_executable(self.bin / "sudo", '#!/usr/bin/env bash\n[[ "${1:-}" == "-n" ]] && shift\nexec "$@"\n')
        write_executable(self.bin / "dpkg-query", '#!/usr/bin/env bash\nprintf "base\\t1.0\\n"\n')
        write_executable(
            self.bin / "apt-get",
            '#!/usr/bin/env bash\n[[ "${1:-}" == "-s" ]] && exit 100\nexit 0\n',
        )
        write_executable(root_helper, '#!/usr/bin/env bash\nexit 0\n')
        write_executable(notify, '#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$MOCK_NOTIFY_ARGS"\n')

        result = self.run_script(
            SCRIPTS / "system-update.sh",
            env={
                "NOTIFY_SCRIPT": str(notify),
                "MOCK_NOTIFY_ARGS": str(notify_args),
                "SYSTEM_UPDATE_ROOT_HELPER": str(root_helper),
                "SYSTEM_UPDATE_REBOOT_REQUIRED_FILE": str(no_reboot_file),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = notify_args.read_text(encoding="utf-8").splitlines()
        pairs = dict(zip(args[0::2], args[1::2]))
        self.assertEqual(pairs["--event-type"], "system_update.result_incomplete")
        details = json.loads(pairs["--details-json"])
        self.assertIsNone(details["updates_remaining"])
        self.assertIn("apt", details["remaining_probe_errors"])

    def test_system_update_reports_unknown_when_applied_inventory_probe_fails(self) -> None:
        state_file = self.root / "applied-probe-state"
        state_file.write_text("old\n", encoding="utf-8")
        notify_args = self.root / "system-update-applied-probe-error-args.txt"
        root_helper = self.root / "system-update-root"
        notify = self.root / "notify"
        no_reboot_file = self.root / "no-reboot-required"

        write_executable(self.bin / "sudo", '#!/usr/bin/env bash\n[[ "${1:-}" == "-n" ]] && shift\nexec "$@"\n')
        write_executable(self.bin / "dpkg-query", '#!/usr/bin/env bash\nprintf "base\\t1.0\\n"\n')
        write_executable(
            self.bin / "apt-get",
            '#!/usr/bin/env bash\n[[ "${1:-}" == "-s" ]] && exit 0\nexit 0\n',
        )
        write_executable(
            self.bin / "snap",
            f'''#!/usr/bin/env bash
if [[ "${{1:-}}" == list ]]; then
  [[ "$(<{state_file})" == old ]] && exit 1
  printf "Name Version Rev Tracking Publisher Notes\\ncore 1.0 10 latest vendor -\\n"
elif [[ "${{1:-}} ${{2:-}}" == "refresh --list" ]]; then
  printf "Name Version Rev Size Publisher Notes\\n"
fi
''',
        )
        write_executable(root_helper, f'#!/usr/bin/env bash\nprintf "new\\n" >"{state_file}"\n')
        write_executable(notify, '#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$MOCK_NOTIFY_ARGS"\n')

        result = self.run_script(
            SCRIPTS / "system-update.sh",
            env={
                "NOTIFY_SCRIPT": str(notify),
                "MOCK_NOTIFY_ARGS": str(notify_args),
                "SYSTEM_UPDATE_ROOT_HELPER": str(root_helper),
                "SYSTEM_UPDATE_REBOOT_REQUIRED_FILE": str(no_reboot_file),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        args = notify_args.read_text(encoding="utf-8").splitlines()
        pairs = dict(zip(args[0::2], args[1::2]))
        self.assertEqual(pairs["--event-type"], "system_update.result_incomplete")
        details = json.loads(pairs["--details-json"])
        self.assertIsNone(details["updates_applied"])
        self.assertIsNone(details["updates_applied_by_manager"]["snap"])
        self.assertIn("before:snap", details["applied_probe_errors"])

    def test_temporary_updater_fails_when_retired_timer_remains_active(self) -> None:
        updater = SCRIPTS / "update-reporting-services.sh"
        write_executable(
            self.bin / "systemctl",
            '''#!/usr/bin/env bash
case "$*" in
  *"disable --now repo-update-check.timer"*) exit 1 ;;
  *"is-active --quiet repo-update-check.timer"*) exit 0 ;;
  *) exit 0 ;;
esac
''',
        )
        result = self.run_script(updater)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("repo-update-check.timer", result.stderr + result.stdout)

    def test_temporary_updater_installs_current_units_and_removes_retired_units(self) -> None:
        updater = SCRIPTS / "update-reporting-services.sh"
        self.assertTrue(updater.exists())
        systemctl_log = self.root / "systemctl.log"
        write_executable(
            self.bin / "systemctl",
            '''#!/usr/bin/env bash
printf "%s\\n" "$*" >>"$MOCK_SYSTEMCTL_LOG"
case "$*" in
  *"is-enabled --quiet repo-update-check.timer"*|*"is-active --quiet repo-update-check.timer"*|*"is-active --quiet repo-update-check.service"*) exit 1 ;;
  *"is-enabled --quiet dotfiles-change-check.timer"*|*"is-active --quiet dotfiles-change-check.timer"*|*"is-active --quiet dotfiles-change-check.service"*) exit 1 ;;
esac
exit 0
''',
        )
        user_units = self.config / "systemd" / "user"
        user_units.mkdir(parents=True)
        for name in ("repo-update-check", "dotfiles-change-check"):
            (user_units / f"{name}.service").write_text("stale\n", encoding="utf-8")
            (user_units / f"{name}.timer").write_text("stale\n", encoding="utf-8")
        result = self.run_script(
            updater,
            env={"MOCK_SYSTEMCTL_LOG": str(systemctl_log)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("repo-update-check", "dotfiles-change-check"):
            self.assertFalse((user_units / f"{name}.service").exists())
            self.assertFalse((user_units / f"{name}.timer").exists())
        for name in ("disk-space-check", "package-export", "system-update"):
            self.assertTrue((user_units / f"{name}.service").exists())
            self.assertTrue((user_units / f"{name}.timer").exists())
        log = systemctl_log.read_text(encoding="utf-8")
        self.assertIn("enable --now disk-space-check.timer", log)
        self.assertIn("enable --now package-export.timer", log)
        self.assertIn("enable --now system-update.timer", log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
