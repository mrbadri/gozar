# Gozar — a macOS app for the laptop VPN

Owner: Mohammad Reza. Lead and reviewer: Claude Opus. Implementer: Codex
(`gpt-6.2-sol`, effort high). This file is the single source of truth for the
build. **Read all of it before you write code. Do not invent anything this file
does not say; if something is missing or contradictory, stop and ask the
coordinator (`ask`).**

## 0. What we are building

Today the laptop VPN is a shell command, `vpn` (`scripts/laptop-vpn.sh`, guide
`docs/LAPTOP-VPN.md`). It runs `ssh -D 127.0.0.1:1080` to the relay
(`vpnuser@203.0.113.10:47853` → egress box → Internet) and points the macOS
system SOCKS proxy at it. Which sites skip the VPN is decided by macOS's proxy
exception list, built from `~/.config/laptop-vpn/routes.json`.

We add three things and change the CLI a little:

1. **`vpn-router`**: a small headless Swift program that becomes the SOCKS5
   proxy on `127.0.0.1:1080`. For every connection it decides the route itself
   (`vpn` → forward to `ssh -D` on `127.0.0.1:1081`; `direct`/`cisco` → connect
   straight from the laptop), counts bytes and times, and serves a local
   control API with live events. Now every request is visible, including the
   direct ones, with per-domain speed and connect time.
2. **`Gozar.app`**: a beautiful SwiftUI app (main window + menu bar) that shows
   all of it live, the health of each link of the chain (Mac → relay → egress →
   Internet, the server side from Grafana), and controls everything the `vpn`
   command does: on/off, routes, adding/removing domains, finding a site's
   domains, Cisco, try another box, reset host key, connection settings.
3. **CLI "router mode"**: `vpn` keeps working from the terminal. When router
   mode is on (`connection.json` → `"router": {"enabled": true}`), `vpn on`
   starts ssh on the upstream port and starts `vpn-router` on the public port.
   With router mode off, everything behaves exactly as today.

The app **never** reimplements what the CLI already does (system proxy,
Cisco's proxy copy, Keychain askpass, ssh loop, editing routes.json). It calls
the CLI. The router never edits config files; it only reads `routes.json` and
`connection.json`.

## 1. Hard rules (break one and the task fails review)

1. **Never touch the user's live VPN.** It is running right now from
   `~/.config/laptop-vpn` on port 1080. Do not run `vpn on|off|apply|try|set|unset|forget|reset-hostkey`
   against the real state dir. Do not run `networksetup -set*` or `scutil` writes.
   Do not bind 1080, 1081 or 1090. Every test uses a temp state dir through
   `LAPTOP_VPN_STATE=<tmpdir>` and ports from 18080 up.
2. **No new dependencies.** Swift: Apple frameworks only (SwiftUI, Charts,
   Network, Foundation, Security, AppKit, OSLog). Python: stdlib only, and it
   must run on macOS's `/usr/bin/python3` (3.9). Bash: what macOS ships (bash 3.2
   compatible: no `mapfile`, no `${var,,}`, no associative arrays).
3. **No Xcode.** Only Command Line Tools + Swift 6.1. Build with SwiftPM.
   **Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). XCTest is
   not available here and fails with `fatalError`. Never import XCTest.**
4. `// swift-tools-version:5.10` and `platforms: [.macOS(.v14)]`. Tools 5.10
   compiles in Swift 5 language mode, which avoids Swift 6 strict-concurrency
   errors. Do not raise the tools version and do not add language-mode settings.
   Tests that need the network or Chrome are mocked (Python: `unittest.mock`).
5. **Privacy.** Only host names, ports, byte counts and timings are recorded.
   Never payload bytes. Nothing leaves the Mac except: the SSH tunnel, the probes
   in §5.6, Grafana queries in §7, and the `vpn domains` lookups the user starts.
6. **Secrets.** The relay password stays in Keychain (service `vpnuser-relay`,
   account = `relay.user`). The Grafana token is in Keychain (service
   `gozar-grafana`, account `token`). The control-API token file is `0600`.
   Never log, print or put a secret in a URL.
7. Keep the house style of each file you edit: comments explain *why*, one line
   where possible; the existing Persian/English mix of user-facing text stays.
8. Work only in the files your task lists. If you need another file changed, ask.
9. Commits: the coordinator commits, not you. Leave changes uncommitted.
10. Every task ends with the evidence its "Done when" asks for, pasted in your
    `worker_done` report (command + its real output). Do not claim a check you
    did not run.

## 2. Repository layout (new and changed files)

```
infra/
  scripts/laptop-vpn.sh                 CHANGED (Task 1)
  scripts/laptop-vpn.d/vpnconf.py       CHANGED (Task 1)
  scripts/laptop-vpn.d/sitedomains.py   CHANGED (Task 1)
  scripts/laptop-vpn.d/connection.schema.json  CHANGED (Task 1)
  scripts/laptop-vpn.d/tests/           NEW (Task 1) python unittest, stdlib
  docs/LAPTOP-VPN.md                    CHANGED (Task 5, Persian)
  apps/laptop-vpn/
    PLAN.md                             this file (do not edit)
    Package.swift                       Task 2 only
    Sources/GozarCore/                  Task 2 (shared models, rules, config, API client)
    Sources/vpn-router/                 Task 3
    Sources/Gozar/                      Task 4 (the app)
    Tests/GozarCoreTests/               Task 2, Task 3 adds router tests
    Resources/                          Task 4/5 (Info.plist template, icon, askpass)
    scripts/build-app.sh                Task 5
    scripts/install.sh                  Task 5
    scripts/e2e.sh                      Task 3 (router), extended in Task 5
    Tests/fixtures/                     shared fixtures (routes json, fake socks server)
```

