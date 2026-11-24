#!/usr/bin/env bash
set -euo pipefail

vpn="${1:-$(cd "$(dirname "$0")/../.." && pwd)/laptop-vpn.sh}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/laptop-vpn-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
export LAPTOP_VPN_STATE="$test_dir/state"
export HOME="$test_dir/home"
export VPN_TEST_DENIED="$test_dir/denied"
mkdir -p "$LAPTOP_VPN_STATE" "$test_dir/bin" "$HOME"
for tool in bash basename cat chmod cmp cp cut dirname grep ln mkdir readlink rm sed tail tr; do
  ln -s "$(command -v "$tool")" "$test_dir/bin/$tool"
done
export PATH="$test_dir/bin"

cat >"$test_dir/bin/deny" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >>"$VPN_TEST_DENIED"
exit 1
SH
chmod +x "$test_dir/bin/deny"
for tool in curl ssh security networksetup sudo python3; do
  ln -s deny "$test_dir/bin/$tool"
done
cat >"$test_dir/bin/nc" <<'SH'
#!/bin/sh
if [ "$*" != '-z -w 1 127.0.0.1 18180' ]; then
  printf '%s\n' "$0 $*" >>"$VPN_TEST_DENIED"
  exit 1
fi
[ "${VPN_TEST_LISTEN:-0}" = 1 ]
SH
cat >"$test_dir/bin/scutil" <<'SH'
#!/bin/sh
if [ "$(cat)" != 'show State:/Network/Service/com.cisco.anyconnect/Proxies' ]; then
  printf '%s\n' 'unexpected scutil command' >>"$VPN_TEST_DENIED"
fi
printf '%s\n' 'No such key'
SH
chmod +x "$test_dir/bin/nc" "$test_dir/bin/scutil"

cat >"$LAPTOP_VPN_STATE/connection.json" <<'JSON'
{"relay":{"host":"relay.test","port":18400,"user":"test"},"local_socks_port":18180,"router":{"upstream_port":18181,"control_port":18190}}
JSON
cp "$LAPTOP_VPN_STATE/connection.json" "$test_dir/connection.before"

/bin/bash -n "$vpn"
printf '%s\n' 'PASS bash -n'

run_vpn() {
  /usr/bin/sandbox-exec -p '
(version 1)
(allow default)
(deny network*)
(deny process-exec
  (literal "/usr/bin/python3")
  (literal "/usr/bin/ssh")
  (literal "/usr/bin/curl")
  (literal "/usr/bin/security")
  (literal "/usr/sbin/networksetup")
  (literal "/usr/sbin/scutil")
  (literal "/usr/bin/sudo"))' "$vpn" "$@"
}

run_vpn status --json --no-ip | /usr/bin/python3 -c '
import json
import sys

assert json.load(sys.stdin) == {
    "loop": False, "socks": False, "exit_ip": None, "proxy": False,
    "cisco": False, "cisco_copy": None,
    "router": {"enabled": False, "running": False, "control_port": None},
    "via": None, "stopped": None, "notes": [],
}
'
cmp "$test_dir/connection.before" "$LAPTOP_VPN_STATE/connection.json"
[[ ! -e "$LAPTOP_VPN_STATE/routes.json" ]]
printf '%s\n' 'PASS vpn status --json --no-ip (VPN off, state untouched)'

sed 's/"router":{/"router":{"enabled":true,/' "$test_dir/connection.before" >"$LAPTOP_VPN_STATE/connection.json"
printf '%s\n' "$$" >"$LAPTOP_VPN_STATE/router.pid"
VPN_TEST_LISTEN=1 run_vpn status --no-ip --json | /usr/bin/python3 -c '
import json
import sys

status = json.load(sys.stdin)
assert status["socks"] and status["exit_ip"] is None
assert status["router"] == {"enabled": True, "running": True, "control_port": 18190}
'
rm "$LAPTOP_VPN_STATE/router.pid"
cp "$test_dir/connection.before" "$LAPTOP_VPN_STATE/connection.json"
printf '%s\n' 'PASS vpn status --json --no-ip (router port listening, exit IP lookup skipped)'

run_vpn routes >"$test_dir/routes.out"
grep -F 'anything not listed → vpn' "$test_dir/routes.out" >/dev/null
run_vpn routes --json | /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)["rules"]'
printf '%s\n' 'PASS vpn routes and vpn routes --json'

run_vpn check cli-validation.test >"$test_dir/check.out"
grep -F 'cli-validation.test → vpn' "$test_dir/check.out" >/dev/null
printf '%s\n' 'PASS vpn check'

run_vpn set cli-validation.test direct
run_vpn check cli-validation.test --json | /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)["route"] == "direct"'
run_vpn unset cli-validation.test
run_vpn check cli-validation.test --json | /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)["route"] == "vpn"'
printf '%s\n' 'PASS vpn set/unset and vpn check --json'

run_vpn exits --json | /usr/bin/python3 -c '
import json, sys
exits = json.load(sys.stdin)
assert exits["active"] == "relay"
assert [(entry["id"], entry["kind"]) for entry in exits["exits"]] == [("relay", "ssh")]
'
printf '%s\n' 'PASS vpn exits migrated the configured SSH relay'

if [[ -e "$VPN_TEST_DENIED" ]]; then
  cat "$VPN_TEST_DENIED" >&2
  exit 1
fi
printf '%s\n' 'PASS no network calls or system changes'
printf '%s\n' 'PASS CLI with Python absent from PATH and execution of /usr/bin/python3 denied'
