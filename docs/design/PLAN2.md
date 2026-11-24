# Gozar — stage 2: exits, V2Ray, self-contained setup, design

Read `PLAN.md` first: every rule in its §1 still applies (never touch the live
VPN; temp `LAPTOP_VPN_STATE` and ports ≥ 18000 in tests; no new dependencies;
Swift Testing only; no Xcode; do not commit; ask when unsure). This file adds
to it. Where they disagree, this file wins.

**Live state warning (stronger than before):** the user's VPN now runs in
router mode: `vpn-router` on 1080/1090 and ssh on 1081, from
`~/.config/laptop-vpn`, with `~/.local/bin/vpn-router` → `~/Applications/Gozar.app`.
Do not run `install.sh` against the real `$HOME`, do not replace
`~/Applications/Gozar.app`, and never bind 1080, 1081, 1090.

## 0. What the owner asked for

1. Adding and removing domains must be easy from everywhere in the app.
2. **Exits**: a list of connection servers the user can add, remove, rename,
   test and switch between: the SSH relay (today's only option) **and V2Ray**
   (VLESS, VMess, Trojan, Shadowsocks links, and subscription URLs).
3. **Self-contained**: hand `Gozar.app` to someone with a plain Mac (no
   Command Line Tools, so **no python3**, no infra repo) and they set it up
   inside the app with a wizard.
4. A more professional, striking design.

## 1. Architecture changes

- **`gozarctl`** (new Swift executable, product of the package) replaces
  `vpnconf.py` as the config tool. Same commands, same output, same files, plus
  the exit commands. `laptop-vpn.sh` calls `gozarctl` (found next to itself in
  the app bundle, else on PATH, else `apps/laptop-vpn/.build/release/gozarctl`,
  else falls back to `/usr/bin/python3 vpnconf.py` with a note). `vpnconf.py`
  stays in the repo as the golden reference for tests; it is not shipped.
- **Exits** live in a new file `exits.json` (§2). The active exit decides how
  the upstream is made: `ssh -D` (today) or an **Xray client** with a SOCKS
  inbound. Everything downstream (router, system proxy, Cisco, app) is unchanged:
  the upstream is always a SOCKS server on `TUNNEL_PORT` (1081 in router mode,
  1080 in classic mode).
- **Xray** is bundled in the app (pinned version, checksum-verified at build,
  universal arm64+x86_64). The CLI supervises it exactly like the ssh loop.
- **The app bundle carries everything**: `Contents/MacOS/{Gozar,vpn-router,gozarctl}`,
  `Contents/Resources/cli/laptop-vpn.sh` + `cli/laptop-vpn.d/` (schemas,
  defaults, docs, `_vpn` completion; not the .py files), `Contents/Resources/xray/xray`
  (+ `geoip.dat`, `geosite.dat`), `Contents/Resources/fonts/Vazirmatn-*.ttf` + `OFL.txt`.
  The app uses its bundled CLI unless the settings point elsewhere.

## 2. `exits.json` (state dir)

```json
{
  "active": "relay",
  "exits": [
    { "id": "relay", "name": "سرور اصلی", "kind": "ssh",
      "host": "203.0.113.10", "port": 47853, "user": "vpnuser" },
    { "id": "x7f3a9c", "name": "Phosfor", "kind": "xray",
      "link": "vless://…", "subscription": "s1a2b3c" }
  ],
  "subscriptions": [
    { "id": "s1a2b3c", "name": "panel.example.com", "url": "https://panel.example.com/sub/…",
      "updated_at": "2026-11-24T06:00:00Z", "error": null }
  ]
}
```

- `id`: `relay` for the migrated one; otherwise a prefix + 6 random hex
  characters: `x` for an xray exit, `h` for an ssh exit, `s` for a subscription
  (`x7f3a9c`, `h0b12ef`, `s1a2b3c`). Stable forever.
- **Migration** (`gozarctl init`): if `exits.json` is missing, create it from
  `connection.json` → `relay` with id `relay`, name «سرور اصلی», active. From
  then on `relay` in `connection.json` is ignored (kept for rollback to an older
  `vpn`); `connection.json` keeps only local settings.
- **Secrets**: SSH passwords in Keychain. Exit `relay`: service `vpnuser-relay`,
  account = its user (unchanged, so the live password keeps working). Any other
  ssh exit: service `gozar-ssh`, account = exit id. Xray links contain their
  credentials (uuid); `exits.json` is written mode 0600 and the state dir is 0700.
- A subscription refresh replaces the exits that came from it (matched by
  link identity: protocol + address + port + uuid/password), keeps their ids and
  names when they still exist, adds new ones, removes vanished ones, and keeps
  `active` valid (if the active exit vanished, keep it until the user picks
  another; mark it `"stale": true`).
- Exit names from links: the `#fragment` (URL-decoded), else `host:port`.

## 3. Task 7 — `gozarctl` (Swift)

Files: `Package.swift` (add executable `gozarctl` depending on GozarCore),
`Sources/gozarctl/**`, `Sources/GozarCore/Conf/**` (new), `Tests/GozarCoreTests/Conf*.swift`,
`Tests/fixtures/links/**`.

### 3.1 Port of vpnconf.py, byte-for-byte compatible

Every command of `scripts/laptop-vpn.d/vpnconf.py` (read it all), same
arguments, same stdout/stderr text, same exit codes, same JSON, and **the same
file bytes** when it writes `routes.json`/`connection.json` (its `_dump`
formatter, `_guide` handling and key order). Honour `LAPTOP_VPN_STATE`.
Defaults and schemas are read from the `laptop-vpn.d` directory given by
`--conf-dir` or env `LAPTOP_VPN_CONF_DIR`, else next to the executable's
`../Resources/cli/laptop-vpn.d`, else `scripts/laptop-vpn.d` up the tree.

**Golden test** (`ConfGoldenTests.swift`): for a matrix of ≥ 60 invocations
(every command; good and bad inputs; cisco on/off; each rule command; `init`
on an empty dir and on an old `direct.txt`), run python `vpnconf.py` and
`gozarctl` each in its own fresh temp state dir seeded identically, and compare
exit code, stdout, stderr and the resulting files byte for byte. 0 mismatches.

### 3.2 New commands (all accept `--json`)

| command | does |
|---|---|
| `exits` | list: `{"active": id, "exits": [{id,name,kind,address,port,protocol?,subscription?,stale?}], "subscriptions": [...]}` — never prints links or passwords |
| `exit-add LINK… [--name N]` | add one exit per `vless://`, `vmess://`, `trojan://`, `ss://` link; prints the new ids |
| `exit-add-ssh HOST PORT USER [--name N]` | add an ssh exit; prints the id (password is set by the caller in Keychain) |
| `exit-rm ID`, `exit-rename ID NAME`, `exit-use ID` | edit; `exit-use` only changes `active` |
| `sub-add URL [--name N]`, `sub-update [ID]`, `sub-rm ID` | subscriptions; `sub-rm` also removes its exits (not the active one: error) |
| `exit-test ID… [--all] [--seconds 8]` | for each exit: start a temporary upstream on a free port ≥ 18300 (xray with the generated config, or ssh -D with SSH_ASKPASS reading Keychain), then through it: TCP CONNECT time to `1.1.1.1:443` (median of 3), then download `https://speed.cloudflare.com/__down?bytes=2000000` (cap at `--seconds`); stop the upstream. JSON: `[{id, ok, connect_ms, mbps, error}]`. Run up to 3 tests in parallel. |
| `xray-config ID --port N` | print the full Xray client config JSON for that exit (SOCKS inbound `127.0.0.1:N`, no auth, UDP off; one outbound from the link; routing: everything to it; log warning) |
| `conn-env` | as today, plus `EXIT_ID`, `EXIT_KIND=ssh|xray`, for ssh `HOST PORT USER_NAME KEYCHAIN_SERVICE KEYCHAIN_ACCOUNT`, for xray `XRAY_CONFIG=<state>/xray.json` (written 0600, inbound on the right TUNNEL_PORT for router/classic mode) and `XRAY_BIN` (bundled path if it exists) |
| `domains SITE --json` | port of sitedomains.py's **community list** part only (v2fly geosite fetch + includes, through the VPN SOCKS port if listening); same JSON shape as `sitedomains.py --json` with `live: null`. The Chrome live part stays python-only. |

Subscription fetch: HTTP GET with `User-Agent: v2rayNG/1.9.27`, through
`socks5h://127.0.0.1:<local_socks_port>` if it is listening, else direct;
body is base64 (standard or URL-safe, padding optional) of newline-separated
links, or plain links; ignore lines that are not supported links (count them).

### 3.3 Link parsing (`GozarCore/Conf/Links.swift`) → Xray outbound

- `vless://uuid@host:port?…#name`: `encryption` (default `none`; keep any
  value like `mlkem768x25519plus.native.0rtt.…` verbatim), `flow`, `security`
  (`none|tls|reality`), `sni`, `fp`, `alpn`, `pbk`, `sid`, `spx`, `type`
  (`tcp|ws|grpc|xhttp|httpupgrade`), `headerType`, `host`, `path`, `serviceName`, `mode`.
- `vmess://base64(json)` (v2rayN format: `add port id aid scy net type host path tls sni alpn fp ps`).
- `trojan://password@host:port?security=…&sni=…&type=…#name`.
- `ss://` SIP002 (`base64(method:password)@host:port#name` and the fully-base64 legacy form).
- IPv6 hosts in brackets. Bad links → a clear error naming the field.
- Fixtures: at least the owner's panel link shape
  (`vless://<uuid>@203.0.113.10:47861?encryption=mlkem768x25519plus.random.<key>&security=none&type=tcp&headerType=none#Phosfor`),
  a REALITY vless, a ws+tls vless, vmess ws, trojan grpc, ss. Unit-test the
  produced outbound JSON against expected files.

Done when: `swift build -c release`, `swift test` (golden 0 mismatches, link
tests), and a short transcript of `gozarctl exits/exit-add/exit-use/sub-add` on a
temp state dir (sub-add against a local `python3 -m http.server` serving a
base64 file).

## 4. Task 8 — CLI on gozarctl + Xray, packaging, e2e

Files: `scripts/laptop-vpn.sh`, `scripts/laptop-vpn.d/tests/test_cli.sh`,
`apps/laptop-vpn/scripts/{build-app.sh,install.sh,e2e.sh,fetch-xray.sh}`,
`apps/laptop-vpn/Resources/xray.lock` (version + sha256s), `Resources/Info.plist`,
`docs/LAPTOP-VPN.md` (update the «اپ گذر» section; add «سرورها و V2Ray»).

- `laptop-vpn.sh`: `conf()` runs gozarctl (lookup in §1). `run_loop` starts
  `"$XRAY_BIN" run -c "$XRAY_CONFIG"` when `EXIT_KIND=xray` (log its lines to
  `ssh.log` with the same timestamp filter; stop for good if it exits 5 times
  within 60 s with `STOPPED: xray keeps exiting — check the link (vpn exits)`),
  ssh otherwise (password lookup uses `KEYCHAIN_SERVICE/ACCOUNT`). `ensure_password`
  only for ssh. New commands: `vpn exits`, `vpn exit add|rm|rename|use|test`,
  `vpn sub add|update|rm` (thin wrappers over gozarctl; `exit use` runs
  `apply` when the VPN is on so it reconnects through the new exit; `exit add
  ssh://user@host:port` asks the password in a terminal and stores it).
  Update `vpn help` and completion.
- `fetch-xray.sh`: download Xray `26.10.31` `Xray-macos-arm64-v8a.zip` and
  `Xray-macos-64.zip` from the XTLS GitHub release, verify each against its
  published `.dgst` SHA2-256, record both in `Resources/xray.lock`, and build a
  universal `xray` with `lipo`. `build-app.sh` uses a cached verified copy
  (`.build/xray/`), refuses a mismatch, and copies everything in §1 into the bundle.
- e2e additions: (a) a **real Xray round trip on loopback**: an Xray *server*
  (VLESS, encryption none, tcp, port 18443, freedom outbound) and the CLI in a
  temp state with an exit added from a matching `vless://` link → `vpn on`
  (stubs for networksetup/scutil/sudo as before) → curl through the router to the
  local http server works and the router shows route `vpn`; `vpn exit test`
  returns ok with a connect time; switching back to an ssh exit (stubbed ssh)
  works. (b) `sub-add` + `sub-update` against a local http server. (c) the CLI
  works with **python3 hidden** (PATH without it and `/usr/bin/python3` not
  called — wrap it with a stub that fails the test if invoked).

Done when: e2e passes end to end; `build-app.sh` produces a signed universal app
whose bundle contains every item in §1 (`find build/Gozar.app` excerpt); `lipo
-info` of the bundled xray shows both architectures.

## 5. Task 9 — the app: wizard, Servers screen, domains everywhere, new design

Files: `Sources/Gozar/**`, `Sources/GozarCore/App/**`, `Tests/GozarCoreTests/App*.swift`,
`Resources/fonts/**` (copy Vazirmatn Regular/Medium/SemiBold/Bold + OFL.txt from
`~/.claude/skills/persian-writing/assets/fonts/`; write OFL.txt with the SIL Open
Font License 1.1 text and the Vazirmatn copyright line if it is missing there).

### 5.1 Data and paths

- The app talks to the CLI and to `gozarctl --json` (exits, subs, tests, rules,
  check, domains). Default CLI = the bundled `Contents/Resources/cli/laptop-vpn.sh`;
  settings may point to another `vpn`. Pass `LAPTOP_VPN_CONF_DIR` = bundled dir.
- Every edit (domains, rules, exits) shows a toast with the result
  («اعمال شد» / the error text) and refreshes the affected data.

### 5.2 First-run wizard («راه‌اندازی»)

Shown when `exits.json` has no exits or `connection.json` is missing; re-runnable
from Settings. A centered glass sheet, 5 steps with a progress indicator:
1. **خوش آمدی** — app icon, «گذر اینترنتت رو از سرورِ خودت عبور می‌ده.», button «شروع».
2. **سرور** — two tabs: «لینک یا اشتراک» (a large paste field accepting one or
   many links or a subscription URL; «از کلیپ‌بورد»; «از تصویر QR» — pick an image,
   decode with `CIDetector(ofType: CIDetectorTypeQRCode)`) and «SSH» (host, port,
   user, password → Keychain). Validation inline.
3. **آزمایش** — runs `exit-test` on what was added; shows each exit with
   connect ms and Mbit/s, best one preselected.
4. **تنظیمات** — toggles: «حالت مسیریاب (پیشنهادی)» on; «باز شدن با روشن شدن مک»;
   «نصب دستور vpn در ترمینال» (symlink `~/.local/bin/vpn` → bundled CLI, only if
   that path is free or already ours; never overwrite another file).
5. **آماده‌ای** — «وصل شو» runs `vpn on`; success animation (checkmark + ring).

### 5.3 «سرورها» screen (replaces «سرور»)

- Header: «سرورها» + buttons «افزودن» (⌘⇧N, opens the step-2 UI as a sheet) and
  «آزمایش همه».
- Exit cards in a grid: kind badge (SSH / VLESS / VMess / Trojan / SS),
  name, address (`host:port`, LTR), last test (connect ms, Mbit/s, colored),
  a «فعال» glowing badge on the active one; actions: «استفاده» (→ `vpn exit use`),
  «آزمایش», «تغییر نام», «حذف» (confirm; disabled for the active exit). A
  subscription's exits are grouped under its header (name, count, updated
  time, «به‌روزرسانی», «حذف اشتراک»).
