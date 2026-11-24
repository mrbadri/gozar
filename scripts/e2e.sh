#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product vpn-router
swift build -c release --product gozarctl
scripts/fetch-xray.sh

umask 077
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gozar-e2e.XXXXXX")"
router_pid="" upstream_pid="" origin_pid="" events_pid=""
cleanup() {
    status=$?
    trap - EXIT
    if [[ "$status" -ne 0 ]]; then
        for log in router.out upstream.out origin.out router.log connections.json cli/state/ssh.log cli/state/router.log; do
            if [[ -s "$tmp/$log" ]]; then tail -n 8 "$tmp/$log" >&2; fi
        done
    fi
    for pid in "$events_pid" "$router_pid" "$upstream_pid" "$origin_pid"; do
        if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
    done
    for pid in "$events_pid" "$router_pid" "$upstream_pid" "$origin_pid"; do
        if [[ -n "$pid" ]]; then wait "$pid" 2>/dev/null || true; fi
    done
    rm -rf "$tmp"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# PATH stubs handle the CLI calls. The router's absolute scutil path and any
# future absolute calls to the real tools must also be blocked.
profile="$tmp/loopback.sb"
cat >"$profile" <<'SB'
(version 1)
(allow default)
(deny process-exec
    (literal "/usr/bin/ssh")
    (literal "/usr/bin/security")
    (literal "/usr/sbin/networksetup")
    (literal "/usr/sbin/scutil")
    (literal "/usr/bin/sudo"))
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
SB

cli_dir="$PWD/cli/laptop-vpn.d"
/usr/bin/python3 -m unittest discover -s "$cli_dir/tests" -v
"$cli_dir/tests/test_cli.sh"

export LAPTOP_VPN_STATE="$tmp"
ulimit -n 4096
mkdir "$tmp/www"
printf '%s\n' '{"rules":[{"name":"Loopback","route":"direct","hosts":["localhost"]}]}' > "$tmp/routes.json"
cp "$tmp/routes.json" "$tmp/routes.good"
printf '%s\n' '{"relay":{"host":"127.0.0.1","port":18088,"user":"fixture"},"local_socks_port":18080,"router":{"enabled":true,"upstream_port":18081,"control_port":18090}}' > "$tmp/connection.json"
printf '%s\n' small > "$tmp/www/small"
dd if=/dev/urandom of="$tmp/www/big" bs=1000000 count=20 2>/dev/null

/usr/bin/python3 Tests/fixtures/fake_socks.py 18081 > "$tmp/upstream.out" 2>&1 &
upstream_pid=$!
/usr/bin/python3 -m http.server 18088 --bind 127.0.0.1 --directory "$tmp/www" > "$tmp/origin.out" 2>&1 &
origin_pid=$!
/usr/bin/sandbox-exec -f "$profile" .build/release/vpn-router \
    --state "$tmp" --listen-port 18080 --upstream-port 18081 --control-port 18090 --no-probes > "$tmp/router.out" 2>&1 &
router_pid=$!

wait_for() {
    for _ in {1..100}; do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    printf 'Timed out waiting for %s\n' "$1" >&2
    return 1
}
origin_ready() {
    kill -0 "$origin_pid" 2>/dev/null && curl -q -fsS --noproxy '*' --max-time 1 http://127.0.0.1:18088/small >/dev/null 2>&1
}
router_ready() {
    kill -0 "$router_pid" 2>/dev/null && [[ -s "$tmp/router.json" ]]
}
wait_for origin_ready
wait_for grep -q '^ready on 18081$' "$tmp/upstream.out"
wait_for router_ready

/usr/bin/sandbox-exec -f "$profile" /usr/bin/python3 - "$tmp" <<'PY'
import os
import shutil
import subprocess
import sys
from pathlib import Path

state = Path(sys.argv[1]) / "conflict"
state.mkdir()
shutil.copyfile(state.parent / "connection.json", state / "connection.json")
shutil.copyfile(state.parent / "routes.json", state / "routes.json")
result = subprocess.run(
    [".build/release/vpn-router", "--state", str(state), "--listen-port", "18091", "--no-probes"],
    env=dict(os.environ, LAPTOP_VPN_STATE=str(state)), capture_output=True, text=True, timeout=5,
)
assert result.returncode == 1, result.stderr
assert "Cannot listen on 127.0.0.1:18090:" in result.stderr, result.stderr
assert not (state / "router.json").exists() and not (state / "router.token").exists()
print("An occupied control port exited 1 with a listener error and left no discovery files")
PY

api_url="http://127.0.0.1:18090"
api() { curl -q -fsS --noproxy '*' --max-time 10 -H "@$tmp/auth-header" "$@"; }
socks() { curl -q -fsS --noproxy '' --max-time 15 --socks5-hostname 127.0.0.1:18080 "$@"; }
[[ "$(stat -f '%Lp' "$tmp/router.token")" == 600 ]]
[[ "$(wc -c < "$tmp/router.token" | tr -d ' ')" == 65 ]]
printf 'Authorization: Bearer %s\n' "$(cat "$tmp/router.token")" > "$tmp/auth-header"
[[ "$(curl -q -sS --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "$api_url/v1/status")" == 401 ]]
printf 'Control API rejected unauthenticated request with 401 and token mode is 0600\n'

speed="$(socks -o "$tmp/direct" -w '%{speed_download}' http://localhost:18088/big)"
socks -o "$tmp/vpn" http://vpn.test:18088/big
hash() { LC_ALL=C /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }
original_hash="$(hash "$tmp/www/big")"
[[ "$(hash "$tmp/direct")" == "$original_hash" && "$(hash "$tmp/vpn")" == "$original_hash" ]]
printf 'Direct and VPN SHA-256 matched for both 20,000,000-byte downloads\n'
printf '%s\n' "$speed" | awk '{
    printf "Direct loopback download reached %.1f MB/s (minimum 50 MB/s)\n", $1 / 1000000
    if ($1 < 50000000) exit 1
}'
[[ "$(sed -n '/^CONNECT /p' "$tmp/upstream.out")" == 'CONNECT vpn.test:18088' ]]
printf 'Fake upstream saw exactly one domain-form CONNECT for vpn.test:18088\n'

