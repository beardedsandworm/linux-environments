#!/usr/bin/env python3
"""Behavior and bootstrap contracts for Heighliner peer fragments."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
WRITER = REPO / "scripts/write-heighliner-peer-fragment.sh"
BOOTSTRAPS = tuple(sorted((REPO / "system").glob("*/*/bootstrap.sh")))
HEIGHLINER = REPO / "system/vps01/ubuntu/bootstrap.sh"
PEER_DIR = REPO / "system/vps01/ubuntu/wireguard/peers"

EXPECTED_PEERS = {
    "server01": ("20-arrakis.conf", "Arrakis", "10.8.0.3/32"),
    "server02": ("30-ix.conf", "IX", "10.8.0.4/32"),
    "laptop01": ("40-laptop01.conf", "laptop01", "10.8.0.10/32"),
    "laptop02": ("50-laptop02.conf", "laptop02", "10.8.0.11/32"),
    "vps02": ("70-farcaster.conf", "Farcaster / vps02", "10.8.0.6/32"),
    "server03": ("80-caladan.conf", "Caladan", "10.8.0.5/32"),
    "server04": ("90-chapterhouse.conf", "Chapterhouse", "10.8.0.7/32"),
}
VALID_PUBLIC_KEY = "vysVMJfC4Avhiwirms+Bi1K2Xfll1XT0umhx33/qCVA="
SECOND_PUBLIC_KEY = "PIuKfHEj+kmHv2P58PV0a9BulqGl00tmj2ZpOblvLS0="
NONCANONICAL_PUBLIC_KEY = "A" * 42 + "B="


class WireGuardPeerFragmentTests(unittest.TestCase):
    def test_writer_overwrites_canonical_fragments_for_every_non_hub_host(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            repo = Path(tempdir)
            peer_dir = repo / "system/vps01/ubuntu/wireguard/peers"
            peer_dir.mkdir(parents=True)
            env = os.environ.copy()
            env["REPO_ROOT"] = str(repo)

            for machine_id, (filename, label, address) in EXPECTED_PEERS.items():
                target = peer_dir / filename
                target.write_text("stale\n", encoding="utf-8")
                result = subprocess.run(
                    [str(WRITER), machine_id, VALID_PUBLIC_KEY, address],
                    text=True,
                    capture_output=True,
                    check=False,
                    env=env,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    target.read_text(encoding="utf-8"),
                    "[Peer]\n"
                    f"# {label}\n"
                    f"PublicKey = {VALID_PUBLIC_KEY}\n"
                    f"AllowedIPs = {address}\n",
                )
                self.assertEqual(target.stat().st_mode & 0o777, 0o644)

    def test_writer_rejects_unknown_hosts_wrong_addresses_and_invalid_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            repo = Path(tempdir)
            peer_dir = repo / "system/vps01/ubuntu/wireguard/peers"
            peer_dir.mkdir(parents=True)
            env = os.environ.copy()
            env["REPO_ROOT"] = str(repo)

            for args in (
                ("vps01", VALID_PUBLIC_KEY, "10.8.0.1/24"),
                ("server03", VALID_PUBLIC_KEY, "10.8.0.7/32"),
                ("server04", "not-a-key", "10.8.0.7/32"),
                ("server04", NONCANONICAL_PUBLIC_KEY, "10.8.0.7/32"),
            ):
                result = subprocess.run(
                    [str(WRITER), *args],
                    text=True,
                    capture_output=True,
                    check=False,
                    env=env,
                )
                self.assertNotEqual(result.returncode, 0, args)

            self.assertFalse(list(peer_dir.iterdir()))

    def test_rollover_replaces_key_and_failed_validation_preserves_fragment(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            repo = Path(tempdir)
            peer_dir = repo / "system/vps01/ubuntu/wireguard/peers"
            peer_dir.mkdir(parents=True)
            target = peer_dir / "20-arrakis.conf"
            env = os.environ.copy()
            env["REPO_ROOT"] = str(repo)

            first = subprocess.run(
                [str(WRITER), "server01", VALID_PUBLIC_KEY, "10.8.0.3/32"],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(first.returncode, 0, first.stderr)

            rollover = subprocess.run(
                [str(WRITER), "server01", SECOND_PUBLIC_KEY, "10.8.0.3/32"],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(rollover.returncode, 0, rollover.stderr)
            rolled_content = target.read_text(encoding="utf-8")
            self.assertIn(f"PublicKey = {SECOND_PUBLIC_KEY}", rolled_content)

            rejected = subprocess.run(
                [
                    str(WRITER),
                    "server01",
                    NONCANONICAL_PUBLIC_KEY,
                    "10.8.0.3/32",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(target.read_text(encoding="utf-8"), rolled_content)
            self.assertFalse(list(peer_dir.glob(".20-arrakis.conf.tmp.*")))

    def test_every_non_heighliner_bootstrap_writes_fragment_after_tunnel_setup(self) -> None:
        self.assertEqual(len(BOOTSTRAPS), 8)
        targets = tuple(path for path in BOOTSTRAPS if path != HEIGHLINER)
        self.assertEqual(len(targets), 7)

        for path in targets:
            text = path.read_text(encoding="utf-8")
            self.assertIn("write_heighliner_peer_fragment() {", text, path)
            main = text[text.index("main() {") :]
            self.assertIn("\n  setup_wormlogic_vpn\n", main, path)
            self.assertIn("\n  write_heighliner_peer_fragment\n", main, path)
            self.assertLess(
                main.index("\n  setup_wormlogic_vpn\n"),
                main.index("\n  write_heighliner_peer_fragment\n"),
                path,
            )
            self.assertNotIn(
                "Add this peer under system/vps01/ubuntu/wireguard/peers/:",
                text,
                path,
            )
            self.assertIn("Public key:", text, path)
            self.assertIn("VPN IP:", text, path)

        self.assertNotIn(
            "write_heighliner_peer_fragment",
            HEIGHLINER.read_text(encoding="utf-8"),
        )

    def test_caladan_and_chapterhouse_use_sequential_peer_names_and_addresses(self) -> None:
        self.assertEqual(EXPECTED_PEERS["server03"][0], "80-caladan.conf")
        self.assertEqual(EXPECTED_PEERS["server04"][0], "90-chapterhouse.conf")

        chapterhouse = (
            REPO / "system/server04/ubuntu/bootstrap.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('default_vpn_ip="10.8.0.7/32"', chapterhouse)

        self.assertFalse((PEER_DIR / "80-caladan.conf").exists())
        self.assertFalse((PEER_DIR / "90-chapterhouse.conf").exists())


if __name__ == "__main__":
    unittest.main()
