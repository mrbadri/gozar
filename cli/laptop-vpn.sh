#!/usr/bin/env bash
# Laptop VPN over the phone-VPN relay (docs/PHONE-VPN.md, docs/LAPTOP-VPN.md), macOS.
#
#   laptop → relay 203.0.113.10:47853 → egress sshd (user vpnuser) → Internet
#
# Opens an SSH SOCKS proxy on 127.0.0.1:1080 (reconnects by itself) and points
# the macOS system SOCKS proxy at it, so browsers and most apps exit through the
# egress host. TCP only: UDP (QUIC, some call apps) is not carried; browsers
# fall back to TCP on their own. Installed as `vpn` (~/.local/bin/vpn symlink).
#
# Two config files in ~/.config/laptop-vpn/ (created from laptop-vpn.d/ on first use):
#   routes.json      which site goes through the vpn, cisco, or direct
#   connection.json  relay address, port, user, local port, keepalive
#
#   vpn on | off        connect + system proxy on / restore proxy + disconnect
#   vpn                 status: connected?, exit IP, Cisco
#   vpn config [conn]   edit routes.json (or connection.json), check it, apply it
#   vpn apply           check both files and apply them (reconnects if connection changed)
#   vpn routes          the rules and where each goes right now
#   vpn set SITE… ROUTE send SITE through vpn | cisco | direct (applied at once)
#   vpn unset SITE…     drop SITE from the rules (→ vpn, the default)
#   vpn check SITE      which way SITE goes, and by which rule
#   vpn domains SITE    the domains a site uses (community list + loading it in Chrome);
#                       --add vpn|cisco|direct puts them in routes.json
#   vpn watch | top     live / busiest sites going through the tunnel
#   vpn try IP          exit through box IP instead (your key, via relay)
#   vpn forget          remove the saved password from Keychain
#   vpn reset-hostkey   after an egress swap (host key changed)
#   vpn docs [md]       the full guide (Persian) in the browser, or the .md in VS Code
#   vpn completion      install tab completion (zsh)
#   vpn help            every command explained (Persian)
#
# The password is asked once and kept in the login Keychain. Turn other
# VPN/proxy apps (Clash, v2ray…) off first: they use the same system proxy.
set -euo pipefail