bulk_closed() {
    api "$api_url/v1/connections" > "$tmp/connections.json" &&
        /usr/bin/python3 -c '
import json, sys
rows = {row["host"]: row for row in json.load(sys.stdin)}
for host, route in (("localhost", "direct"), ("vpn.test", "vpn")):
    row = rows.get(host, {})
    assert row.get("state") == "closed" and row["route"] == route
    assert row["bytes_down"] >= 20_000_000 and row["bytes_up"] > 0 and row["error"] is None
    assert row["connect_ms"] >= 0 and row["ended_at"] is not None
' < "$tmp/connections.json" 2>/dev/null
}
wait_for bulk_closed
printf 'Connection API reported direct and VPN routes and at least 20,000,000 bytes down each\n'

: > "$tmp/event-headers"
curl -q -fsSN --noproxy '*' --max-time 10 -H "@$tmp/auth-header" -D "$tmp/event-headers" \
    "$api_url/v1/events" > "$tmp/events" 2>"$tmp/events.error" &
events_pid=$!
wait_for grep -iq '^content-type: text/event-stream' "$tmp/event-headers"
socks http://localhost:18088/small > "$tmp/event-request"
cmp "$tmp/event-request" "$tmp/www/small"
wait_for grep -q '^data: .*"state":"closed".*}$' "$tmp/events"
/usr/bin/python3 -c '
import json, sys
events = {}
for packet in sys.stdin.read().split("\n\n"):
    name, _, payload = packet.partition("\ndata: ")
    if name in ("event: open", "event: close"):
        events[name] = json.loads(payload)
opened, closed = events["event: open"], events["event: close"]
assert opened["id"] == closed["id"]
assert opened["host"] == closed["host"] == "localhost"
assert opened["state"] == "open" and closed["state"] == "closed"
' < "$tmp/events"
kill "$events_pid"
wait "$events_pid" 2>/dev/null || true
events_pid=""
printf 'SSE delivered matching open and close events for a third request\n'

/usr/bin/python3 - "$router_pid" <<'PY'
import asyncio
import socket
import struct
import subprocess
import sys

PARALLEL = 300
ROUTER = 18080
ORIGIN = 18089
REQUEST = b"GET /small HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
RESPONSE = b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nsmall\n"
CONNECT = bytes((5, 1, 0, 1, 127, 0, 0, 1)) + struct.pack("!H", ORIGIN)
OK = bytes((5, 0, 0, 1)) + bytes(6)
PAYLOAD = b"client can send after the other side finishes"


