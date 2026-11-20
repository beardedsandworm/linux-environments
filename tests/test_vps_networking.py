#!/usr/bin/env python3
"""Behavior and repository-contract tests for VPS private networking."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HOST_OVERRIDE = REPO / "scripts/configure-host-override.sh"
HEIGHLINER_SETUP = REPO / "system/vps01/ubuntu/wireguard/setup.sh"
HEIGHLINER_FORWARDING = (
    REPO / "system/vps01/ubuntu/wireguard/configure-forwarding-policy.sh"
)
HEIGHLINER_BOOTSTRAP = REPO / "system/vps01/ubuntu/bootstrap.sh"
FARCASTER_BOOTSTRAP = REPO / "system/vps02/ubuntu/bootstrap.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class VpsNetworkingTests(unittest.TestCase):
    def test_host_override_rewrite_is_idempotent_and_preserves_other_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            hosts = root / "hosts"
            first = root / "first"
            second = root / "second"
            hosts.write_text(
                "127.0.0.1 localhost\n"
                "10.42.20.4 automate.wormlogic.com old-alias # old route\n"
                "192.0.2.10 unrelated.example\n",
                encoding="utf-8",
            )
            command = (
                f'source "{HOST_OVERRIDE}"; '
                f'rewrite_hosts_file "{hosts}" "{first}" 10.8.0.3 automate.wormlogic.com; '
                f'rewrite_hosts_file "{first}" "{second}" 10.8.0.3 automate.wormlogic.com'
            )
            result = subprocess.run(
                ["bash", "-c", command], text=True, capture_output=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(first.read_text(encoding="utf-8"), second.read_text(encoding="utf-8"))
            text = second.read_text(encoding="utf-8")
            self.assertIn("10.42.20.4\told-alias\t# old route", text)
            self.assertIn("192.0.2.10 unrelated.example", text)
            self.assertEqual(text.count("automate.wormlogic.com"), 1)
            self.assertIn(
                "10.8.0.3\tautomate.wormlogic.com\t# managed by linux-environments",
                text,
            )

    def test_host_override_validates_inputs(self) -> None:
        command = (
            "set -e; "
            f'source "{HOST_OVERRIDE}"; '
            "validate_ipv4 10.8.0.3; "
            "validate_hostname automate.wormlogic.com; "
            "! validate_ipv4 999.8.0.3; "
            "! validate_hostname 'bad host'"
        )
        result = subprocess.run(
            ["bash", "-c", command], text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_host_override_install_path_replaces_mapping_and_cleans_temp(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            hosts = root / "hosts"
            bin_dir = root / "bin"
            bin_dir.mkdir()
            hosts.write_text(
                "127.0.0.1 localhost\n10.42.20.4 automate.wormlogic.com\n",
                encoding="utf-8",
            )
            write_executable(
                bin_dir / "sudo",
                '#!/usr/bin/env bash\nset -euo pipefail\nexec "$@"\n',
            )
            write_executable(
                bin_dir / "install",
                '''#!/usr/bin/env bash
set -euo pipefail
source_file="${@: -2:1}"
target_file="${@: -1}"
cp "$source_file" "$target_file"
chmod 0644 "$target_file"
''',
            )
            write_executable(
                bin_dir / "getent",
                '''#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == ahostsv4 && "$2" == automate.wormlogic.com ]]
awk '$2 == "automate.wormlogic.com" { print $1, "STREAM", $2; exit }' "$MOCK_HOSTS_FILE"
''',
            )
            command = (
                "set -e; "
                f'source "{HOST_OVERRIDE}"; '
                f'install_host_override "{hosts}" 10.8.0.3 automate.wormlogic.com'
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "MOCK_HOSTS_FILE": str(hosts),
                    "TMPDIR": str(root),
                }
            )
            result = subprocess.run(
                ["bash", "-c", command],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("10.8.0.3\tautomate.wormlogic.com", hosts.read_text())
            self.assertEqual(
                sorted(path.name for path in root.iterdir()), ["bin", "hosts"]
            )

    def test_both_vps_bootstraps_install_arrakis_host_override(self) -> None:
        expected = (
            '"$REPO_ROOT/scripts/configure-host-override.sh" '
            "10.8.0.3 automate.wormlogic.com"
        )
        for path in (HEIGHLINER_BOOTSTRAP, FARCASTER_BOOTSTRAP):
            text = path.read_text(encoding="utf-8")
            self.assertIn(expected, text, path)
            main = text[text.index("main() {") :]
            self.assertIn("\n  configure_automate_resolution\n", main, path)

    def test_heighliner_forwarding_is_owned_by_narrow_ufw_route_rule(self) -> None:
        setup = HEIGHLINER_SETUP.read_text(encoding="utf-8")
        policy = HEIGHLINER_FORWARDING.read_text(encoding="utf-8")
        expected_rule = (
            "ufw route allow in on wg0 out on wg0 proto tcp "
            "from 10.8.0.6 to 10.8.0.3 port 443"
        )
        self.assertIn(expected_rule, policy)
        self.assertIn('DEFAULT_FORWARD_POLICY="DROP"', policy)
        self.assertIn("remove_legacy_forwarding_policy", policy)
        invocation = '"$SCRIPT_DIR/configure-forwarding-policy.sh"'
        self.assertIn(invocation, setup)
        main = setup[setup.index("main() {") :]
        self.assertLess(main.index(invocation), main.index("install_files"))
        self.assertFalse(
            (REPO / "system/vps01/ubuntu/wireguard/wormlogic.nft").exists()
        )
        self.assertFalse(
            (REPO / "system/vps01/ubuntu/wireguard/wormlogic-wg.service").exists()
        )

    def test_forwarding_policy_converges_before_cleanup_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            command_log = root / "commands.log"
            added_rules = root / "added-rules"
            added_rules.write_text("", encoding="utf-8")
            write_executable(
                bin_dir / "sudo",
                '''#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_COMMAND_LOG"
if [[ "$1" == rm ]]; then exit 0; fi
if [[ "$1" == grep && "${@: -1}" == /etc/default/ufw ]]; then
  [[ "$MOCK_UFW_DEFAULT" == DROP ]]
  exit
fi
exec "$@"
''',
            )
            write_executable(
                bin_dir / "ufw",
                '''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "status") printf 'Status: active\n' ;;
  "route allow in on wg0 out on wg0 proto tcp from 10.8.0.6 to 10.8.0.3 port 443 comment Farcaster to Arrakis HTTPS")
    printf "ufw route allow in on wg0 out on wg0 from 10.8.0.6 to 10.8.0.3 port 443 proto tcp comment 'Farcaster to Arrakis HTTPS'\n" >"$MOCK_ADDED_RULES"
    ;;
  "show added")
    printf "Added user rules (see 'ufw status' for running firewall):\n"
    cat "$MOCK_ADDED_RULES"
    ;;
  *) exit 2 ;;
esac
''',
            )
            write_executable(
                bin_dir / "systemctl",
                '''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "is-active --quiet wormlogic-wg.service") exit 0 ;;
  "is-enabled --quiet wormlogic-wg.service") exit 0 ;;
  "disable --now wormlogic-wg.service"|"daemon-reload") exit 0 ;;
  *) exit 2 ;;
esac
''',
            )
            write_executable(
                bin_dir / "nft",
                '''#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "list table inet wormlogic_wg_filter"|"delete table inet wormlogic_wg_filter") exit 0 ;;
  *) exit 2 ;;
esac
''',
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "MOCK_COMMAND_LOG": str(command_log),
                    "MOCK_ADDED_RULES": str(added_rules),
                    "MOCK_UFW_DEFAULT": "DROP",
                }
            )
            for _ in range(2):
                result = subprocess.run(
                    ["bash", str(HEIGHLINER_FORWARDING)],
                    text=True,
                    capture_output=True,
                    check=False,
                    env=env,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
            commands = command_log.read_text(encoding="utf-8").splitlines()
            first_add = next(
                i for i, line in enumerate(commands) if line.startswith("ufw route allow")
            )
            first_cleanup = next(
                i for i, line in enumerate(commands) if line.startswith("systemctl disable")
            )
            self.assertLess(first_add, first_cleanup)
            self.assertEqual(
                sum(line.startswith("ufw route allow") for line in commands), 2
            )

    def test_forwarding_policy_fails_closed_before_cleanup_when_ufw_is_inactive(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            command_log = root / "commands.log"
            write_executable(
                bin_dir / "sudo",
                '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"$MOCK_COMMAND_LOG"\nexec "$@"\n',
            )
            write_executable(
                bin_dir / "ufw",
                '#!/usr/bin/env bash\nprintf "Status: inactive\\n"\n',
            )
            write_executable(
                bin_dir / "nft",
                '#!/usr/bin/env bash\nexit 0\n',
            )
            write_executable(
                bin_dir / "systemctl",
                '#!/usr/bin/env bash\nexit 0\n',
            )
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "MOCK_COMMAND_LOG": str(command_log),
                }
            )
            result = subprocess.run(
                ["bash", str(HEIGHLINER_FORWARDING)],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            commands = command_log.read_text(encoding="utf-8")
            self.assertNotIn("disable --now", commands)
            self.assertNotIn("nft delete", commands)

    def test_farcaster_owns_point_six_and_chapterhouse_owns_point_seven(self) -> None:
        peer = (
            REPO / "system/vps01/ubuntu/wireguard/peers/70-farcaster.conf"
        ).read_text(encoding="utf-8")
        self.assertIn("AllowedIPs = 10.8.0.6/32", peer)

        authoritative_docs = (
            REPO / "README.md",
            REPO / "docs/NETWORK.md",
            REPO / "docs/OPERATIONAL_BASELINE.md",
        )
        for path in authoritative_docs:
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"Chapterhouse[^\n]*10\.8\.0\.6")
            self.assertRegex(text, r"Farcaster[^\n]*10\.8\.0\.6")
            self.assertRegex(text, r"Chapterhouse[^\n]*10\.8\.0\.7")

        chapterhouse = (
            REPO / "system/server04/ubuntu/bootstrap.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('default_vpn_ip="10.8.0.7/32"', chapterhouse)


if __name__ == "__main__":
    unittest.main()