## 3. Config and state (shared contract)

State dir: `$LAPTOP_VPN_STATE`, default `~/.config/laptop-vpn`. Everything below
is relative to it. **Both the CLI and vpnconf.py and the Swift code must honour
`LAPTOP_VPN_STATE`.**

| file | who writes | content |
|---|---|---|
| `routes.json` | vpnconf.py (CLI) | rules, unchanged format (`routes.schema.json`) |
| `connection.json` | vpnconf.py / user | + new optional `router` block (below) |
| `ssh.log` | CLI | as today |
| `router.log` | vpn-router | one line per connection: `HH:MM:SS → host:port [route]`, plus `HH:MM:SS ✗ host:port [route] error` on failure, plus `--- <date> router started` lines. Rotated at 20 MB like ssh.log (truncate). |
| `router.pid` | CLI | pid of the router supervisor loop |
| `router.token` | vpn-router | 32 random bytes hex, mode 0600, rewritten at each start |
| `router.json` | vpn-router | `{"control_port": 18090, "pid": 123, "started_at": "<ISO8601>"}` written at start so clients find the API |

`connection.json` new block (all optional, defaults shown):

```json
"router": {
  "enabled": false,
  "upstream_port": 1081,
  "control_port": 1090
}
```

When `router.enabled` is true: ssh `-D` binds `127.0.0.1:<upstream_port>`;
`vpn-router` listens on `127.0.0.1:<local_socks_port>` (1080) and serves the
control API on `127.0.0.1:<control_port>`. When false: exactly today's behaviour.

## 4. Task 1 — CLI and Python groundwork (bash + python, no Swift)

Files: `scripts/laptop-vpn.sh`, `scripts/laptop-vpn.d/vpnconf.py`,
`scripts/laptop-vpn.d/sitedomains.py`, `scripts/laptop-vpn.d/connection.schema.json`,
new `scripts/laptop-vpn.d/tests/test_vpnconf.py`, `scripts/laptop-vpn.d/tests/test_cli.sh`.

### 4.1 vpnconf.py

- `STATE = Path(os.environ.get("LAPTOP_VPN_STATE") or Path.home() / ".config" / "laptop-vpn")`.
- `load_connection()`: accept the `router` key; validate `enabled` bool,
  `upstream_port`/`control_port` ints 1024–65535, all three ports distinct from
  `local_socks_port` and each other. Unknown keys inside `router` are an error.
- `cmd_conn_env()`: also print `ROUTER_ENABLED=0|1`, `UPSTREAM_PORT`, `CONTROL_PORT`.
- New `--json` flag (output on stdout, one JSON document, `ensure_ascii=False`):
  - `check HOST --json [--cisco]` → `{"host","route","rule":name|null,"pattern":str|null,"rule_route":str|null,"cisco":bool}`
    (`route` = effective route; `rule_route` = what the rule says).
  - `routes --json [--cisco]` → `{"path","cisco":bool,"rules":[{"name","route","without_cisco","enabled","note","domains":[...],"hosts":[...],"effective":str}]}`
    in file order, disabled rules included (`effective` = `"off"` for them).
- New rule commands (all validate with `check_routes` before writing, write with
  `_write(ROUTES, _with_guide(...))` exactly like `cmd_set`, print one line of
  human text, exit 1 with `config error:` on bad input):
  - `add-to NAME ROUTE SITE...` → `add_to_rule(data, NAME, ROUTE, SITES)` (creates the rule).
  - `rule-set NAME [--route R] [--without-cisco direct|vpn|none] [--enabled true|false] [--rename NEW] [--note TEXT]`
    (`--without-cisco none` removes the key; `--route` other than cisco also removes `without_cisco`).
  - `rule-delete NAME`.
  - `rule-move NAME --to INDEX` (0-based; order matters only for `hosts` matches, but the user wants to sort).
  - Rule names match case-insensitively; a missing rule is a `config error`.
- Keep `main()`'s structure; add the new commands there.

### 4.2 sitedomains.py

- `--json`: print one document instead of the text report:
  `{"site","title","via":"vpn"|"direct","listed":{"name","domains":[{"domain","route"}]}|null,"live":[{"host","route"}]|null,"suggested":[...]}`
  where `suggested` is what `--add` would add (same logic as today). `--json`
  with `--add` is an error. Text mode output must stay byte-identical.

### 4.3 laptop-vpn.sh

- `STATE="${LAPTOP_VPN_STATE:-${HOME}/.config/laptop-vpn}"`.
- Router mode (`ROUTER_ENABLED=1` from conn-env):
  - ssh `-D 127.0.0.1:${UPSTREAM_PORT}` instead of `SOCKS_PORT`.
  - Start a second background supervisor loop (pidfile `router.pid`) that runs
    `"$ROUTER_BIN" --state "$STATE"` and restarts it after 2 s if it exits
    (stop for good if it exits non-zero 5 times within 60 s, log `STOPPED: router keeps crashing` to `router.log`).
  - `ROUTER_BIN`: first `command -v vpn-router`, else `~/.local/bin/vpn-router`;
    missing → `die "router mode is on but vpn-router is not installed — run apps/laptop-vpn/scripts/install.sh, or set router.enabled to false"`.
  - "socks_listening" / exit IP test go through `SOCKS_PORT` as today (the router).
  - Wait for the upstream port first (ssh), then the router port, in `cmd_up`.
  - `bypass_list`: in router mode only the fixed local list (new `vpnconf.py bypass --router` prints `FIXED_DIRECT`), because the router routes everything else itself. The Cisco proxy copy gets the same list.
  - `cmd_down` stops both loops (and their children).
  - `vpn watch` tails `router.log` in router mode, `ssh.log` otherwise. `vpn top` reads the same file (`→` lines, field 3).
  - `cmd_status` adds `router: running on 127.0.0.1:<port>, control 127.0.0.1:<control_port>` or `router: off`.