def rss():
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", sys.argv[1]], text=True))


async def begin():
    reader, writer = await asyncio.open_connection("127.0.0.1", ROUTER)
    writer.write(b"\x05\x01\x00")
    await writer.drain()
    assert await reader.readexactly(2) == b"\x05\x00"
    return reader, writer


async def parallel_requests():
    release = asyncio.Event()
    accepted = asyncio.Queue()

    async def respond(reader, writer):
        try:
            assert await reader.readuntil(b"\r\n\r\n") == REQUEST
            accepted.put_nowait(None)
            await release.wait()
            writer.write(RESPONSE)
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    async def request():
        reader, writer = await begin()
        try:
            # Put the HTTP bytes in the same TCP write as the SOCKS request.
            writer.write(CONNECT + REQUEST)
            await writer.drain()
            assert await reader.readexactly(10) == OK
            assert await reader.read() == RESPONSE
        finally:
            writer.close()
            await writer.wait_closed()

    peak = rss()
    async with await asyncio.start_server(respond, "127.0.0.1", ORIGIN, backlog=512, reuse_address=True):
        tasks = []
        try:
            # Let the listeners drain their accept queues between bursts.
            for start in range(0, PARALLEL, 50):
                count = min(50, PARALLEL - start)
                tasks.extend(asyncio.create_task(request()) for _ in range(count))
                await asyncio.wait_for(asyncio.gather(*(accepted.get() for _ in range(count))), 5)
            # Every request is in flight and the origin has sent no responses yet.
            peak = max(peak, rss())
            release.set()
            while not all(task.done() for task in tasks):
                peak = max(peak, rss())
                await asyncio.sleep(0.02)
            await asyncio.gather(*tasks)
        finally:
            release.set()
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    peak = max(peak, rss())
    assert peak * 1024 < 150_000_000, f"Router RSS {peak} KiB exceeded the 150 MB cap"
    print(f"300 simultaneous HTTP requests succeeded; peak router RSS {peak} KiB (ps -o rss)")


async def half_closes():
    done = asyncio.get_running_loop().create_future()

    async def origin(reader, writer):
        try:
            mode = await reader.readexactly(1)
            if mode == b"d":
                assert await reader.read() == PAYLOAD
            writer.write(b"remote response")
            await writer.drain()
            writer.write_eof()
            if mode == b"u":
                assert await reader.read() == PAYLOAD
            done.set_result(None)
        except Exception as error:
            done.set_exception(error)
        finally:
            writer.close()
            await writer.wait_closed()

    async with await asyncio.start_server(origin, "127.0.0.1", ORIGIN, reuse_address=True):
        reader, writer = await begin()
        writer.write(CONNECT + b"d" + PAYLOAD)
        await writer.drain()
        writer.write_eof()
        assert await reader.readexactly(10) == OK
        assert await reader.read() == b"remote response"
        await done
        writer.close()
        await writer.wait_closed()

        done = asyncio.get_running_loop().create_future()
        reader, writer = await asyncio.open_connection("127.0.0.1", ROUTER)
        request = b"\x04\x01" + struct.pack("!H", ORIGIN) + b"\x00\x00\x00\x01\x00localhost\x00"
        writer.write(request + b"u")
        await writer.drain()
        assert await reader.readexactly(8) == b"\x00\x5a" + bytes(6)
        assert await reader.read() == b"remote response"
        writer.write(PAYLOAD)
        await writer.drain()
        writer.write_eof()
        await done
        writer.close()
        await writer.wait_closed()

    print("SOCKS5 and SOCKS4a preserved pipelined bytes and both directions of TCP half-close")


async def reset_closes_other_side():
    done = asyncio.get_running_loop().create_future()

    async def origin(reader, writer):
        try:
            assert await reader.read() == b""
            done.set_result(None)
        except Exception as error:
            done.set_exception(error)
        finally:
            writer.close()
            await writer.wait_closed()

    async with await asyncio.start_server(origin, "127.0.0.1", ORIGIN, reuse_address=True):
        reader, writer = await begin()
        writer.write(CONNECT)
        await writer.drain()
        assert await reader.readexactly(10) == OK
        writer.get_extra_info("socket").setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        writer.transport.abort()
        await done

    print("A client TCP reset closed the idle outbound connection")