STATE="${LAPTOP_VPN_STATE:-${HOME}/.config/laptop-vpn}"
export LAPTOP_VPN_STATE="$STATE"
PIDFILE="$STATE/loop.pid"
LOG="$STATE/ssh.log"
ROUTER_PIDFILE="$STATE/router.pid"
ROUTER_LOG="$STATE/router.log"
SAVED="$STATE/proxy-before"     # per-service proxy settings to restore on down
APPLIED="$STATE/applied"        # what the proxy settings were last built for
VIA_FILE="$STATE/via"           # set by `vpn try IP`: exit through that box instead
ROUTES="$STATE/routes.json"
CONNECTION="$STATE/connection.json"
ME=$(basename "$0")
# The real file behind the ~/.local/bin/vpn symlink, for laptop-vpn.d/ next to it.
SELF=$0
while [[ -L "$SELF" ]]; do
  link=$(readlink "$SELF")
  case "$link" in /*) SELF=$link ;; *) SELF="$(dirname "$SELF")/$link" ;; esac
done
CLI_DIR="$(cd "$(dirname "$SELF")" && pwd)"
CONF_DIR="${LAPTOP_VPN_CONF_DIR:-$CLI_DIR/laptop-vpn.d}"
REPO_APP="$CLI_DIR/.."
GOZARCTL="$CLI_DIR/../../MacOS/gozarctl"
if [[ ! -x "$GOZARCTL" ]]; then
  GOZARCTL=$(command -v gozarctl || true)
  if [[ -z "$GOZARCTL" && -x "$REPO_APP/.build/release/gozarctl" ]]; then
    GOZARCTL="$REPO_APP/.build/release/gozarctl"
  fi
fi
if [[ -z "${XRAY_BIN:-}" && ! -x "$CLI_DIR/../xray/xray" && -x "$REPO_APP/.build/xray/xray" ]]; then
  export XRAY_BIN="$REPO_APP/.build/xray/xray"
fi
PY=/usr/bin/python3

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
conf() {
  if [[ -n "$GOZARCTL" ]]; then
    "$GOZARCTL" --conf-dir "$CONF_DIR" "$@"
  else
    [[ -f "$CONF_DIR/vpnconf.py" ]] || die "gozarctl is missing"
    if [[ -z "${VPN_LEGACY_NOTE:-}" ]]; then
      printf '%s\n' 'note: gozarctl is unavailable; using legacy vpnconf.py' >&2
    fi
    VPN_LEGACY_NOTE=1
    "$PY" -I "$CONF_DIR/vpnconf.py" "$@"
  fi
}
routes_hash() { LC_ALL=C shasum "$ROUTES" 2>/dev/null | cut -d' ' -f1; }

prepare_state() {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
}

# Status JSON reads defaults without creating or refreshing any files.
load_config() {
  if [[ "${1:-}" != --defaults ]]; then
    prepare_state
    conf init
  fi
  local env
  env=$(conf conn-env --defaults) || die "fix $CONNECTION (vpn config conn), then try again"
  EXIT_ID=relay EXIT_KIND=ssh KEYCHAIN_SERVICE=vpnuser-relay KEYCHAIN_ACCOUNT=
  if [[ -n "$GOZARCTL" && -f "$STATE/exits.json" ]]; then EXIT_ID= EXIT_KIND=; fi
  eval "$env"
  KEYCHAIN_ACCOUNT=${KEYCHAIN_ACCOUNT:-$USER_NAME}
  TUNNEL_PORT=$SOCKS_PORT
  TRAFFIC_LOG=$LOG
  if [[ "$ROUTER_ENABLED" == 1 ]]; then
    TUNNEL_PORT=$UPSTREAM_PORT
    TRAFFIC_LOG=$ROUTER_LOG
  fi
}

have_password() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1
}

ensure_password() {
  have_password && return
  local pw
  [[ -t 0 ]] || die "no password saved yet — run 'vpn on' once in a real terminal so it can ask for it"
  read -r -s -p "Password for ${USER_NAME} (saved to Keychain): " pw; echo
  [[ -n "$pw" ]] || die "empty password"
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w "$pw"
}

write_askpass() {
  printf '#!/bin/bash\nexec security find-generic-password -s %q -a %q -w\n' \
    "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" >"$STATE/askpass"
  chmod 700 "$STATE/askpass"
}

supervisor_running() {
  local pid
  pid=$(cat "$1" 2>/dev/null) && [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null
}

loop_running() { supervisor_running "$PIDFILE"; }
router_running() { supervisor_running "$ROUTER_PIDFILE"; }

port_listening() { nc -z -w 1 127.0.0.1 "$1" >/dev/null 2>&1; }

socks_listening() {
  port_listening "$SOCKS_PORT"
}

# ssh -vv names every destination a SOCKS client asks for; keep those (one
# timestamped "→ host:port" line per connection), failures and ssh's own
# messages, and drop the rest of the debug chatter.
log_filter() {
  LC_ALL=C perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 }
    my $t = strftime("%H:%M:%S", localtime);
    if (/dynamic request: socks\d host (\S+) port (\d+)/) { print "$t → $1:$2\n" }
    elsif (/channel \d+: open failed: (.*)/)             { print "$t ✗ $1\n" }
    elsif (!/^debug\d: /)                                { print "$t $_" }'
}

# Reconnect loop, run in the background. Stops for good on errors a retry
# can't fix (wrong password, changed host key). Reads connection.json once, at
# start: `vpn apply` restarts it when that file changes.
run_loop() {
  if [[ "$EXIT_KIND" == xray ]]; then
    run_xray_loop
    return
  fi
  trap 'exit 0' TERM
  while :; do
    [[ $(wc -c <"$LOG") -lt 20000000 ]] || : >"$LOG"
    echo "--- $(date '+%F %T') connecting" >>"$LOG"
    # `vpn try IP`: straight to that box as root with your own key, jumping
    # through relay (the box answers relay, often not your ISP). Otherwise the
    # usual relay account on relay.
    local via target
    via=$(cat "$VIA_FILE" 2>/dev/null || true)
    if [[ -n "$via" ]]; then
      target=(-J "root@${HOST}" -o PubkeyAuthentication=yes -o PreferredAuthentications=publickey
              -o BatchMode=yes "root@${via}")
    else
      target=(-p "$PORT" -o PubkeyAuthentication=no -o PreferredAuthentications=password
              -o NumberOfPasswordPrompts=1 "${USER_NAME}@${HOST}")
    fi
    SSH_ASKPASS="$STATE/askpass" SSH_ASKPASS_REQUIRE=force \
    ssh -N -D "127.0.0.1:${TUNNEL_PORT}" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval="$KEEPALIVE_INTERVAL" -o ServerAliveCountMax="$KEEPALIVE_MISSED" \
      -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o Ciphers="$CIPHERS" \
      -o Compression=no -o IPQoS=throughput \
      -o UserKnownHostsFile="$STATE/known_hosts" \
      -o StrictHostKeyChecking=accept-new -vv \
      "${target[@]}" </dev/null 2>&1 | log_filter >>"$LOG" || true
    if tail -n 20 "$LOG" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
      echo "STOPPED: host key changed — run: vpn reset-hostkey" >>"$LOG"; break
    fi
    if tail -n 5 "$LOG" | grep -q 'Permission denied'; then
      echo "STOPPED: wrong password — run: vpn forget, then vpn on" >>"$LOG"; break
    fi
    sleep "$RECONNECT_DELAY"
  done
}

run_xray_loop() {
  local child=
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM
  while :; do
    [[ $(wc -c <"$LOG") -lt 20000000 ]] || : >"$LOG"
    echo "--- $(date '+%F %T') connecting" >>"$LOG"
    "$XRAY_BIN" run -c "$XRAY_CONFIG" > >(log_filter >>"$LOG") 2>&1 &
    child=$!
    wait "$child" || true
    set -- "$@" "$SECONDS"
    if [[ $# == 5 ]]; then
      if (( SECONDS - $1 < 60 )); then
        echo 'STOPPED: xray keeps exiting — check the link (vpn exits)' >>"$LOG"
        return
      fi
      shift
    fi
    sleep "$RECONNECT_DELAY" &
    child=$!
    wait "$child"
  done
}

run_router_loop() {
  local child=
  trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 0' TERM
  while :; do
    "$ROUTER_BIN" --state "$STATE" &
    child=$!
    if ! wait "$child"; then
      set -- "$@" "$SECONDS"
      if [[ $# == 5 ]]; then
        if (( SECONDS - $1 < 60 )); then
          printf '%s\n' 'STOPPED: router keeps crashing' >>"$ROUTER_LOG"
          return
        fi
        shift
      fi
    fi
    sleep 2 &
    child=$!
    wait "$child"
  done
}

# Hardware network services that are enabled (Wi-Fi, Ethernet…); VPN entries
# can't carry a SOCKS setting.
services() {
  local enabled
  enabled=$(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' || true)
  networksetup -listallhardwareports | sed -n 's/^Hardware Port: //p' |
    while IFS= read -r s; do grep -qxF "$s" <<<"$enabled" && printf '%s\n' "$s"; done
}

# Cisco AnyConnect, while connected, is the primary network service, and macOS
# then reads proxy settings from Cisco's own copy, taken when it connected and
# never refreshed: networksetup changes to Wi-Fi don't reach it. So `vpn on`
# after Cisco connects would not apply at all (everything, YouTube included,
# would go through Cisco), and `vpn off` would leave Cisco's copy pointing at a
# dead proxy. Rewriting that copy needs root, hence sudo — only when Cisco is up.
CISCO_PROXIES="State:/Network/Service/com.cisco.anyconnect/Proxies"

cisco_connected() {
  printf 'show %s\n' "$CISCO_PROXIES" | scutil 2>/dev/null | grep -q '<dictionary>'
}

conf_cisco() {
  if cisco_connected; then conf "$@" --cisco; else conf "$@"; fi
}

# The macOS exception list (what must not use the VPN) for the current Cisco state.
bypass_list() {
  if [[ "$ROUTER_ENABLED" == 1 ]]; then conf bypass --router; else conf_cisco bypass; fi
}

set_bypass() {
  local list=() line
  while IFS= read -r line; do list+=("$line"); done < <(bypass_list)
  networksetup -setproxybypassdomains "$1" "${list[@]}"
}

# cisco_proxy on | off <exceptions…>
cisco_proxy() {
  cisco_connected || return 0
  local mode="$1"; shift
  if ! sudo -n true 2>/dev/null; then
    if [[ -t 0 ]]; then
      say "Cisco VPN is connected: macOS needs your Mac password to update Cisco's proxy copy."
      sudo -v || { say "warning: Cisco's proxy copy not updated"; return 0; }
    elif [[ -n "${SUDO_ASKPASS:-}" ]]; then
      sudo -A -v || { say "warning: Cisco's proxy copy not updated"; return 0; }
    else
      say "warning: Cisco VPN is connected and its proxy copy needs your Mac password — run 'vpn $mode' in a terminal"
      [[ "$mode" == off ]] && say "         until then, browsing over Cisco still points at the closed proxy"
      return 0
    fi
  fi
  {
    printf 'get %s\n' "$CISCO_PROXIES"
    if [[ "$mode" == on ]]; then
      printf 'd.add SOCKSEnable # 1\nd.add SOCKSProxy 127.0.0.1\nd.add SOCKSPort # %s\n' "$SOCKS_PORT"
    else
      printf 'd.add SOCKSEnable # 0\n'
    fi
    if [[ $# -gt 0 ]]; then printf 'd.add ExceptionsList *'; printf ' %s' "$@"; printf '\n'; fi
    printf 'set %s\n' "$CISCO_PROXIES"
  } | sudo scutil || { say "warning: could not update Cisco's proxy copy"; return 0; }
  say "Cisco VPN proxy copy: $mode"
}

cisco_proxy_on() {
  local list=() line
  while IFS= read -r line; do list+=("$line"); done < <(bypass_list)
  cisco_proxy on "${list[@]}"
}

# Remember what the settings were built for, so `vpn` can tell when Cisco has
# since connected or dropped (the routes then need `vpn apply`).
mark_applied() {
  printf 'cisco=%s\n' "$(cisco_connected && echo on || echo off)" >"$APPLIED"
}

proxy_on() {
  local s tmp
  if [[ -f "$SAVED" ]]; then    # already on: keep the saved originals, refresh the routes
    cut -f1 "$SAVED" | while IFS= read -r s; do set_bypass "$s"; done
    cisco_proxy_on
    mark_applied
    say "routes applied ($(cisco_connected && echo "Cisco connected" || echo "no Cisco"))"
    return
  fi
  tmp=$(mktemp)
  while IFS= read -r s; do
    local en srv prt byp
    en=$(networksetup -getsocksfirewallproxy "$s" | sed -n 's/^Enabled: //p')
    srv=$(networksetup -getsocksfirewallproxy "$s" | sed -n 's/^Server: //p')
    prt=$(networksetup -getsocksfirewallproxy "$s" | sed -n 's/^Port: //p')
    byp=$(networksetup -getproxybypassdomains "$s" | { grep -v "^There aren't" || true; } | paste -sd'|' -)
    printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$en" "$srv" "$prt" "$byp" >>"$tmp"
    networksetup -setsocksfirewallproxy "$s" 127.0.0.1 "$SOCKS_PORT"
    set_bypass "$s"
    networksetup -setsocksfirewallproxystate "$s" on
    say "system proxy on: $s"
  done < <(services)
  mv "$tmp" "$SAVED"
  cisco_proxy_on
  mark_applied
}

proxy_off() {
  [[ -f "$SAVED" ]] || return 0
  local s en srv prt byp first_byp st list=()
  # Cisco's copy goes back to the first service's own exceptions (normally Wi-Fi's).
  first_byp=$(head -n 1 "$SAVED" | cut -f5)
  if [[ -n "$first_byp" ]]; then
    IFS='|' read -r -a list <<<"$first_byp"
    cisco_proxy off "${list[@]}"
  else
    cisco_proxy off
  fi
  while IFS=$'\t' read -r s en srv prt byp; do
    if [[ -n "$srv" && "$srv" != "(null)" && "$prt" != "0" ]]; then
      networksetup -setsocksfirewallproxy "$s" "$srv" "$prt"
    fi
    if [[ -n "$byp" ]]; then
      IFS='|' read -r -a list <<<"$byp"
      networksetup -setproxybypassdomains "$s" "${list[@]}"
    else
      networksetup -setproxybypassdomains "$s" Empty
    fi
    [[ "$en" == "Yes" ]] && st=on || st=off
    networksetup -setsocksfirewallproxystate "$s" "$st"
    say "system proxy restored: $s ($st)"
  done <"$SAVED"
  rm -f "$SAVED" "$APPLIED"
}

exit_ip() {
  curl -s --max-time 10 --noproxy '' --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://api.ipify.org || true
}

conn_hash() { LC_ALL=C shasum "$CONNECTION" | cut -d' ' -f1; }
exit_changed() {
  local applied
  applied=$(cat "$STATE/exit.applied" 2>/dev/null || printf '%s' relay)
  [[ "$EXIT_ID" != "$applied" ]]
}

wait_for_port() {
  local port="$1" pidfile="$2" i
  for ((i = 0; i < 30; i++)); do
    supervisor_running "$pidfile" || return 1
    port_listening "$port" && return 0
    sleep 1
  done
  port_listening "$port"
}

cmd_up() {
  [[ -n "$EXIT_KIND" ]] || die "no active exit — run: vpn exits"
  conf validate || die "fix the config first (vpn config / vpn config conn)"
  if [[ "$ROUTER_ENABLED" == 1 ]]; then
    ROUTER_BIN="$CLI_DIR/../../MacOS/vpn-router"
    if [[ ! -x "$ROUTER_BIN" ]]; then
      ROUTER_BIN=$(command -v vpn-router || printf '%s' "$HOME/.local/bin/vpn-router")
    fi
    [[ -x "$ROUTER_BIN" ]] || die "router mode is on but vpn-router is not installed — run scripts/install.sh, or set router.enabled to false"
    if ! router_running && socks_listening; then
      die "port ${SOCKS_PORT} is taken by something else (local_socks_port in $CONNECTION)"
    fi
  fi
  if [[ "$EXIT_KIND" == ssh ]]; then
    ensure_password
    write_askpass
  fi
  if ! loop_running; then
    local port_key=local_socks_port
    [[ "$ROUTER_ENABLED" == 1 ]] && port_key=router.upstream_port
    port_listening "$TUNNEL_PORT" && die "port ${TUNNEL_PORT} is taken by something else ($port_key in $CONNECTION)"
    if [[ "$EXIT_KIND" == xray ]]; then
      local env
      [[ -x "$XRAY_BIN" ]] || die "Xray is missing — build the app or set XRAY_BIN"
      env=$(conf conn-env) || die "could not generate Xray configuration (vpn exits)"
      eval "$env"
    fi
    : >"$LOG"
    run_loop </dev/null >/dev/null 2>&1 &   # detached: don't hold the caller's pipes
    echo $! >"$PIDFILE"
    conn_hash >"$STATE/connection.applied"
    printf '%s\n' "$EXIT_ID" >"$STATE/exit.applied"
    disown
  fi
  if [[ "$EXIT_KIND" == xray ]]; then say "connecting through Xray (${EXIT_ID})…"
  elif [[ -f "$VIA_FILE" ]]; then say "connecting to $(cat "$VIA_FILE") via ${HOST}…"
  else say "connecting to ${HOST}:${PORT}…"; fi
  if ! wait_for_port "$TUNNEL_PORT" "$PIDFILE"; then
    tail -n 5 "$LOG" >&2
    loop_running || die "tunnel stopped (log: $LOG)"
    cmd_down >/dev/null
    die "no connection after 30 s (log: $LOG)"
  fi
  if [[ "$ROUTER_ENABLED" == 1 ]]; then
    if ! router_running; then
      touch "$ROUTER_LOG"
      run_router_loop </dev/null >>"$ROUTER_LOG" 2>&1 &
      echo $! >"$ROUTER_PIDFILE"
      disown
    fi
    if ! wait_for_port "$SOCKS_PORT" "$ROUTER_PIDFILE"; then
      tail -n 5 "$ROUTER_LOG" >&2
      cmd_down >/dev/null
      die "router did not start (log: $ROUTER_LOG)"
    fi
  fi
  local ip=""
  for _ in 1 2 3; do ip=$(exit_ip); [[ -z "$ip" ]] || break; done
  # A slow first answer is not a dead tunnel: keep it, just leave the proxy off.
  [[ -n "$ip" ]] || die "tunnel is up but nothing came back through it in 30 s — system proxy left as it was; try 'vpn on' again"
  proxy_on
  say "connected — exit IP ${ip}"
  say "terminal tools: export ALL_PROXY=socks5h://127.0.0.1:${SOCKS_PORT}"
}

cmd_down() {
  local i
  proxy_off
  if router_running; then
    kill "$(cat "$ROUTER_PIDFILE")" 2>/dev/null || true
  fi
  if loop_running; then
    local pid kids; pid=$(cat "$PIDFILE")
    # List ssh before killing the loop: a loop started by an older vpn has no
    # TERM trap, dies at once, and its children move to launchd, out of pkill -P.
    kids=$(pgrep -P "$pid" || true)
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true   # let the loop handle TERM after ssh exits
    # shellcheck disable=SC2086
    [[ -z "$kids" ]] || kill $kids 2>/dev/null || true
    # A killed ssh keeps the port for a moment; `vpn apply` binds it again at once.
    local k
    for k in $kids; do
      for ((i = 0; i < 30; i++)); do kill -0 "$k" 2>/dev/null || break; sleep 0.1; done
    done
  fi
  for ((i = 0; i < 20; i++)); do
    if ! loop_running && ! router_running; then break; fi
    sleep 0.1
  done
  if loop_running || router_running; then
    die 'a supervisor is still stopping — run: vpn off'
  fi
  rm -f "$PIDFILE" "$ROUTER_PIDFILE" "$STATE/connection.applied" "$STATE/exit.applied"
  say "disconnected"
}

cmd_status() {
  local json=0 no_ip=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      --no-ip) no_ip=1 ;;
      *) die 'usage: vpn status [--json] [--no-ip]' ;;
    esac
    shift
  done
  if [[ "$json" == 1 ]]; then load_config --defaults; else load_config; fi
  local loop=0 socks=0 ip= proxy=0 cisco=0 cisco_copy= via= stopped= routing=0
  local cisco_note= connection_note= exit_note= now=off cs
  loop_running && loop=1
  if socks_listening; then
    socks=1
    [[ "$no_ip" == 1 ]] || ip=$(exit_ip)
  fi
  [[ -f "$SAVED" ]] && proxy=1
  [[ -f "$VIA_FILE" ]] && via=$(cat "$VIA_FILE")
  cs=$(printf 'show %s\n' "$CISCO_PROXIES" | scutil 2>/dev/null || true)
  if [[ "$cs" == *'<dictionary>'* ]]; then
    cisco=1 now=on cisco_copy=0
    [[ $(awk '/^  SOCKSEnable :/{print $3}' <<<"$cs") == 1 ]] && cisco_copy=1
  fi
  if [[ "$proxy" == 1 && -f "$APPLIED" ]] && ! grep -qx "cisco=$now" "$APPLIED"; then
    cisco_note="Cisco has $([[ "$now" == on ]] && echo connected || echo disconnected) since the routes were applied — run: vpn apply"
  fi
  if [[ "$loop" == 1 && -f "$STATE/connection.applied" ]] && [[ "$(conn_hash)" != "$(cat "$STATE/connection.applied")" ]]; then
    connection_note="connection.json changed since connecting — run: vpn apply"
  fi
  if [[ "$loop" == 1 ]] && exit_changed; then
    exit_note="active exit changed since connecting — run: vpn apply"
  fi
  [[ "$socks" == 1 ]] && router_running && routing=1
  if [[ "$ROUTER_ENABLED" == 1 && "$routing" == 0 ]]; then
    stopped=$(awk '/^--- .* router started/{stop=""} /^STOPPED/{stop=$0} END{if (stop) print stop}' "$ROUTER_LOG" 2>/dev/null || true)
  fi
  [[ -n "$stopped" ]] || stopped=$(grep '^STOPPED' "$LOG" 2>/dev/null | tail -n 1 || true)
  if [[ "$json" == 1 ]]; then
    /usr/bin/osascript -l JavaScript - \
      "$loop" "$socks" "$ip" "$proxy" "$cisco" "$cisco_copy" "$ROUTER_ENABLED" "$routing" "$CONTROL_PORT" \
      "$via" "$stopped" "$cisco_note" "$connection_note" "$exit_note" <<'JS'
function run(args) {
  const [loop, socks, ip, proxy, cisco, copy, enabled, running, port, via, stopped, ...notes] = args
  return JSON.stringify({
    loop: loop === "1", socks: socks === "1", exit_ip: ip || null,
    proxy: proxy === "1", cisco: cisco === "1", cisco_copy: copy ? copy === "1" : null,
    router: { enabled: enabled === "1", running: running === "1", control_port: enabled === "1" ? Number(port) : null },
    via: via || null, stopped: stopped || null, notes: notes.filter(Boolean),
  })
}
JS
    return
  fi
  [[ -n "$via" ]] && say "exit: test box $via (vpn on = back to normal)"
  if [[ "$loop" == 1 ]]; then say "tunnel loop: running (pid $(cat "$PIDFILE"))"; else say "tunnel loop: stopped"; fi
  if [[ "$socks" == 0 ]]; then say "socks 127.0.0.1:${SOCKS_PORT}: down"
  elif [[ "$no_ip" == 1 ]]; then say "socks 127.0.0.1:${SOCKS_PORT}: up"
  else say "socks 127.0.0.1:${SOCKS_PORT}: up, exit IP $ip"; fi
  if [[ "$routing" == 1 ]]; then say "router: running on 127.0.0.1:${SOCKS_PORT}, control 127.0.0.1:${CONTROL_PORT}"
  else say "router: off"; fi
  if [[ "$proxy" == 1 ]]; then say "system proxy: on"; else say "system proxy: off"; fi
  if [[ "$cisco" == 1 ]]; then say "Cisco VPN: connected, its proxy copy: $([[ "$cisco_copy" == 1 ]] && echo on || echo off)"; fi
  [[ -n "$cisco_note" ]] && say "note: $cisco_note"
  [[ -n "$connection_note" ]] && say "note: $connection_note"
  [[ -n "$exit_note" ]] && say "note: $exit_note"
  [[ -n "$stopped" ]] && say "$stopped"
  return 0
}

# Busiest destinations since this connection started.
cmd_top() {
  grep ' → ' "$TRAFFIC_LOG" 2>/dev/null | awk '{print $3}' | sed 's/:[0-9]*$//' |
    sort | uniq -c | sort -rn | head -n "${1:-20}"
}

# Check both files; then reconnect if connection.json changed while connected,
# else just re-apply the routes.
cmd_apply() {
  conf validate || die "nothing applied — fix the file and run: vpn apply"
  if { loop_running || [[ -f "$SAVED" ]]; } && { exit_changed || { [[ -f "$STATE/connection.applied" ]] &&
      [[ "$(conn_hash)" != "$(cat "$STATE/connection.applied")" ]]; }; }; then
    if exit_changed; then
      say "active exit changed: reconnecting"
      rm -f "$VIA_FILE"
    else
      say "connection.json changed: reconnecting"
    fi
    cmd_down >/dev/null
    load_config
    cmd_up
  elif [[ -f "$SAVED" ]]; then
    proxy_on
  else
    say "config is valid — it applies on the next: vpn on"
  fi
}

# Open a config file, keep it open until it parses, then apply.
cmd_config() {
  local which="${1:-routes}" file
  case "$which" in
    routes|r) file="$ROUTES" ;;
    conn|connection|c) file="$CONNECTION" ;;
    path|paths) say "$ROUTES"; say "$CONNECTION"; say "defaults + schema: $CONF_DIR"; return ;;
    *) die "usage: vpn config [routes | conn | paths]" ;;
  esac
  if [[ ! -t 0 || ! -t 1 ]]; then
    # No terminal to wait in (e.g. Claude's ! box): open it, apply later.
    if command -v code >/dev/null; then code "$file"; else open -t "$file"; fi
    say "opened $file — save it, then run: vpn apply"
    return
  fi
  local editor="${VISUAL:-${EDITOR:-}}"
  if [[ -z "$editor" ]]; then
    if command -v code >/dev/null; then editor="code --wait"; else editor="nano"; fi
  fi
  while :; do
    [[ "$editor" == code* ]] && say "opened in VS Code — close the tab to apply"
    # shellcheck disable=SC2086
    $editor "$file"
    if conf validate; then break; fi
    local again
    read -r -p "open it again to fix? [Y/n] " again
    [[ "$again" =~ ^[Nn] ]] && die "not applied"
  done
  cmd_apply
}

# Full help, in Persian. Each command on its own line so the terminal's
# right-to-left handling doesn't scramble it.
cmd_help() {
  cat <<'EOF2'
vpn — VPN لپ‌تاپ با SSH یا Xray

  مسیر پیش‌فرض SSH: لپ‌تاپ → 203.0.113.10:47853 → سرور خارج → اینترنت
  یه proxy روی 127.0.0.1:1080 باز می‌کنه و proxy سیستم مک رو روی اون می‌ذاره.
  هر سایت طبق routes.json یکی از این سه راه رو می‌ره:
      vpn      از VPN ِ ما (هر سایتی که توی فایل نیست هم همین)
      cisco    از Cisco وقتی وصله؛ بدون Cisco طبق without_cisco (vpn یا direct)
      direct   هیچ‌وقت از VPN ِ ما نه (وقتی Cisco وصله، Cisco همه‌چی رو می‌بره)

وصل و قطع
  vpn on
      وصل می‌شه و proxy سیستم رو روشن می‌کنه. اگه قطع بشه خودش دوباره وصل می‌شه.
      برای سرور SSH، بار اول رمز رو می‌پرسه و توی Keychain نگه می‌داره (فقط توی ترمینال واقعی).
      اسم دیگه: vpn up
  vpn off
      proxy هر کارت شبکه رو به همون حالتی که قبل از on بود برمی‌گردونه و قطع می‌کنه.
      اسم دیگه: vpn down
  vpn
      وضعیت: تونل، IP خروجی، proxy سیستم، Cisco، و اینکه apply لازمه یا نه.
  vpn try IP
      مثل on، ولی از سرور IP بیرون می‌ره (برای تست سرور تازه؛ با کلید SSH ِ خودت از راه relay).
      برگشت به حالت عادی: vpn on

کانفیگ
  فایل‌ها توی ~/.config/laptop-vpn/:
      routes.json       کدوم سایت از کجا بره
      connection.json   تنظیمات محلی اتصال (پورت، keepalive، حالت مسیریاب)
      exits.json        سرورها، اشتراک‌ها و انتخاب فعلی
  رمز SSH توی Keychain ِ مکه. لینک‌های V2Ray و اشتراک رو خصوصی نگه دار.

  vpn config
      routes.json رو باز می‌کنه (VS Code، یا $EDITOR). وقتی بستی، چکش می‌کنه؛ اگه غلط داشت
      می‌گه کجا و دوباره بازش می‌کنه؛ اگه درست بود همون لحظه اعمالش می‌کنه.
      اسم دیگه: vpn edit
  vpn config conn
      همین برای connection.json. اگه وصلی، بعد از ذخیره دوباره وصل می‌شه.
  vpn config paths
      مسیر فایل‌ها (برای باز کردن دستی).
  vpn apply
      اگه فایل‌ها رو خودت جای دیگه عوض کردی: چک و اعمال.
      وقتی Cisco وصل یا قطع شد هم بزن تا سایت‌های cisco درست برن.
  vpn routes
      همهٔ قانون‌ها و اینکه هر کدوم الان از کجا می‌ره. اسم‌های دیگه: vpn list، vpn ls

  vpn set SITE… vpn|cisco|direct
      SITE رو همون لحظه به اون راه می‌فرسته (توی routes.json هم ذخیره می‌شه).
      مثال: vpn set snapp.taxi direct
            vpn set chatgpt.com vpn
  vpn unset SITE…
      SITE رو از همهٔ قانون‌ها برمی‌داره؛ یعنی از VPN می‌ره.
  vpn add SITE…  /  vpn rm SITE…
      همون vpn set SITE direct  /  vpn unset SITE
  vpn check SITE
      SITE الان از کجا می‌ره و طبق کدوم قانون.
      مثال: vpn check https://claude.ai/new
  vpn domains SITE
      همهٔ دامنه‌هایی که یه سایت استفاده می‌کنه: از لیست عمومی (v2fly geosite) و با باز کردن
      خود سایت توی Chrome ِ بی‌صفحه (~۱۵ ثانیه). کنار هر کدوم می‌گه الان از کجا می‌ره.
        vpn domains youtube                 فقط نشون بده
        vpn domains youtube --add vpn       اضافه کن به قانون YouTube (اگه نیست می‌سازه)
        vpn domains company.example --add cisco --name Company
        --all     چیزهای اضافه‌ای که Chrome دید (حتی مشترک‌ها مثل google.com) هم اضافه بشن
        --quick   بدون Chrome، فقط لیست عمومی
      اسم دیگه: vpn find
      نسخهٔ همراه اپ فقط لیست عمومی رو می‌گیره: vpn domains SITE --json

  شکل نوشتن آدرس توی routes.json (راهنمای کامل بالای خود فایل هست):
      "youtube.com"      خودش و همهٔ زیردامنه‌هاش
      "*.company.example"   فقط زیردامنه‌ها، نه خود company.example
      "*.ir" یا "ir"      همهٔ .irها
      "hosts": ["corp-mgmt01", "10.0.0.0/8"]   اسم دقیق، IP، رنج
      "enabled": false   قانون موقتاً خاموش

سرورها و V2Ray
  vpn exits [--json]                  فهرست سرورها، شناسه‌ها و سرور فعال
  vpn exit add 'LINK' [--name NAME]   افزودن لینک VLESS، VMess، Trojan یا Shadowsocks
  vpn exit add ssh://user@host:port   افزودن SSH و ذخیرهٔ رمز در Keychain
  vpn exit use ID                     انتخاب سرور و اتصال دوباره اگه VPN روشنه
  vpn exit test ID | --all            آزمایش زمان اتصال و سرعت دانلود
  vpn exit rename ID NAME             تغییر اسم
  vpn exit rm ID                      حذف سروری که فعال نیست
  vpn sub add 'URL' [--name NAME]     افزودن اشتراک
  vpn sub update [ID]                 تازه‌کردن یک یا همهٔ اشتراک‌ها
  vpn sub rm ID                       حذف اشتراک و سرورهاش

دیدن ترافیک
  vpn watch
      زنده نشون می‌ده چه سایت‌هایی از VPN رد می‌شن. Ctrl+C برای خروج؛ VPN قطع نمی‌شه.
        15:50:49 → www.youtube.com:443   یه اتصال جدید از VPN
        15:50:41 ✗ connect failed: …       سرور خارج نتونست به مقصد برسه
        --- … connecting                    تونل قطع شده بود و دوباره وصل شد
      سایتی که باز می‌شه ولی اینجا نمیاد، از VPN نرفته.
      اسم دیگه: vpn w
  vpn top [N]
      پرتکرارترین سایت‌هایی که از VPN رد شدن (پیش‌فرض ۲۰ تا).

نگهداری
  vpn reset-hostkey
      وقتی سرور خارج عوض شده و vpn می‌گه host key changed. بعدش vpn on.
  vpn forget
      رمز ذخیره‌شده رو از Keychain پاک می‌کنه. vpn on بعدی دوباره می‌پرسه.
  vpn help
      همین راهنما. اسم‌های دیگه: vpn -h، vpn --help
  vpn docs
      راهنمای کامل (فارسی) رو به‌شکل یه صفحهٔ مرتب توی مرورگر باز می‌کنه.
      vpn docs md   خود فایل md رو توی VS Code باز می‌کنه.
  vpn completion
      Tab رو برای vpn فعال می‌کنه: vpn بزن، یه فاصله، بعد Tab (یه بار کافیه).

نکته‌ها
  - وقتی Cisco وصله، on/off/apply/set رمز مک رو می‌پرسن (کپی proxy ِ Cisco رو درست می‌کنن)؛
    توی ترمینال بزن، نه کادر ! ِ Claude.
  - ابزارهای ترمینال (curl، git، pnpm) از proxy سیستم استفاده نمی‌کنن:
      export ALL_PROXY=socks5h://127.0.0.1:1080
  - قبل از vpn on، Clash/v2ray و هر فیلترشکن دیگه‌ای رو خاموش کن.
  - فقط TCP رد می‌شه؛ بعضی تماس‌های صوتی/تصویری ممکنه کار نکنن.
  - لاگ: ~/.config/laptop-vpn/ssh.log
  - راهنمای کامل: docs/LAPTOP-VPN.md
EOF2
}

# Test another exit box: disconnect, then come back up through IP.
cmd_try() {
  [[ -n "${1:-}" ]] || die "usage: vpn try <IP>   (back to normal: vpn on)"
  [[ "$EXIT_KIND" == ssh ]] || die "vpn try requires an active SSH exit"
  [[ -f "$PIDFILE" ]] && cmd_down >/dev/null
  printf '%s\n' "$1" >"$VIA_FILE"
  say "exit: $1 (via relay)"
  cmd_up
}

cmd_exit_add() {
  local link="${1:-}" user host port pw id json=0
  if [[ "$link" != ssh://* ]]; then
    conf exit-add "$@"
    return
  fi
  if [[ "$link" =~ ^ssh://([^@/:]+)@(\[[^]]+\]|[^:/@]+):([0-9]+)$ ]]; then
    user=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
  else
    die 'usage: vpn exit add ssh://user@host:port [--name NAME]'
  fi
  shift
  local -a options
  options=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) [[ $# -ge 2 ]] || die "missing value for --name"; options+=("$1" "$2"); shift ;;
      --json) json=1 ;;
      *) die "usage: vpn exit add ssh://user@host:port [--name NAME] [--json]" ;;
    esac
    shift
  done
  [[ -t 0 ]] || die "run 'vpn exit add' for SSH in a real terminal so it can ask for the password"
  read -r -s -p "Password for ${user} (saved to Keychain): " pw; echo >&2
  [[ -n "$pw" ]] || die "empty password"
  id=$(conf exit-add-ssh "$host" "$port" "$user" ${options[@]+"${options[@]}"})
  if ! security add-generic-password -U -s gozar-ssh -a "$id" -w "$pw" >/dev/null; then
    if conf exit-rm "$id" >/dev/null 2>&1; then die "could not save password in Keychain"; fi
    die "could not save password in Keychain for $id — run vpn on in a terminal to try again"
  fi
  if [[ "$json" == 1 ]]; then printf '{"ids":["%s"]}\n' "$id"; else say "$id"; fi
}

cmd_exit() {
  local action="${1:-}" output
  if [[ $# -gt 0 ]]; then shift; fi
  case "$action" in
    add) cmd_exit_add "$@" ;;
    rm|rename|test) conf "exit-$action" "$@" ;;
    use)
      output=$(conf exit-use "$@") || { [[ -z "$output" ]] || say "$output"; return 1; }
      say "$output"
      if loop_running || [[ -f "$SAVED" ]]; then
        # Reserve stdout for the exit-use result and show reconnect progress separately.
        (
          exec 1>&2
          load_config
          cmd_apply
        )
      fi ;;
    *) die "usage: vpn exit add|rm|rename|use|test" ;;
  esac
}

# Apply after a routes change, if the VPN is on.
apply_routes() {
  if [[ -f "$SAVED" ]]; then proxy_on; else say "applies on the next: vpn on"; fi
}

# The guide, as a right-to-left page in the browser (or the .md itself in VS Code).
cmd_docs() {
  local md="$CLI_DIR/docs/LAPTOP-VPN.md"
  [[ -f "$md" ]] || md="$CLI_DIR/../docs/LAPTOP-VPN.md"
  [[ -f "$md" ]] || die "guide not found: $md"
  if [[ "${1:-}" == md ]]; then
    if command -v code >/dev/null; then code "$md"; else open -t "$md"; fi
    say "opened $md"
    return
  fi
  if [[ -f "$CLI_DIR/docs/LAPTOP-VPN.html" ]]; then
    open "$CLI_DIR/docs/LAPTOP-VPN.html"
    say "opened the guide in your browser"
    return
  fi
  "$PY" -I "$CONF_DIR/docs.py" "$md" "$STATE/guide.html"
  open "$STATE/guide.html"
  say "opened the guide in your browser ($STATE/guide.html)"
}

# Tab completion: link _vpn into a zsh completion directory that's on $fpath.
cmd_completion() {
  local dir
  for dir in "$HOME/.oh-my-zsh/custom/completions" "$HOME/.zsh/completions"; do
    [[ -d "$dir" ]] && break
  done
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    say "add this line to ~/.zshrc, before compinit:  fpath=(\"$dir\" \$fpath)"
  fi
  ln -sf "$CONF_DIR/_vpn" "$dir/_vpn"
  say "installed: $dir/_vpn — open a new terminal (or run: exec zsh), then try: vpn <Tab>"
}

case "${1:-status}" in
  status) if [[ $# -gt 0 ]]; then shift; fi; cmd_status "$@"; exit 0 ;;
  help|-h|--help) prepare_state; cmd_help; exit 0 ;;
  docs|guide|doc) prepare_state; cmd_docs "${2:-}"; exit 0 ;;
  completion) prepare_state; cmd_completion; exit 0 ;;
esac

load_config

case "${1:-status}" in
  on|up)
    [[ -f "$VIA_FILE" ]] && { cmd_down >/dev/null; rm -f "$VIA_FILE"; say "exit: normal relay"; }
    if { loop_running || [[ -f "$SAVED" ]]; } && exit_changed; then cmd_apply; else cmd_up; fi ;;
  try) cmd_try "${2:-}" ;;
  off|down) cmd_down ;;
  config|edit) cmd_config "${2:-routes}" ;;
  apply) cmd_apply ;;
  exits) shift; conf exits "$@" ;;
  exit) shift; cmd_exit "$@" ;;
  sub)
    shift
    case "${1:-}" in
      add|update|rm) action=$1; shift; conf "sub-$action" "$@" ;;
      *) die "usage: vpn sub add|update|rm" ;;
    esac ;;
  routes|list|ls) shift; conf_cisco routes "$@" ;;
  set)
    shift
    [[ $# -ge 2 ]] || die "usage: vpn set SITE… vpn|cisco|direct"
    conf set "$@" && apply_routes ;;
  unset|rm) shift; [[ $# -ge 1 ]] || die "usage: vpn unset SITE…"; conf unset "$@" && apply_routes ;;
  add) shift; [[ $# -ge 1 ]] || die "usage: vpn add SITE…"; conf set "$@" direct && apply_routes ;;
  check) shift; [[ $# -ge 1 ]] || die "usage: vpn check SITE [--json]"; conf_cisco check "$@" ;;
  _sites) conf sites ;;   # for tab completion
  domains|find)
    shift
    [[ $# -ge 1 ]] || die "usage: vpn domains SITE [--json | --add vpn|cisco|direct] [--name NAME] [--all] [--quick]"
    before=$(routes_hash)
    if cisco_connected; then set -- "$@" --cisco; fi
    domains_json=0
    for arg in "$@"; do [[ "$arg" == --json ]] && domains_json=1; done
    if [[ -n "$GOZARCTL" && ( "$domains_json" == 1 || ! -f "$CONF_DIR/sitedomains.py" ) ]]; then
      conf domains "$@"
    else
      "$PY" -I "$CONF_DIR/sitedomains.py" "$@"
    fi
    [[ "$(routes_hash)" == "$before" ]] || apply_routes ;;
  watch|w) tail -n 30 -F "$TRAFFIC_LOG" ;;
  top) cmd_top "${2:-}" ;;
  forget)
    [[ "$EXIT_KIND" == ssh ]] || die "the active exit does not use an SSH password"
    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null && say "password removed" ;;
  reset-hostkey) rm -f "$STATE/known_hosts" && say "host key forgotten; run: vpn on" ;;
  *) say "unknown command: $1"
     say "commands: on off config apply exits exit sub routes set unset check domains docs watch top try forget reset-hostkey completion — help: vpn help, guide: vpn docs"
     exit 1 ;;
esac