- Sudo without a terminal: in `cisco_proxy`, when stdin is not a TTY and
  `SUDO_ASKPASS` is set, use `sudo -A -v` instead of warning. (The app sets
  `SUDO_ASKPASS` to its own dialog helper.)
- New `vpn status --json`: `{"loop":bool,"socks":bool,"exit_ip":str|null,"proxy":bool,"cisco":bool,"cisco_copy":bool|null,"router":{"enabled":bool,"running":bool,"control_port":int|null},"via":str|null,"stopped":str|null,"notes":[str]}`. Pure reads, no side effects, finishes in < 12 s (exit IP check has a 10 s cap; `--no-ip` skips it).
- Everything else unchanged. `bash -n` and `shellcheck` (if installed) clean.

### 4.4 Done when (Task 1)

- `python3 -m unittest discover -s scripts/laptop-vpn.d/tests -v` passes. Tests
  cover: LAPTOP_VPN_STATE, router block validation (good + 4 bad cases),
  conn-env router vars, `check --json` for: a listed domain, a subdomain, a TLD
  rule (`ir`), a `*.` rule, a bare host, an unlisted host, cisco on/off for a
  `cisco`+`without_cisco: vpn` rule; `routes --json` with a disabled rule;
  `add-to`, `rule-set` (each flag), `rule-delete`, `rule-move`, and that
  `routes.json` keeps its `_guide` after each edit.
- `scripts/laptop-vpn.d/tests/test_cli.sh` runs with a temp `LAPTOP_VPN_STATE`
  and **no network and no system changes**: `vpn routes`, `vpn check`,
  `vpn set`/`unset`, `vpn status --json --no-ip` (VPN off), `bash -n`.
- `git diff --stat` shows only the Task 1 files.

## 5. Task 2 — Swift package + GozarCore

Files: `apps/laptop-vpn/Package.swift`, `Sources/GozarCore/**`,
`Tests/GozarCoreTests/**`, `Tests/fixtures/routes.sample.json`,
placeholder `Sources/vpn-router/main.swift` and `Sources/Gozar/GozarApp.swift`
(each just prints/shows "TODO" so the package builds).

Products: library `GozarCore`; executables `vpn-router`, `Gozar`.

### 5.1 Models (`Models.swift`), all `Codable, Sendable, Equatable`

```swift
public enum Route: String, Codable, Sendable { case vpn, direct, cisco }
public struct Rule { name: String; route: Route; withoutCisco: Route?   // "without_cisco"
                     enabled: Bool; note: String?; domains: [String]; hosts: [String] }
public struct RoutesFile { rules: [Rule] }      // ignores "$schema" and "_guide"
public struct RouterSettings { enabled: Bool; upstreamPort: Int; controlPort: Int }
public struct ConnectionFile { relayHost: String; relayPort: Int; relayUser: String;
                               localSocksPort: Int; router: RouterSettings }   // decoded from the JSON shape in §3
public struct RouteDecision { route: Route; rule: String?; pattern: String? }
```

JSON keys follow the files exactly (`without_cisco`, `local_socks_port`, `upstream_port`…): use `CodingKeys`.

### 5.2 RuleEngine (`RuleEngine.swift`)

Port of `vpnconf.py` `parse_domain`, `match`, `effective` — **same results for every input**:

- `parseDomain("YouTube.com") == (.tree, "youtube.com")`, `"*.x.com" → (.sub, "x.com")`,
  `".x.com" → (.sub, "x.com")`, `"ir" → (.sub, "ir")`, URLs → host with `www.` stripped.
- `match(host)`: hosts entries first (exact, case-insensitive, or `*.suffix`), in
  rule order, **plus** (new, router only) an IPv4 CIDR entry like `10.0.0.0/8`
  matches an IPv4 literal host inside it. Then domains: longest matching name
  wins; `hit = host.hasSuffix("." + name) || (kind == .tree && host == name)`.
  Disabled rules are skipped.
- `effective(rule, ciscoUp)`: cisco & !ciscoUp → `withoutCisco ?? .direct`;
  direct & ciscoUp → `.cisco`; else rule.route.