async def main():
    await asyncio.wait_for(parallel_requests(), 30)
    await asyncio.wait_for(half_closes(), 10)
    await asyncio.wait_for(reset_closes_other_side(), 5)


asyncio.run(main())
PY

api "$api_url/v1/status" > "$tmp/status.json"
api "$api_url/v1/domains" > "$tmp/domains.json"
/usr/bin/python3 - "$tmp" <<'PY'
import json
import sys
from pathlib import Path

folder = Path(sys.argv[1])
status = json.loads((folder / "status.json").read_text())
domains = json.loads((folder / "domains.json").read_text())
assert status["listen_port"] == 18080 and status["upstream_port"] == 18081 and status["upstream_up"]
assert status["total"] == 306 and status["probes"] == []
assert status["totals"]["direct"]["connections"] == 305 and status["totals"]["vpn"]["connections"] == 1
assert domains[0]["bytes_down"] >= 20_000_000 and domains[1]["bytes_down"] >= 20_000_000
assert {row["domain"] for row in domains} == {"localhost", "vpn.test", "127.0.0.1"}
PY

printf '%s\n' '{"rules":[{"name":"Test domain","route":"direct","domains":["test"]}]}' > "$tmp/routes.new"
mv "$tmp/routes.new" "$tmp/routes.json"
[[ "$(api -X POST -o /dev/null -w '%{http_code}' "$api_url/v1/reload")" == 204 ]]
route_is_direct() {
    api "$api_url/v1/check?host=other.test" | /usr/bin/python3 -c '
import json, sys
state = json.load(sys.stdin)
assert state["route"] == ("cisco" if state["cisco_up"] else "direct") and state["rule"] == "Test domain"
'
}
route_is_direct
printf '{\n' > "$tmp/routes.new"
mv "$tmp/routes.new" "$tmp/routes.json"
rules_error() {
    api "$api_url/v1/status" | /usr/bin/python3 -c '
import json, sys
sys.exit(0 if bool(json.load(sys.stdin)["rules_error"]) else 1)
'
}
wait_for rules_error
route_is_direct
mv "$tmp/routes.good" "$tmp/routes.json"
[[ "$(api -X POST -o /dev/null -w '%{http_code}' "$api_url/v1/reload")" == 204 ]]
printf 'Status and domains matched traffic; malformed rules kept the last good configuration\n'

kill "$upstream_pid"
wait "$upstream_pid" 2>/dev/null || true
upstream_pid=""
if socks http://offline.test:18088/small > /dev/null 2>"$tmp/offline.error"; then
    printf 'An offline upstream unexpectedly passed the request\n' >&2
    exit 1
fi
failure_recorded() {
    api "$api_url/v1/connections?limit=10" | /usr/bin/python3 -c '
import json, sys
rows = json.load(sys.stdin)
sys.exit(0 if any(row["host"] == "offline.test" and row["state"] == "failed"
                  and row["route"] == "vpn" and row["error"] for row in rows) else 1)
'
}
wait_for failure_recorded
grep -q '✗ offline.test:18088 \[vpn\]' "$tmp/router.log"
printf 'Unavailable upstream returned a SOCKS failure and logged the failed connection\n'

kill -TERM "$router_pid"
wait "$router_pid"
router_pid=""
[[ ! -e "$tmp/router.json" ]]
printf 'SIGTERM exited 0 and removed router.json\n'
printf 'Router e2e passed on loopback ports 18080, 18081, 18088, 18089, 18090 and 18091 with probes disabled\n'

