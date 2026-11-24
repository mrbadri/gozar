import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

CONF_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CONF_DIR))
import sitedomains
import vpnconf


class VpnConfTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.state = Path(temp.name)
        self.routes = self.state / "routes.json"
        self.connection = self.state / "connection.json"
        self.env = {**os.environ, "LAPTOP_VPN_STATE": str(self.state)}
        self.write_connection()
        self.routes.write_text(json.dumps({"rules": [
            {"name": "سایت", "route": "direct", "domains": ["example.com"]},
            {"name": "Iran", "route": "direct", "domains": ["ir"]},
            {"name": "Subdomains", "route": "direct", "domains": ["*.only.test"]},
            {"name": "Office", "route": "cisco", "without_cisco": "vpn",
             "domains": ["corp.test"], "hosts": ["CORP-MGMT01"]},
            {"name": "Disabled", "route": "direct", "enabled": False, "domains": ["off.test"]},
        ]}))

    def write_connection(self, **overrides):
        self.connection.write_text(json.dumps({
            "relay": {"host": "relay.test", "port": 18400, "user": "test"},
            "local_socks_port": 18180,
            "router": {"enabled": True, "upstream_port": 18181, "control_port": 18190},
            **overrides,
        }))

    def conf(self, *args, fails=False):
        result = subprocess.run([sys.executable, "-I", "-B", str(CONF_DIR / "vpnconf.py"), *args],
                                env=self.env, cwd=CONF_DIR, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1 if fails else 0, result.stderr)
        if fails:
            self.assertTrue(result.stderr.startswith("config error:"), result.stderr)
        return result.stdout

    def edit(self, *args):
        self.assertEqual(len(self.conf(*args).splitlines()), 1)
        data = json.loads(self.routes.read_text())
        self.assertEqual(data["_guide"], vpnconf.ROUTES_GUIDE)
        return data["rules"]

    def test_state_override(self):
        self.assertEqual(json.loads(self.conf("routes", "--json"))["path"], str(self.routes))
        self.assertIn("HOST=relay.test", self.conf("conn-env").splitlines())

    def test_router_ports_and_environment(self):
        self.conf("validate")
        env = dict(line.split("=", 1) for line in self.conf("conn-env").splitlines())
        for name, value in {"ROUTER_ENABLED": "1", "UPSTREAM_PORT": "18181", "CONTROL_PORT": "18190"}.items():
            self.assertEqual(env[name], value)
        self.write_connection(router={})
        env = dict(line.split("=", 1) for line in self.conf("conn-env").splitlines())
        self.assertEqual([env[k] for k in ("ROUTER_ENABLED", "UPSTREAM_PORT", "CONTROL_PORT")], ["0", "1081", "1090"])

    def test_router_validation(self):
        cases = [
            {"router": []}, {"router": {"enabled": "true"}}, {"router": {"other": 1}},
            {"router": {"control_port": 65536}}, {"router": {"upstream_port": True}},
            {"router": {"upstream_port": 18180}},
            {"router": {"upstream_port": 18190, "control_port": 18190}},
            {"local_socks_port": 18190},
        ]
        for case in cases:
            with self.subTest(case=case):
                self.write_connection(**case)
                self.conf("validate", fails=True)

    def test_router_bypass_uses_only_fixed_entries(self):
        self.assertEqual(self.conf("bypass", "--router", "--cisco").splitlines(), vpnconf.FIXED_DIRECT)

    def test_check_json(self):
        cases = [
            ("example.com", False, "direct", "سایت", "example.com", "direct"),
            ("https://www.example.com/path", False, "direct", "سایت", "example.com", "direct"),
            ("aparat.ir", False, "direct", "Iran", "*.ir", "direct"),
            ("a.only.test", False, "direct", "Subdomains", "*.only.test", "direct"),
            ("only.test", False, "vpn", None, None, None),
            ("corp-mgmt01", False, "vpn", "Office", "CORP-MGMT01", "cisco"),
            ("outside.test", False, "vpn", None, None, None),
            ("corp.test", False, "vpn", "Office", "corp.test", "cisco"),
            ("corp.test", True, "cisco", "Office", "corp.test", "cisco"),
        ]
        for site, cisco, route, rule, pattern, rule_route in cases:
            with self.subTest(site=site, cisco=cisco):
                raw = self.conf("check", site, "--json", *(["--cisco"] if cisco else []))
                self.assertEqual(json.loads(raw), {
                    "host": vpnconf.host_of(site), "route": route, "rule": rule, "pattern": pattern,
                    "rule_route": rule_route, "cisco": cisco,
                })
        self.assertIn("سایت", self.conf("check", "example.com", "--json"))

    def test_routes_json_includes_disabled_rules_in_order(self):
        report = json.loads(self.conf("routes", "--json", "--cisco"))
        self.assertTrue(report["cisco"])
        self.assertEqual([r["name"] for r in report["rules"]], ["سایت", "Iran", "Subdomains", "Office", "Disabled"])
        self.assertEqual(report["rules"][0]["effective"], "cisco")
        self.assertEqual(report["rules"][-1], {
            "name": "Disabled", "route": "direct", "without_cisco": None, "enabled": False, "note": None,
            "domains": ["off.test"], "hosts": [], "effective": "off",
        })

    def test_add_to_new_and_existing_rule(self):
        rules = self.edit("add-to", "Video", "vpn", "https://www.video.test/watch", "office-host")
        self.assertEqual(rules[-1], {"name": "Video", "route": "vpn", "domains": ["video.test"], "hosts": ["office-host"]})
        rules = self.edit("add-to", "video", "direct", "api.test")
        self.assertEqual(rules[-1]["domains"], ["video.test", "api.test"])
        self.assertEqual(rules[-1]["route"], "vpn")

    def test_rule_set_flags(self):
        self.assertEqual(self.edit("rule-set", "office", "--without-cisco", "direct")[3]["without_cisco"], "direct")
        self.assertNotIn("without_cisco", self.edit("rule-set", "office", "--without-cisco", "none")[3])
        self.assertEqual(self.edit("rule-set", "office", "--without-cisco", "vpn")[3]["without_cisco"], "vpn")
        office = self.edit("rule-set", "office", "--route", "direct")[3]
        self.assertEqual(office["route"], "direct")
        self.assertNotIn("without_cisco", office)
        self.assertFalse(self.edit("rule-set", "office", "--enabled", "false")[3]["enabled"])
        self.assertTrue(self.edit("rule-set", "office", "--enabled", "true")[3]["enabled"])
        self.assertEqual(self.edit("rule-set", "office", "--rename", "Work")[3]["name"], "Work")
        self.assertEqual(self.edit("rule-set", "work", "--note", "یادداشت")[3]["note"], "یادداشت")

    def test_rule_move_and_delete(self):
        self.assertEqual(self.edit("rule-move", "office", "--to", "0")[0]["name"], "Office")
        self.assertEqual(self.edit("rule-move", "office", "--to", "4")[-1]["name"], "Office")
        self.assertNotIn("Office", [rule["name"] for rule in self.edit("rule-delete", "office")])

    def test_invalid_edits_leave_routes_unchanged(self):
        starting_routes = self.routes.read_bytes()
        for args in (
            ("add-to", "Test", "invalid", "new.test"), ("add-to", "Test", "vpn", "bad host"),
            ("rule-set", "office", "--enabled", "yes"), ("rule-set", "missing", "--note", "x"),
            ("rule-set", "office", "--rename", "Iran"), ("rule-delete", "missing"),
            ("rule-move", "Iran", "--to", "5"), ("rule-move", "Iran", "--to", "no"),
        ):
            with self.subTest(args=args):
                self.assertEqual(self.conf(*args, fails=True), "")
                self.assertEqual(self.routes.read_bytes(), starting_routes)

    def test_domains_json_suggestions_match_add(self):
        listed = {"name": "example", "domains": ["example.com"], "country": 0, "skipped": []}
        hosts = ["api.example.com", "assets.extra.test", "cdn.google.com"]
        with patch.multiple(vpnconf, STATE=self.state, ROUTES=self.routes, CONNECTION=self.connection), \
                patch.object(sitedomains, "socks_port", return_value=18180), \
                patch.object(sitedomains, "geosite", return_value=listed), \
                patch.object(sitedomains, "live_hosts", return_value=hosts), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(sitedomains.main(["example.com", "--json", "--all"]), 0)
            self.assertEqual(json.loads(output.getvalue()), {
                "site": "example.com", "title": "Example", "via": "vpn",
                "listed": {"name": "example", "domains": [{"domain": "example.com", "route": "direct"}]},
                "live": [{"host": h, "route": r} for h, r in zip(hosts, ["direct", "vpn", "vpn"])],
                "suggested": ["example.com", "extra.test", "cdn.google.com"],
            })
            self.assertEqual(sitedomains.main(["example.com", "--add", "vpn", "--all"]), 0)
        self.assertEqual(json.loads(self.routes.read_text())["rules"][-1]["domains"],
                         ["example.com", "extra.test", "cdn.google.com"])

    def test_domains_json_unavailable_sources_and_add_error(self):
        with patch.multiple(vpnconf, STATE=self.state, ROUTES=self.routes, CONNECTION=self.connection), \
                patch.object(sitedomains, "socks_port", return_value=None) as socks, \
                patch.object(sitedomains, "geosite", return_value=None), \
                patch.object(sitedomains, "live_hosts") as live, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(sitedomains.main(["unknown.test", "--json", "--quick"]), 0)
            self.assertEqual(json.loads(output.getvalue()), {
                "site": "unknown.test", "title": "Unknown", "via": "direct", "listed": None,
                "live": None, "suggested": [],
            })
            live.assert_not_called()
            socks.reset_mock()
            with self.assertRaises(SystemExit) as error, contextlib.redirect_stderr(io.StringIO()) as stderr:
                sitedomains.main(["unknown.test", "--json", "--add", "vpn"])
            self.assertEqual(error.exception.code, 2)
            self.assertIn("--json cannot be used with --add", stderr.getvalue())
            socks.assert_not_called()