- `decide(host, ciscoUp) -> RouteDecision`: no rule → `.vpn`. Always-direct
  before rules: `localhost`, `127.0.0.0/8`, `::1`, `*.local`, `169.254.0.0/16`,
  `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (mirror of `FIXED_DIRECT`),
  with rule name `"Local network"`.
- Precompute on init (sorted suffix table) so `decide` is O(labels), not O(rules × domains). It runs per connection.

**Golden test** (`RuleEngineGoldenTests.swift`): for `Tests/fixtures/routes.sample.json`
(copy the user's real rule *shapes*: the five default rules from
`scripts/laptop-vpn.d/routes.default.json` + one disabled rule + one `*.` rule +
one `hosts` rule with `*.`), run a Python one-liner via `Process`
(`/usr/bin/python3 -c` that imports `vpnconf` from `scripts/laptop-vpn.d`, loads
the fixture with `json.load`, and prints `match` + `effective` for a host list as
JSON) and compare with Swift for ≥ 40 hosts × cisco on/off. Include: `company.example`,
`www.company.example`, `x.y.corp.example.net`, `claude.ai`, `api.claude.ai`,
`shaparak.ir`, `ir`, `evil-ir.com`, `aparat.com`, `notaparat.com`,
`www.youtube.com`, `CORP-MGMT01`, `corp-mgmt01.corp`, `example.com`, IPs. (CIDR is
router-only, so leave CIDR hosts out of the golden set and test them separately.)

### 5.3 Config loading (`Config.swift`)

`StatePaths(stateDir:)` with `static func resolve()` (env `LAPTOP_VPN_STATE` or
`~/.config/laptop-vpn`) and URLs for every file in §3. `ConfigStore` loads
`routes.json`/`connection.json`, reports errors as text (never crashes on a bad
file), and exposes `func watch(onChange:)` that polls mtimes every 1 s (simple,
robust with editors that replace files).

### 5.4 Control API types (`ControlAPI.swift`)

The exact wire format of §6.3, as Codable structs (`ConnStat`, `DomainStat`,
`RouteTotals`, `ProbeStat`, `RouterStatus`, `RouterEvent` enum with exactly
`open(ConnStat)`, `close(ConnStat)`, `tick(Tick)` — the three SSE events of §6.3;
per-connection byte updates arrive inside `Tick.open_updates`. Unknown event
names are ignored, not errors). Dates as ISO8601 with fractional seconds; durations as
milliseconds `Double`; rates as bytes/second `Double`.

### 5.5 RouterClient (`RouterClient.swift`)

Reads `router.json` + `router.token`, `GET`s with `Authorization: Bearer`, and
`events()` returning `AsyncThrowingStream<RouterEvent, Error>` that parses SSE
(`event:`/`data:` lines) from `URLSession.bytes`. Reconnects are the caller's job.

### 5.6 Done when (Task 2)

`cd apps/laptop-vpn && swift build && swift test` both pass (paste the test
summary). Golden test runs ≥ 80 comparisons, 0 mismatches. `swift build -c release`
passes.

## 6. Task 3 — vpn-router

Files: `Sources/vpn-router/**`, router tests in `Tests/GozarCoreTests/Router*`
(put testable logic in `GozarCore/Router/` if tests need it), `Tests/fixtures/fake_socks.py`,
`scripts/e2e.sh`.

### 6.1 Process

`vpn-router --state DIR [--listen-port N] [--upstream-port N] [--control-port N]`
(ports default from `connection.json`). Logs with `os.Logger` (subsystem
`ir.mrbadri.gozar`, category `router`) **and** `router.log` (§3). Writes
`router.token` and `router.json` at start, removes `router.json` on SIGTERM/SIGINT
and exits 0. Exit 1 with a clear stderr line if a port is taken.

### 6.2 SOCKS5 data plane (Network.framework)

- `NWListener` on `127.0.0.1:<listen>` TCP, **loopback only**
  (`requiredLocalEndpoint`), `acceptLocalOnly = true`.
- RFC 1928 subset: version 5, method `00` (no auth) — reject others with `FF`;
  command CONNECT only (others → reply `07`); ATYP domain (03), IPv4 (01),
  IPv6 (04). Also accept SOCKS4a/SOCKS4 (`04`) CONNECT, because some macOS apps
  use it: reply `5A`/`5B`.
- Decide with `RuleEngine.decide(host, ciscoUp:)`. Cisco state: poll every 3 s
  with `/usr/sbin/scutil` reading `show State:/Network/Service/com.cisco.anyconnect/Proxies`
  (`<dictionary>` present = up), same test as the CLI. Reload rules when
  `routes.json` changes (ConfigStore.watch); a broken file keeps the last good
  rules and sets `rules_error`.
- `vpn` route: open TCP to `127.0.0.1:<upstream>`, do a SOCKS5 no-auth CONNECT
  with ATYP **domain** (never resolve locally; the egress resolves), then splice.
  If the upstream is down → reply `05`/`01` to the client, record `failed`.
- `direct`/`cisco` route: `NWConnection` to host:port (system resolver), reply
  success with BND `0.0.0.0:0`, splice.
- Reply to the client only after the outbound side is `.ready` (or failed).
  `connect_ms` = accept → outbound ready.
- Splice: two receive loops (64 KB max), backpressure by waiting for each
  `send` completion before the next receive. Half-close: on EOF from one side,
  send EOF (`isComplete`) to the other; close both when both finished or on error.
  Idle timeout none (SSH and browsers handle that).
- Count bytes per connection (`up` = client → remote, `down` = remote → client).
- Concurrency: one serial `DispatchQueue` per connection for its state + one
  stats actor/queue; never block the listener queue. Must sustain 300
  concurrent connections and 50 MB/s through `direct` on loopback in the e2e
  test without growing memory past 150 MB.

### 6.3 Control API (HTTP/1.1 on 127.0.0.1:<control>, loopback only)

Types: connection `id` is an `Int` (UInt64 range), increasing from 1 per router
process. A value that has no sample yet is `null` in JSON and optional in Swift
(`rules_loaded_at`, `connect_ms`, `connect_ms_avg`, `connect_ms_p90`, `ended_at`,
`rule`, `error`, probe `last_ms`/`median_ms`). Encoders omit nothing: optional
keys are written as `null` (use `encodeIfPresent` only if the decoder treats a
missing key as `null`, which it must anyway).

Every request needs `Authorization: Bearer <router.token>` (else 401). JSON with
`Content-Type: application/json`. Minimal HTTP parser: request line + headers
until CRLFCRLF, ignore bodies except `POST /v1/reload` (empty). Keep-alive not
needed (close after each response) except the SSE stream.

- `GET /v1/status` → `RouterStatus`:
  `{version, started_at, listen_port, upstream_port, upstream_up: Bool, cisco_up,
    rules_loaded_at, rules_error: String?, open: Int, total: Int,
    totals: {vpn: RouteTotals, direct: RouteTotals, cisco: RouteTotals},
    probes: [ProbeStat]}`
  `RouteTotals = {connections, open, failed, bytes_up, bytes_down, rate_up, rate_down}`
  (rates = bytes/s over the last 3 s, computed by the 1 s ticker from a ring buffer).
- `GET /v1/connections?limit=N` (default 300, max 2000) → `[ConnStat]`, open ones
  first, then most recently closed. Keep the last 2000 closed in a ring.
  `ConnStat = {id, host, port, route, rule: String?, started_at, connect_ms: Double?,
   ended_at?, state: "connecting"|"open"|"closed"|"failed", error: String?,
   bytes_up, bytes_down, rate_up, rate_down}`.
- `GET /v1/domains?window=S` (default 600) → `[DomainStat]` sorted by bytes desc:
  `{domain, hosts: [String] (≤ 20), route, rule?, connections, open, failed,
    bytes_up, bytes_down, rate_down, rate_up, connect_ms_avg, connect_ms_p90, last_seen}`.
  `domain` = registrable name: last two labels, or last three when the
  second-to-last label is one of `co com net org ac gov edu` and the last is a
  2-letter country code (`bbc.co.uk`, `ut.ac.ir`); IP literals stay as they are.
- `GET /v1/check?host=H` → `RouteDecision` + `cisco_up`.
- `POST /v1/reload` → 204, reloads rules now.
- `GET /v1/events` → `text/event-stream`, `Cache-Control: no-cache`. Events:
  `open` (ConnStat), `close` (ConnStat), `tick` every 1 s:
  `{at, totals, open_updates: [{id, bytes_up, bytes_down, rate_up, rate_down}]}`
  (only connections whose bytes changed). Send `: ping` every 15 s. Up to 8
  concurrent SSE clients; a slow client is dropped, never buffered without limit.

### 6.4 Probes (in the router, every 10 s, kept: last 30 samples each)

`ProbeStat = {name, target, last_ms: Double?, median_ms: Double?, loss: Double (0–1), samples: Int, last_error: String?}`

| name | what | meaning |
|---|---|---|
| `relay` | TCP connect to `relay.host:relay.port` (direct) | Mac → relay |
| `tunnel` | SOCKS5 CONNECT through upstream to `1.1.1.1:443`, time until CONNECT succeeds | Mac → relay → egress → 1.1.1.1 |
| `local` | direct TCP connect to `aparat.com:443` | the Mac's own internet (Iran) |

A probe that fails or takes > 5 s counts as loss. Probes do not appear in
connections/domains.

### 6.5 Done when (Task 3)

- `swift test` passes, with unit tests for: SOCKS5 greeting/request parsing
  (domain, IPv4, IPv6, bad version, bad method, BIND), SOCKS4a parsing,
  registrable-domain function (≥ 12 cases), HTTP request parsing + auth.
- `scripts/e2e.sh` passes and prints a summary. It: builds release; creates a
  temp state dir with a routes.json (`localhost` → direct via hosts rule, `*.test`
  not listed → vpn); starts `Tests/fixtures/fake_socks.py 18081` (stdlib SOCKS5
  server that maps any `*.test` name to 127.0.0.1 and counts connections); starts
  `python3 -m http.server 18088` serving a 20 MB file; starts
  `vpn-router --state $TMP --listen-port 18080 --upstream-port 18081 --control-port 18090`;
  then checks: `curl --socks5-hostname 127.0.0.1:18080 http://localhost:18088/big`
  (direct) and `http://vpn.test:18088/big` (vpn) both download 20 MB intact
  (sha256 match); fake_socks saw exactly the vpn one; `/v1/connections` shows both
  with the right route and `bytes_down ≥ 20_000_000`; `/v1/events` delivers an
  `open` and a `close` for a third request; 401 without token; 300 parallel
  small requests all succeed; router RSS < 150 MB (`ps -o rss`); SIGTERM exits 0
  and removes `router.json`. All processes are killed on exit (trap).
- No port below 18000 is used by any test.

## 7. Task 4 — Gozar.app (SwiftUI)

Files: `Sources/Gozar/**`, `Resources/**` (except icon art, Task 6).

### 7.1 Data sources

- **Router** via `RouterClient` (§5.5): status every 2 s, SSE events live,
  domains every 3 s. If the router is not running: show the "router off" state
  (the VPN may still be on in classic mode — then show `vpn status --json` data
  only and a card offering to turn router mode on).
- **CLI** via `CLI.run(args) async -> (code, stdout, stderr)`: binary = setting
  `vpnPath` (default `~/.local/bin/vpn`), env adds `SUDO_ASKPASS=<bundle>/Contents/Resources/gozar-askpass`
  and `PATH=/usr/bin:/bin:/usr/sbin:/sbin:~/.local/bin`. Never through a shell
  string; arguments as an array. A long action shows progress and its last
  output line; errors show the CLI's stderr in a sheet.
- **Grafana** via `GrafanaClient`: base URL setting (default
  `https://grafana.example.com`), token from Keychain (`gozar-grafana`/`token`).
  Find the Prometheus datasource uid once (`GET /api/datasources`, `type == "prometheus"`).
  Query with `POST /api/ds/query` (instant and 30-minute range, step 30 s).
  Refresh every 15 s while a window is visible, every 60 s otherwise. The queries:

  | key | PromQL |
  |---|---|
  | box | `egress_host_info` (labels `name`, `target`) |
  | since | `time() - max(egress_host_since_timestamp_seconds)` |
  | uptime | `time() - max(egress_host_boot_time_seconds)` |
  | steal | `sum(rate(egress_host_cpu_seconds_total{mode="steal"}[2m])) / clamp_min(sum(rate(egress_host_cpu_seconds_total[2m])), 0.001)` |
  | cpu_ours | same with `mode=~"user|nice|system|irq|softirq"` |
  | mem_free | `max(egress_host_memory_available_bytes) / max(egress_host_memory_total_bytes)` |
  | nic_tx | `sum(rate(egress_host_network_transmit_bytes_total[2m]))` |
  | ping | `max(egress_tunnel_icmp_rtt_seconds)` |
  | loss | `max(egress_tunnel_icmp_loss_ratio)` |
  | pools | `max by (pool) (egress_tunnel_pool_healthy_members)` |
  | phone_banner | `min(egress_tunnel_probe_median_seconds{pool="phone",probe="banner"})` |
  | openrouter | `min(egress_tunnel_probe_median_seconds{pool="app",probe="openrouter"})` |
  | members | `max by (pool, member) (egress_tunnel_haproxy_state)` |

### 7.2 Screens (sidebar `NavigationSplitView`, window min 1100×720)

Layout direction **right-to-left** for the whole app
(`.environment(\.layoutDirection, .rightToLeft)`, locale `fa_IR`). Technical
values (hosts, IPs, ms, MB/s) use Latin digits in `.monospacedDigit()`; keep
hosts LTR inside RTL rows (`Text(host).environment(\.layoutDirection, .leftToRight)`).
All user text comes from `Strings.swift` (§7.5); never hard-code Persian elsewhere.

1. **نمای کلی (Overview)** — the hero screen.
   - Top: a big connect switch (custom, 64 pt, animated gradient ring while
     connecting), state line («وصل · IP خروجی 198.51.100.20»), and two large live
     numbers ↓ ↑ (router totals, all routes) with `contentTransition(.numericText())`.
   - **The chain**: a horizontal path of 4 nodes — «این مک» → «سرور ایران» →
     «سرور خارج» → «اینترنت» — connected by animated links. Each link shows its
     latency and a health color; each node shows a small sparkline. Link values:
     Mac→relay = probe `relay`; relay→egress = Grafana `ping` + `loss`; egress→Internet
     = Grafana `openrouter`; plus a thin overlay line under the whole chain for
     probe `tunnel` (end-to-end). Egress node shows `box.name`, steal, free memory.
     Colors: green < thresholds (relay 60 ms, ping 150 ms, openrouter 1 s, steal 10 %),
     orange up to 2× that, red above, grey = no data. Moving dots travel along a
     link at a speed proportional to that route's current throughput (subtle; stop when idle).
   - Below: three route cards (VPN / مستقیم / Cisco): rate ↓↑, open connections,
     a 2-minute area chart (Swift Charts) of rate_down.
   - Bottom: «پرمصرف‌ها الان» — top 6 domains by `rate_down`, each with route
     chip and a mini bar.
2. **زنده (Live)** — a `Table` of connections, newest on top, streaming from SSE:
   time, host (LTR), port, route chip, rule, connect ms, ↓ bytes, ↑ bytes, live
   rate (only while open), state icon. Filter bar: search field, route segmented
   picker (همه/VPN/مستقیم/Cisco), «فقط باز», «فقط خطا». Pause button (keeps
   buffering, shows "۱۲۳ جدید" badge). Row context menu: «این دامنه از VPN برود»,
   «… مستقیم برود», «… از Cisco برود», «از قانون‌ها حذف شود» (all on the
   registrable domain, via `vpn set DOMAIN ROUTE` / `vpn unset DOMAIN`, then a
   toast «اعمال شد»), «کپی نام». Keep at most 5000 rows in memory.
3. **دامنه‌ها (Domains)** — `/v1/domains`, a sortable table: domain, route chip,
   connections, ↓ total, ↓ now, avg/p90 connect ms, failures, last seen. Selecting
   a domain opens an inspector (trailing panel): its hosts, a rate chart from the
   live events, the rule it matches (`/v1/check`), and buttons to change the route.
4. **قانون‌ها (Rules)** — the rules from `vpnconf.py routes --json` (via
   `vpn`-shipped python: run `/usr/bin/python3 -I <conf_dir>/vpnconf.py`, where
   `conf_dir` = `laptop-vpn.d` next to the real path of `vpnPath`). A list of rule
   cards in file order (drag to reorder → `rule-move`): name, route chip (menu to
   change → `rule-set --route`), «بدون Cisco» chip for cisco rules, enabled toggle,
   note, and the domains/hosts as removable tokens (× → `vpn unset X`) plus an
   «افزودن دامنه» field (→ `add-to NAME ROUTE X`, accepts a URL). «قانون تازه»
   button (name + route + first domain). «پیدا کردن دامنه‌های یک سایت»: a sheet that
   runs `vpn domains SITE --json` (spinner, it can take ~20 s), shows the community
   list and the live hosts with checkboxes and their current route, and adds the
   checked ones to a chosen rule/route (`add-to`). A «بررسی یک سایت» field shows
   `check --json` live as you type (debounced 300 ms). After every edit: if the VPN
   is on and router mode is off, run `vpn apply`; in router mode the router
   reloads by itself (call `POST /v1/reload` to be instant).
5. **سرور (Server)** — Grafana data: the box card (name, IP, since, uptime,
   steal gauge, memory gauge, NIC traffic), the four pools (healthy members as
   2 dots each), the 8 members table, ping/loss chart, steal chart (30 min). A
   «باز کردن در Grafana» button opens `/d/egress-tunnels`. If no token: an empty
   state with a field to paste the token (saved to Keychain) and a link to the
   doc section that explains how to make one.
6. **تنظیمات (Settings)** — connection.json fields (relay host/port/user, local
   port, keepalive, router block) edited in a form, saved by writing the JSON
   through `vpnconf.py` validation (write to a temp file, run `validate` with
   `LAPTOP_VPN_STATE` pointed at a temp copy, then move into place), then
   `vpn apply`. Password: «تغییر رمز» → secure field → Keychain update
   (`SecItemUpdate`/`SecItemAdd`, service `vpnuser-relay`, account = user).
   «خروج از سرور دیگر (try)» IP field → `vpn try IP`; «برگشت به حالت عادی» → `vpn on`.
   «فراموش کردن host key» → `vpn reset-hostkey` (confirm dialog). «پاک کردن رمز»
   → `vpn forget` (confirm). Router mode toggle. Grafana URL + token. Path of `vpn`.
   «باز شدن با روشن شدن مک» via `SMAppService.mainApp`.

### 7.3 Menu bar (`MenuBarExtra`, style `.window`)

Icon: SF Symbol `shield.lefthalf.filled` (on, accent), `shield.slash` (off),
`exclamationmark.shield` (problem). Next to it, when on: `↓ 1.2M` live (toggle
in settings). The popover (320 pt wide): the connect switch, exit IP, the chain
as 4 dots with latencies, ↓↑ now, top 5 domains now with route chips, buttons
«باز کردن گذر» and «خروج». Closing the main window keeps the app in the menu
bar (`NSApp.setActivationPolicy(.accessory)` when no window is open,
`.regular` when one is).

### 7.4 Design system (this is what makes it beautiful — follow it exactly)

- Window background: `.background(.windowBackground)` with a very subtle
  radial gradient of the current state's accent (8 % opacity) in the top
  trailing corner. Sidebar: default `List(.sidebar)` with SF Symbols.
- Cards: `RoundedRectangle(cornerRadius: 16, style: .continuous)` filled with
  `.regularMaterial`, 1 pt stroke `Color.primary.opacity(0.06)`, shadow
  `color: .black.opacity(0.08), radius: 12, y: 4`. Padding 16. Grid gap 16.
- Typography: titles `.title2.weight(.semibold)`; big numbers
  `.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()`;
  labels `.callout` secondary; tables `.body.monospacedDigit()`.
- Route colors (one place, `Theme.swift`):
  vpn = `Color(red: 0.42, green: 0.36, blue: 0.98)` (violet) → gradient to
  `Color(red: 0.25, green: 0.55, blue: 1.0)`; direct = `Color(red: 0.13, green: 0.72, blue: 0.62)` (teal);
  cisco = `Color(red: 0.98, green: 0.62, blue: 0.18)` (amber); failed = `.red`;
  health good/warn/bad = `.green`/`.orange`/`.red` at 0.9 saturation.
- Route chip: capsule, 10 pt horizontal padding, route color at 15 % fill, text
  in route color, `.caption.weight(.semibold)`, SF Symbol: vpn `lock.shield`,
  direct `arrow.right`, cisco `building.2`.
- Charts: `AreaMark` with a vertical gradient of the series color (35 % → 0 %),
  `LineMark` 2 pt on top, `.interpolationMethod(.catmullRom)`, no grid lines
  except a faint baseline, axis labels `.caption2`.
- Motion: `.animation(.smooth(duration: 0.35), value:)` for state changes,
  `.contentTransition(.numericText())` for live numbers, `.symbolEffect(.pulse)`
  on the connect icon while connecting. Respect `accessibilityReduceMotion`:
  no moving dots, no pulses.
- Light and dark mode both must look right (materials do most of it; never
  hard-code white/black text).
- Empty states: `ContentUnavailableView` with a symbol and one Persian sentence.
- Every interactive control has an accessibility label.

### 7.5 Strings (`Strings.swift`, `enum L`) — use these exactly

```
appName = "گذر"
tabOverview = "نمای کلی";  tabLive = "زنده";  tabDomains = "دامنه‌ها"
tabRules = "قانون‌ها";  tabServer = "سرور";  tabSettings = "تنظیمات"
connect = "وصل شو";  disconnect = "قطع کن";  connecting = "در حال وصل شدن…"
connected = "وصل";  disconnected = "قطع";  exitIP = "IP خروجی"
routeVPN = "VPN";  routeDirect = "مستقیم";  routeCisco = "Cisco"
nodeMac = "این مک";  nodeIran = "سرور ایران";  nodeEgress = "سرور خارج";  nodeInternet = "اینترنت"
download = "دانلود";  upload = "آپلود";  openConnections = "اتصال باز"
topNow = "پرمصرف‌ها الان";  all = "همه";  onlyOpen = "فقط باز";  onlyErrors = "فقط خطا"
pause = "مکث";  resume = "ادامه";  newRows = "%d جدید"
sendViaVPN = "این دامنه از VPN برود";  sendDirect = "این دامنه مستقیم برود"
sendCisco = "این دامنه از Cisco برود";  removeFromRules = "از قانون‌ها حذف شود"
copyName = "کپی نام";  applied = "اعمال شد"
addDomain = "افزودن دامنه";  newRule = "قانون تازه";  findDomains = "پیدا کردن دامنه‌های یک سایت"
checkSite = "بررسی یک سایت";  withoutCisco = "بدون Cisco";  ruleOff = "خاموش"
communityList = "فهرست عمومی";  liveHosts = "دیده‌شده هنگام باز کردن سایت";  addSelected = "افزودن انتخاب‌شده‌ها"
steal = "CPU دزدیده‌شده";  freeMemory = "حافظهٔ آزاد";  uptime = "روشن از";  onThisBoxSince = "روی این سرور از"
pools = "مسیرها";  openInGrafana = "باز کردن در Grafana"
noToken = "برای دیدن وضعیت سرور، توکن Grafana را وارد کن."
routerOff = "مسیریاب خاموش است؛ برای دیدن همهٔ درخواست‌ها، حالت مسیریاب را روشن کن."
vpnOffEmpty = "VPN خاموش است."
changePassword = "تغییر رمز";  forgetPassword = "پاک کردن رمز";  resetHostKey = "فراموش کردن کلید سرور"
tryBox = "خروج از سرور دیگر";  backToNormal = "برگشت به حالت عادی"
routerMode = "حالت مسیریاب";  launchAtLogin = "باز شدن با روشن شدن مک"
openApp = "باز کردن گذر";  quit = "خروج";  save = "ذخیره";  cancel = "انصراف"
confirmResetHostKey = "بعد از عوض شدن سرور خارج لازم است. ادامه بدهم؟"
confirmForget = "رمز از Keychain پاک می‌شود و دفعهٔ بعد دوباره پرسیده می‌شود."
error = "خطا";  details = "جزئیات"
```

(Format numbers with a shared `Fmt` helper: bytes `1.2 MB`, rates `1.2 MB/s`,
ms `85 ms` / `1.2 s`, durations `3h 12m`, all Latin digits.)

### 7.6 Demo mode and snapshots (for review without a running VPN)

- `Gozar --demo`: every data source replaced by `DemoData` (a believable
  scripted feed: ~40 domains incl. youtube, googlevideo, github, aparat,
  company, claude.ai; rates that move; one failing host; Grafana values like
  egress-box today).
- `Gozar --snapshot DIR`: renders each of the 6 screens + the menu bar popover
  with demo data, light and dark, at 1280×800 (popover 320×520), using
  `ImageRenderer` (scale 2), writes `DIR/<screen>-<light|dark>.png`, and exits.
  This is how the coordinator reviews the design. It must not need screen-recording
  permission.

### 7.7 Done when (Task 4)

`swift build -c release` passes with **zero warnings in Sources/Gozar**;
`swift test` passes; `Gozar --snapshot /tmp/gozar-shots` writes 14 PNGs (paste
`ls -la`); unit tests for `Fmt`, SSE parsing (in GozarCore), and the Grafana
response parser (a recorded fixture JSON in `Tests/fixtures/grafana/`).

## 8. Task 5 — packaging, install, docs, end-to-end

Files: `scripts/build-app.sh`, `scripts/install.sh`, `Resources/Info.plist`,
`Resources/gozar-askpass`, `scripts/e2e.sh` (extend), `docs/LAPTOP-VPN.md`
(new Persian section «اپ گذر»), `connection.default.json` (add the router block,
`enabled: false`).

- `build-app.sh`: `swift build -c release`, then assemble `build/Gozar.app`:
  `Contents/MacOS/Gozar`, `Contents/MacOS/vpn-router`, `Contents/Info.plist`
  (`CFBundleIdentifier ir.mrbadri.gozar`, `CFBundleName گذر`,
  `CFBundleDisplayName گذر`, `LSMinimumSystemVersion 14.0`, `CFBundleIconFile AppIcon`,
  `NSHumanReadableCopyright`), `Contents/Resources/AppIcon.icns` (from
  `Resources/icon-1024.png` via `sips` + `iconutil`), `gozar-askpass` (executable),
  then `codesign --force --deep -s -` (ad-hoc). Print the app path and size.
- `gozar-askpass`: `#!/bin/sh` + `osascript` dialog with hidden answer, Persian
  prompt «گذر برای به‌روز کردن تنظیمات Cisco رمز مک را لازم دارد», prints the
  answer; cancel → exit 1.
- `install.sh`: build, copy to `~/Applications/Gozar.app` (replace), symlink
  `~/.local/bin/vpn-router` → the bundled router, print next steps. Never
  touches the running VPN or connection.json.
- `e2e.sh` extended: run the Task 1 CLI tests and the router e2e; plus a
  **CLI router-mode** test with a temp state dir where `ssh` is replaced by a
  stub on PATH that runs `fake_socks.py` on the upstream port (so `vpn on`
  starts "ssh" + router; **`networksetup`/`scutil`/`sudo` are stubbed too** —
  the test must prove no real system call happens: the stubs log calls to a file,
  the test asserts the expected calls). Check `vpn status --json` shows the
  router running, `vpn watch`/`vpn top` read router.log, `vpn off` stops both.
- Docs: how to install, turn on router mode, make a Grafana token (Grafana →
  Administration → Service accounts → Viewer → token), what each screen shows.

Done when: `scripts/e2e.sh` passes end to end (paste summary), `build-app.sh`
produces a signed app (`codesign -dv` output), and the app launches with
`open build/Gozar.app --args --demo` without crashing for 10 s (check with
`pgrep -f Gozar` then quit it with `osascript -e 'quit app "Gozar"'`).

## 9. Task 6 — app icon (image generation)

`Resources/icon-1024.png`, 1024×1024, macOS Big Sur+ icon style: rounded
square (squircle) with a soft violet→blue gradient (match the vpn route colors
in §7.4), a stylised path/route line passing through a gate or arch (the name
"Gozar" means passage), subtle depth, no text, no letters, transparent outside
the squircle. Also `Resources/icon-1024-dark.png` variant is not needed.

## 10. Order and ownership

| # | task | depends on | agent |
|---|---|---|---|
| 1 | CLI + Python groundwork | — | Codex |
| 2 | Swift package + GozarCore | — | Codex |
| 6 | Icon | — | Codex (image) |
| 3 | vpn-router | 2 | Codex |
| 4 | Gozar.app | 2 | Codex |
| 5 | Packaging, e2e, docs | 1, 3, 4, 6 | Codex |
| R | Review of each task, fixes sent back, final live switch-over | each | Opus |

Tasks 1, 2 and 6 run in parallel; 3 and 4 run in parallel after 2. They share
one checkout, so stay inside your task's files.