(
    cli="$tmp/cli"
    vpn_cli="$PWD/cli/laptop-vpn.sh"
    cli_bin="$cli/bin"
    real_router="$PWD/.build/release/vpn-router"
    export LAPTOP_VPN_STATE="$cli/state"
    export HOME="$cli/home"
    export GOZAR_TEST_CALLS="$cli/calls.jsonl"
    export GOZAR_TEST_ROUTER="$real_router"
    export XRAY_BIN="$PWD/.build/xray/xray"
    export PATH="$cli_bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export SUDO_ASKPASS="$PWD/Resources/gozar-askpass"
    mkdir -p "$HOME" "$LAPTOP_VPN_STATE" "$cli_bin"
    for name in ssh networksetup scutil sudo security curl; do
        ln -s "$PWD/Tests/fixtures/vpn-cli-command.py" "$cli_bin/$name"
        [[ "$(command -v "$name")" == "$cli_bin/$name" && -x "$cli_bin/$name" ]]
    done
    cat >"$cli_bin/vpn-router" <<'SH'
#!/bin/sh
exec "$GOZAR_TEST_ROUTER" "$@" --no-probes
SH
    chmod +x "$cli_bin/vpn-router"

    /usr/bin/sandbox-exec -f "$profile" /usr/bin/python3 - <<'PY'
import subprocess

for path in ("/usr/bin/ssh", "/usr/sbin/networksetup", "/usr/sbin/scutil", "/usr/bin/sudo"):
    try:
        subprocess.run([path], stdin=subprocess.DEVNULL, capture_output=True, timeout=2)
    except PermissionError:
        continue
    raise SystemExit(f"Fixture sandbox allowed execution of {path}")
PY
    printf 'Sandbox denied execution of real ssh, networksetup, scutil and sudo\n'

    vpn() { /usr/bin/sandbox-exec -f "$profile" "$vpn_cli" "$@" </dev/null; }
    watch_pid="" vpn_pgid="" xray_server_pid="" tls_pid=""
    cli_cleanup() {
        result=$?
        if [[ -n "$watch_pid" ]]; then
            kill -- "-$watch_pid" 2>/dev/null || true
            wait "$watch_pid" 2>/dev/null || true
        fi
        if [[ -n "$vpn_pgid" || -e "$LAPTOP_VPN_STATE/loop.pid" || -e "$LAPTOP_VPN_STATE/router.pid" ]]; then
            vpn off >&2 || kill -- "-$vpn_pgid" 2>/dev/null || true
        fi
        for pid in "$xray_server_pid" "$tls_pid"; do
            if [[ -n "$pid" ]]; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        done
        if [[ "$result" -ne 0 ]]; then
            for log in on.out off.out status.json watch.out top.out calls.jsonl server.log tls.log exit-test.json; do
                if [[ -s "$cli/$log" ]]; then tail -n 12 "$cli/$log" >&2; fi
            done
        fi
        exit "$result"
    }
    trap cli_cleanup EXIT
    printf '%s\n' '{"relay":{"host":"127.0.0.1","port":18284,"user":"fixture"},"local_socks_port":18280,"router":{"enabled":true,"upstream_port":18281,"control_port":18290}}' > "$LAPTOP_VPN_STATE/connection.json"
    printf '%s\n' '{"rules":[{"name":"Separate direct rule","route":"direct","domains":["direct.test"]}]}' > "$LAPTOP_VPN_STATE/routes.json"
    set -m
    /usr/bin/sandbox-exec -f "$profile" "$vpn_cli" on </dev/null > "$cli/on.out" &
    vpn_pgid=$!
    wait "$vpn_pgid"
    set +m
    grep -qx 'connected — exit IP 192.0.2.1' "$cli/on.out"
    wait_for test -s "$LAPTOP_VPN_STATE/router.json"
    vpn status --json > "$cli/status.json"
    /usr/bin/python3 - "$cli/status.json" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text())