- Below, collapsible «مانیتورینگ سرور (Grafana)»: today's server panels, shown
  only when a Grafana token is set; otherwise a one-line hint with a button to
  Settings. (Grafana is optional and off for new users.)

### 5.4 Domains, everywhere

- A toolbar button «افزودن سایت» (⌘N) on every screen: sheet with a field
  (domain or URL), a big three-way route picker (VPN / مستقیم / Cisco, with
  their colors and one-line explanations), an optional rule picker («قانون تازه»
  by default), and the live `check --json` result under the field. → `vpn set`
  or `gozarctl add-to`.
- Domains screen: row context menu (VPN / مستقیم / Cisco / حذف از قانون‌ها /
  کپی) and the inspector's route picker; Live: same context menu (already there).
- Rules screen: keep; make the «×» remove and the add field obvious (bigger
  hit targets, hover states).
- Real data only outside `--demo`: the Rules screen must show the user's
  real `routes.json` (e.g. «Claude» → Cisco, without Cisco → VPN).

### 5.5 Design overhaul — "Night Gate"

Replace §7.4 of PLAN.md with this (keep its structure rules):

- **Font**: register the bundled Vazirmatn at launch
  (`CTFontManagerRegisterFontsForURL`, scope `.process`). All UI text uses
  Vazirmatn (`Font.custom("Vazirmatn", size:, relativeTo:)`, weights via the
  family's faces); hosts, IPs and code use `.system(.body, design: .monospaced)`.
- **Window**: `.windowStyle(.hiddenTitleBar)`, content under the title bar,
  traffic lights kept; min 1180×760. Remove the duplicated «گذر» title.
- **Background**: dark `#0A0C18 → #121530` vertical gradient with two large
  blurred blobs (violet `#7C5CFF`, cyan `#22D3EE`, 16 % opacity, blur 120) that
  drift slowly (40 s loop; static with Reduce Motion). Light: `#F7F8FC → #ECEEF8`
  with the same blobs at 10 %.
- **Glass cards**: `.ultraThinMaterial`, radius 20 continuous, 1 pt gradient
  border (white 16 % top → white 3 % bottom; light mode black 8 % → 2 %), inner
  top highlight, shadow `black 25 %, r 24, y 12` (light: 8 %). Hover: lift 2 pt.
- **Colors** (`Theme.swift`): accent gradient `#7C5CFF → #3B82F6`; direct
  `#14B8A6`; cisco `#F59E0B`; good `#22C55E`; warn `#F59E0B`; bad `#F43F5E`;
  text primary/secondary from the system. Route chips: gradient fill at 18 %,
  1 pt border at 35 %, text in the route color.
- **Glow**: active things (active exit, connect button, selected sidebar item,
  live dots) carry a colored shadow (40 %, r 18).
- **Sidebar**: custom (not `List(.sidebar)` look): app icon + «گذر» at top,
  items as rows with SF Symbols, the selected one a gradient pill with glow;
  at the bottom a mini status card: state dot, active exit name, ↓↑ now.
- **Hero** (Overview): the connect button as a 120 pt circle with an animated
  angular-gradient ring while connecting and a soft breathing glow when
  connected; throughput numbers 52 pt in Vazirmatn SemiBold with gradient text;
  under them the active exit's name with a «تغییر» menu.
- **Chain**: nodes as glass circles (56 pt) with icons; links as 6 pt gradient
  capsules colored by health with particles flowing along them
  (`TimelineView` + `Canvas`, speed by throughput); latency pills centered on links.
- **Charts**: gradient areas, a 2 pt line with a soft glow, rounded caps.
- **Tables**: no zebra; hover highlight; sticky header; 40 pt rows; hosts mono.
- **Motion**: springs (`.spring(response: 0.4, dampingFraction: 0.8)`);
  `.contentTransition(.numericText())`; toasts slide in from the top.
- **Menu bar popover**: same glass + gradient language, exit switcher at top.

### 5.6 Done when

`swift build -c release` with zero warnings in `Sources/Gozar`; `swift test`;
`Gozar --snapshot /tmp/gozar-shots-2` writes the 6 screens + popover + the 5
wizard steps + the add-site sheet + the add-exit sheet, light and dark. Look at
every image yourself and iterate until it looks like a top-tier Mac app. Unit
tests for: exits JSON decoding, QR decode helper (a fixture PNG made in the
test with CIFilter.qrCodeGenerator), and the add-site flow's command building.

## 6. Order

| # | task | depends on |
|---|---|---|
| 7 | gozarctl | — |
| 9 | app | — (codes against §2/§3 JSON; demo mode for snapshots) |
| 8 | CLI + Xray + packaging + e2e | 7 |
| R | Opus review of each; final: real install, migrate the owner's live config, switch to the new app | all |

## 7. Clarifications (answers to worker questions)

- **Golden vs. new behaviour.** `gozarctl init` also creates `exits.json`; python
  does not. The golden test compares only the files python writes
  (`routes.json`, `connection.json`, `direct.txt.old`) and ignores `exits.json`.
  `conn-env`: gozarctl prints python's lines first, identical and in the same
  order, then the new lines; the golden check for `conn-env` is "python output
  is an exact prefix". The legacy `HOST/PORT/USER_NAME` lines come from the
  active ssh exit once `exits.json` exists (for the migrated `relay` they equal
  python's). After migration, validation ignores `connection.json`'s `relay`,
  which stays on disk for rollback.
- **Wire shapes (`--json`).**
  - `exits`: `{"active": id|null, "exits": [{id, name, kind: "ssh"|"xray", protocol: "ssh"|"vless"|"vmess"|"trojan"|"ss", address, port, subscription: id|null, stale: bool}], "subscriptions": [{id, name, host, count, updated_at, error}]}`.
    `host` = the URL's host only; never the full URL (it holds a token), never links or passwords.
  - `exit-add`, `exit-add-ssh`: `{"ids": [...]}` (ssh: one id). `exit-rm`, `exit-rename`, `exit-use`: `{"id": ..., "active": ...}`.
  - `sub-add`, `sub-update`: `{"id": sub_id | "ids": [...], "added": n, "updated": n, "removed": n, "ignored": n}` (sub-update without ID: `"ids"`).
  - `sub-rm`: `{"id": ..., "removed": n}`.
  - Errors with `--json`: exit 1, stderr human text, stdout `{"error": "..."}`.
