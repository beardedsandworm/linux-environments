#!/usr/bin/env python3
"""Repository contracts for Wormlogic WireGuard client routing."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class WireGuardRoutingTests(unittest.TestCase):
    def test_arrakis_routes_the_complete_wormlogic_peer_subnet(self) -> None:
        bootstrap = (
            REPO / "system/server01/ubuntu/bootstrap.sh"
        ).read_text(encoding="utf-8")
        match = re.search(
            r"setup_wormlogic_vpn\(\) \{\n(?P<body>.*?)\n\}",
            bootstrap,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        body = match.group("body")
        self.assertIn('local vpn_allowed_ips="10.8.0.0/24"', body)
        self.assertNotIn('local vpn_allowed_ips="10.8.0.1/32"', body)

    def test_other_existing_clients_keep_their_current_hub_only_routes(self) -> None:
        for relative in (
            "system/server02/ubuntu/bootstrap.sh",
            "system/server03/ubuntu/bootstrap.sh",
            "system/server04/ubuntu/bootstrap.sh",
        ):
            bootstrap = (REPO / relative).read_text(encoding="utf-8")
            self.assertIn('local vpn_allowed_ips="10.8.0.1/32"', bootstrap, relative)


if __name__ == "__main__":
    unittest.main()