assert status["router"] == {"enabled": True, "running": True, "control_port": 18290}, status
assert status["loop"] and status["socks"] and status["proxy"] and status["cisco_copy"], status
assert status["exit_ip"] == "192.0.2.1", status
PY
    cmp "$tmp/www/small" <(/usr/bin/curl -q -fsS --noproxy '' --max-time 5 \
        --socks5-hostname 127.0.0.1:18280 http://cli-router.test:18088/small)
    wait_for grep -Fq '→ cli-router.test:18088 [vpn]' "$LAPTOP_VPN_STATE/router.log"
    grep -q 'CONNECT cli-router.test:18088' "$LAPTOP_VPN_STATE/ssh.log"
    printf '%s\n' '00:00:01 → ssh-only.test:18088' >> "$LAPTOP_VPN_STATE/ssh.log"
    vpn top > "$cli/top.out"
    [[ "$(awk '{$1=$1; print}' "$cli/top.out")" == '1 cli-router.test' ]]
    set -m
    /usr/bin/sandbox-exec -f "$profile" "$vpn_cli" watch </dev/null > "$cli/watch.out" 2>&1 &
    watch_pid=$!
    wait_for grep -Fq '→ cli-router.test:18088 [vpn]' "$cli/watch.out"
    if grep -q 'ssh-only.test' "$cli/watch.out"; then
        printf 'CLI watch read the SSH log in router mode\n' >&2
        exit 1
    fi
    kill -- "-$watch_pid"
    wait "$watch_pid" 2>/dev/null || true
    watch_pid=""
    set +m
    printf 'CLI on, status, watch and top passed with live loopback traffic through the router and SSH stub\n'

    ssh_supervisor="$(cat "$LAPTOP_VPN_STATE/loop.pid")"
    router_supervisor="$(cat "$LAPTOP_VPN_STATE/router.pid")"
    router_child="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' < "$LAPTOP_VPN_STATE/router.json")"
    ssh_child="$(/usr/bin/python3 -c 'import json,sys; print(next(c["pid"] for c in map(json.loads, sys.stdin) if c["name"] == "ssh"))' < "$GOZAR_TEST_CALLS")"
    for pid in "$ssh_supervisor" "$router_supervisor" "$ssh_child" "$router_child"; do kill -0 "$pid"; done
    vpn off > "$cli/off.out"
    grep -qx 'disconnected' "$cli/off.out"
    for pid in "$ssh_supervisor" "$router_supervisor" "$ssh_child" "$router_child"; do
        if kill -0 "$pid" 2>/dev/null; then
            printf 'Process %s survived vpn off\n' "$pid" >&2
            exit 1
        fi
    done
    for file in loop.pid router.pid router.json proxy-before; do
        [[ ! -e "$LAPTOP_VPN_STATE/$file" ]]
    done
    for port in 18280 18281 18290; do
        if nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
            printf 'Port %s survived vpn off\n' "$port" >&2
            exit 1
        fi
    done
    vpn_pgid=""
    printf 'CLI off stopped both supervisors and children and closed ports 18280, 18281 and 18290\n'

    /usr/bin/python3 - "$GOZAR_TEST_CALLS" <<'PY'
import json
import sys
from pathlib import Path

calls = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert not any("unexpected" in call for call in calls), calls

def args(name):
    return [call["args"] for call in calls if call["name"] == name]

ssh, = args("ssh")
assert ssh[:3] == ["-N", "-D", "127.0.0.1:18281"] and ssh[-1] == "fixture@127.0.0.1", ssh
assert len(args("security")) == 1 and len(args("curl")) == 2
fixed = ["127.0.0.1", "localhost", "*.local", "169.254.0.0/16", "10.0.0.0/8",
         "172.16.0.0/12", "192.168.0.0/16", "<local>"]
assert args("networksetup") == [
    ["-listallnetworkservices"], ["-listallhardwareports"],
    *[["-getsocksfirewallproxy", "Wi-Fi"]] * 3,
    ["-getproxybypassdomains", "Wi-Fi"],
    ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "18280"],
    ["-setproxybypassdomains", "Wi-Fi", *fixed],
    ["-setsocksfirewallproxystate", "Wi-Fi", "on"],
    ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "18282"],
    ["-setproxybypassdomains", "Wi-Fi", "before.test"],
    ["-setsocksfirewallproxystate", "Wi-Fi", "off"],
], args("networksetup")
key = "State:/Network/Service/com.cisco.anyconnect/Proxies"
assert [call["stdin"] for call in calls if call["name"] == "scutil"] == [[f"show {key}"]] * 4
assert args("sudo") == [["-n", "true"], ["-A", "-v"], ["scutil"]] * 2, args("sudo")
assert [call["stdin"] for call in calls if call["name"] == "sudo" and call["args"] == ["scutil"]] == [
    [f"get {key}", "d.add SOCKSEnable # 1", "d.add SOCKSProxy 127.0.0.1", "d.add SOCKSPort # 18280",
     "d.add ExceptionsList * " + " ".join(fixed), f"set {key}"],
    [f"get {key}", "d.add SOCKSEnable # 0", "d.add ExceptionsList * before.test", f"set {key}"],
]
PY
    printf 'CLI router-mode e2e passed with the expected SSH, system proxy, Cisco and sudo askpass calls recorded by stubs\n'

    ctl="$PWD/.build/release/gozarctl"
    xray_test() {
        local label=$1 config=$2 output
        if ! output=$(/usr/bin/sandbox-exec -f "$profile" "$XRAY_BIN" run -test -c "$config" 2>&1); then
            printf '%s\n' "$output" >&2
            return 1
        fi
        [[ "$output" == *'Configuration OK.'* ]]
        printf 'Xray 26.10.31 run -test -c %s (%s): Configuration OK.\n' "${config##*/}" "$label"
    }
    mkdir "$cli/fixtures"
    for fixture in Tests/fixtures/links/*.link; do
        fixture_id=$(LAPTOP_VPN_STATE="$cli/fixtures" "$ctl" exit-add "$(cat "$fixture")")
        LAPTOP_VPN_STATE="$cli/fixtures" "$ctl" xray-config "$fixture_id" --port 18442 >"$cli/client.json"
        xray_test "${fixture##*/}" "$cli/client.json"
    done

    # Xray's server fixture redirects both exit-test probes to this HTTPS origin.
    cat >"$cli/tls.cnf" <<'CONF'
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = speed.cloudflare.com
[extensions]
subjectAltName = DNS:speed.cloudflare.com
basicConstraints = critical,CA:TRUE
CONF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$cli/tls.cnf" \
        -keyout "$cli/key.pem" -out "$cli/cert.pem" >"$cli/cert.log" 2>&1
    export CURL_CA_BUNDLE="$cli/cert.pem"
    /usr/bin/python3 Tests/fixtures/xray-loopback.py serve "$cli" >"$cli/tls.log" 2>&1 &
    tls_pid=$!
    wait_for grep -q '^TLS ready on 18444$' "$cli/tls.log"

    for mode in plain encrypted; do
        /usr/bin/python3 Tests/fixtures/xray-loopback.py "$mode" "$XRAY_BIN" "$cli"
        xray_test "$mode VLESS server" "$cli/xray-server.json"
        /usr/bin/sandbox-exec -f "$profile" "$XRAY_BIN" run -c "$cli/xray-server.json" >"$cli/server.log" 2>&1 &
        xray_server_pid=$!
        xray_ready() { nc -z -w 1 127.0.0.1 18443 >/dev/null 2>&1; }
        wait_for xray_ready
        id=$(vpn exit add "$(cat "$cli/vless.link")")
        "$ctl" xray-config "$id" --port 18281 >"$cli/client.json"
        xray_test "$mode VLESS client" "$cli/client.json"
        keychain_calls=$(grep -c '"name": "security"' "$GOZAR_TEST_CALLS")
        if [[ "$mode" == plain ]]; then
            vpn exit use "$id"
            [[ ! -e "$LAPTOP_VPN_STATE/xray.json" ]]
            vpn status --json --no-ip >/dev/null
            [[ ! -e "$LAPTOP_VPN_STATE/xray.json" ]]
            set -m
            /usr/bin/sandbox-exec -f "$profile" "$vpn_cli" on </dev/null >"$cli/on.out" &
            vpn_pgid=$!
            wait "$vpn_pgid"
            set +m
        else
            vpn exit use "$id" --json | /usr/bin/python3 -c 'import json, sys; assert json.load(sys.stdin)["active"] == sys.argv[1]' "$id"
        fi
        [[ "$(stat -f '%Lp' "$LAPTOP_VPN_STATE/xray.json")" == 600 ]]
        before=$(stat -f '%i:%m' "$LAPTOP_VPN_STATE/xray.json")
        vpn status --json --no-ip >/dev/null
        [[ "$(stat -f '%i:%m' "$LAPTOP_VPN_STATE/xray.json")" == "$before" ]]
        [[ "$(grep -c '"name": "security"' "$GOZAR_TEST_CALLS")" == "$keychain_calls" ]]
        cmp "$tmp/www/small" <(/usr/bin/curl -q -fsS --noproxy '' --max-time 5 \
            --socks5-hostname 127.0.0.1:18280 http://xray-loopback.test:18088/small)
        wait_for grep -Fq '→ xray-loopback.test:18088 [vpn]' "$LAPTOP_VPN_STATE/router.log"
        printf 'CLI routed HTTP through real %s VLESS on loopback [vpn]\n' "$mode"
        vpn exit test "$id" --json --seconds 5 >"$cli/exit-test.json"
        /usr/bin/python3 -c '
import json, sys
row, = json.load(sys.stdin)
assert row["ok"] and row["connect_ms"] >= 0 and row["mbps"] > 0, row
print("vpn exit test " + sys.argv[1] + " " + json.dumps(row))
' "$mode" <"$cli/exit-test.json"
        kill "$xray_server_pid"
        wait "$xray_server_pid" 2>/dev/null || true
        xray_server_pid=""
    done
    vpn exit use relay
    cmp "$tmp/www/small" <(/usr/bin/curl -q -fsS --noproxy '' --max-time 5 \
        --socks5-hostname 127.0.0.1:18280 http://ssh-again.test:18088/small)
    wait_for grep -Fq '→ ssh-again.test:18088 [vpn]' "$LAPTOP_VPN_STATE/router.log"
    grep -q 'CONNECT ssh-again.test:18088' "$LAPTOP_VPN_STATE/ssh.log"
    vpn off
    vpn_pgid=""
    printf 'vpn exit use relay reconnected through the migrated SSH exit and carried loopback traffic\n'

    /usr/bin/base64 -i Tests/fixtures/links/ss-sip002.link >"$tmp/www/sub"
    vpn sub add http://127.0.0.1:18088/sub --json >"$cli/sub-added.json"
    vpn exits --json >"$cli/exits-before-update.json"
    subid=$(/usr/bin/python3 -c '
import json, sys
row = json.load(sys.stdin)
assert row["added"] == 1 and row["ignored"] == 0, row
print(row["id"])
' <"$cli/sub-added.json")
    cat Tests/fixtures/links/{ss-sip002,trojan-grpc}.link | /usr/bin/base64 >"$tmp/www/sub"
    vpn sub update "$subid" --json >"$cli/sub-updated.json"
    vpn exits --json >"$cli/exits-after-update.json"
    /usr/bin/python3 - "$cli" "$subid" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
subid = sys.argv[2]
before, after = [json.loads((directory / f"exits-{when}-update.json").read_text()) for when in ("before", "after")]
added, updated = [json.loads((directory / f"sub-{action}.json").read_text()) for action in ("added", "updated")]
old, = [exit for exit in before["exits"] if exit["subscription"] == subid]
new = {exit["protocol"]: exit["id"] for exit in after["exits"] if exit["subscription"] == subid}
assert after["active"] == "relay" and set(new) == {"ss", "trojan"} and new["ss"] == old["id"]
assert updated["added"] == 1 and updated["removed"] == 0 and updated["ignored"] == 0, updated
print("vpn sub add --json " + json.dumps(added))
print("vpn sub update --json " + json.dumps(updated))
PY

    # Recheck the migrated relay with the router disabled and SSH on the public port.
    export GOZAR_TEST_SOCKS="$PWD/Tests/fixtures/fake_socks.py"
    cat >"$cli/classic-ssh" <<'SH'
#!/bin/bash
[[ "$1 $2 $3" == '-N -D 127.0.0.1:18280' && "${!#}" == 'fixture@127.0.0.1' ]] || exit 1
exec /usr/bin/python3 "$GOZAR_TEST_SOCKS" 18280
SH
    chmod +x "$cli/classic-ssh"
    ln -sf "$cli/classic-ssh" "$cli_bin/ssh"
    sed -i '' 's/"enabled":[[:space:]]*true/"enabled": false/' "$LAPTOP_VPN_STATE/connection.json"
    vpn on >"$cli/on.out"
    cmp "$tmp/www/small" <(/usr/bin/curl -q -fsS --noproxy '' --max-time 5 \
        --socks5-hostname 127.0.0.1:18280 http://ssh-classic.test:18088/small)
    grep -q 'CONNECT ssh-classic.test:18088' "$LAPTOP_VPN_STATE/ssh.log"
    [[ ! -e "$LAPTOP_VPN_STATE/router.pid" ]]
    vpn off >"$cli/off.out"
    printf 'Classic mode carried loopback traffic through the migrated SSH exit on the public SOCKS port\n'
)
printf 'Gozar e2e passed (Python-free CLI, router data plane, SSH and Xray exits, subscriptions)\n'
