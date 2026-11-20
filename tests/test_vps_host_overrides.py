#!/usr/bin/env python3
"""Behavior and bootstrap contracts for VPS private host overrides."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HOST_OVERRIDE = REPO / "scripts/configure-host-override.sh"
HEIGHLINER_BOOTSTRAP = REPO / "system/vps01/ubuntu/bootstrap.sh"
FARCASTER_BOOTSTRAP = REPO / "system/vps02/ubuntu/bootstrap.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class VpsHostOverrideTests(unittest.TestCase):
    def test_rewrite_is_idempotent_and_preserves_unrelated_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            hosts = root / "hosts"
            first = root / "first"
            second = root / "second"
            hosts.write_text(
                "127.0.0.1 localhost\n"
                "10.42.20.4 AUTOMATE.WORMLOGIC.COM old-alias # old route\n"
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
            self.assertEqual(first.read_text(), second.read_text())
            text = second.read_text()
            self.assertIn("10.42.20.4\told-alias\t# old route", text)
            self.assertIn("192.0.2.10 unrelated.example", text)
            self.assertEqual(text.count("automate.wormlogic.com"), 1)
            self.assertIn(
                "10.8.0.3\tautomate.wormlogic.com\t# managed by linux-environments",
                text,
            )

    def test_input_validation_rejects_noncanonical_addresses_and_bad_labels(self) -> None:
        overlong_label = "a" * 64 + ".wormlogic.com"
        overlong_hostname = ".".join(["a" * 63] * 4) + ".com"
        command = (
            "set -e; "
            f'source "{HOST_OVERRIDE}"; '
            "validate_ipv4 10.8.0.3; "
            "validate_hostname automate.wormlogic.com; "
            "! validate_ipv4 18446744073709551616.0.0.1; "
            "! validate_ipv4 010.8.0.3; "
            "! validate_ipv4 256.8.0.3; "
            "! validate_hostname auto.-bad.com; "
            "! validate_hostname auto.bad-.com; "
            f'! validate_hostname "{overlong_label}"; '
            f'! validate_hostname "{overlong_hostname}"'
        )
        result = subprocess.run(
            ["bash", "-c", command], text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_install_path_replaces_mapping_and_cleans_temporary_file(self) -> None:
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
[[ "$1" == -o && "$2" == root && "$3" == -g && "$4" == root ]]
[[ "$5" == -m && "$6" == 0644 ]]
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
            self.assertEqual(sorted(path.name for path in root.iterdir()), ["bin", "hosts"])

    def test_both_vps_bootstraps_install_arrakis_override_after_tunnel_setup(self) -> None:
        expected = (
            '"$REPO_ROOT/scripts/configure-host-override.sh" '
            "10.8.0.3 automate.wormlogic.com"
        )
        for path in (HEIGHLINER_BOOTSTRAP, FARCASTER_BOOTSTRAP):
            text = path.read_text(encoding="utf-8")
            self.assertIn(expected, text, path)
            main = text[text.index("main() {") :]
            self.assertIn("\n  configure_automate_resolution\n", main, path)

        heighliner_main = HEIGHLINER_BOOTSTRAP.read_text()[
            HEIGHLINER_BOOTSTRAP.read_text().index("main() {") :
        ]
        self.assertLess(
            heighliner_main.index("\n  configure_host_system\n"),
            heighliner_main.index("\n  configure_automate_resolution\n"),
        )

        farcaster_main = FARCASTER_BOOTSTRAP.read_text()[
            FARCASTER_BOOTSTRAP.read_text().index("main() {") :
        ]
        self.assertLess(
            farcaster_main.index("\n  setup_wormlogic_vpn\n"),
            farcaster_main.index("\n  configure_automate_resolution\n"),
        )


if __name__ == "__main__":
    unittest.main()
