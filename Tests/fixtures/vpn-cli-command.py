#!/usr/bin/python3
"""Stub commands for the CLI router-mode test, dispatched by symlink name."""

import json
import os
import sys
from pathlib import Path


name = Path(sys.argv[0]).name
args = sys.argv[1:]
commands = sys.stdin.read().splitlines() if (name, args) in (
    ("scutil", []), ("sudo", ["scutil"])
) else []
with open(os.environ["GOZAR_TEST_CALLS"], "a") as log:
    log.write(json.dumps({"name": name, "args": args, "stdin": commands, "pid": os.getpid()}) + "\n")

cisco_key = "State:/Network/Service/com.cisco.anyconnect/Proxies"
cisco_copy = Path(os.environ["LAPTOP_VPN_STATE"]) / "fixture-cisco-copy"
service = "Wi-Fi"

if name == "ssh" and args[:3] == ["-N", "-D", "127.0.0.1:18281"]:
    script = Path(__file__).resolve().with_name("fake_socks.py")
    os.execv(sys.executable, [sys.executable, str(script), "18281"])
elif name == "networksetup":
    replies = {
        ("-listallnetworkservices",): "An asterisk (*) denotes a disabled network service.\nWi-Fi",
        ("-listallhardwareports",): "Hardware Port: Wi-Fi\nDevice: en0",
        ("-getsocksfirewallproxy", service): "Enabled: No\nServer: 127.0.0.1\nPort: 18282",
        ("-getproxybypassdomains", service): "before.test",
    }
    if tuple(args) in replies:
        print(replies[tuple(args)])
        sys.exit(0)
    if len(args) >= 3 and args[1] == service and args[0] in (
        "-setsocksfirewallproxy", "-setsocksfirewallproxystate", "-setproxybypassdomains"
    ):
        sys.exit(0)
elif name == "scutil" and not args and commands == [f"show {cisco_key}"]:
    enabled = cisco_copy.read_text() if cisco_copy.exists() else "0"
    print(f"<dictionary> {{\n  SOCKSEnable : {enabled}\n}}")
    sys.exit(0)
elif name == "sudo":
    if args == ["-n", "true"]:
        sys.exit(1)
    if args == ["-A", "-v"]:
        sys.exit(0)
    if args == ["scutil"] and len(commands) >= 3 and commands[0] == f"get {cisco_key}" and commands[-1] == f"set {cisco_key}":
        if commands[1] in ("d.add SOCKSEnable # 0", "d.add SOCKSEnable # 1"):
            cisco_copy.write_text(commands[1][-1])
            sys.exit(0)
elif name == "security" and args == ["find-generic-password", "-s", "vpnuser-relay", "-a", "fixture"]:
    sys.exit(0)
elif name == "curl" and args == [
    "-s", "--max-time", "10", "--noproxy", "", "--socks5-hostname",
    "127.0.0.1:18280", "https://api.ipify.org"
]:
    print("192.0.2.1")
    sys.exit(0)

with open(os.environ["GOZAR_TEST_CALLS"], "a") as log:
    log.write(json.dumps({"unexpected": name, "args": args, "stdin": commands}) + "\n")
sys.exit(f"Unexpected test command: {name} {args}")
