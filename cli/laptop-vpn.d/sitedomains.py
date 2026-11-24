"""`vpn domains SITE`: find the domains a site uses, so they can go in routes.json.

Two sources, both printed:

  list  the community-kept list for that service (v2fly/domain-list-community,
        the "geosite" lists VPN apps use): curated, but only for known services
  live  load the site in headless Chrome and record every host it talks to:
        works for any site, but also shows shared CDNs and trackers

Downloads go through our VPN when it is up (127.0.0.1:<socks>), else direct.
Stdlib only (macOS's /usr/bin/python3 is 3.9).
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # run with python3 -I
import vpnconf  # noqa: E402

GEOSITE = "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/{name}"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Second-level suffixes where the "site" is one label further left.
MULTI_SUFFIX = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "co.kr",
    "co.in", "co.nz", "com.br", "com.tr", "com.cn", "com.hk", "com.tw", "com.sg", "com.mx",
    "co.ir", "ac.ir", "gov.ir", "org.ir", "sch.ir", "id.ir", "net.ir",
}
# Infrastructure many sites share: adding the whole domain would move far more
# than the one site, so these are offered host by host.
SHARED = {
    "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "googletagmanager.com",
    "google-analytics.com", "doubleclick.net", "googlesyndication.com", "gvt1.com", "gvt2.com",
    "cloudfront.net", "amazonaws.com", "akamaihd.net", "akamaized.net", "akamai.net", "edgekey.net",
    "fastly.net", "fastly.com", "cloudflare.com", "cloudflare.net", "jsdelivr.net", "unpkg.com",
    "azureedge.net", "azurewebsites.net", "msecnd.net", "facebook.net", "fbcdn.net", "twimg.com",
}


def socks_port() -> int | None:
    try:
        port = int(vpnconf.load_connection().get("local_socks_port", 1080))
    except Exception:  # noqa: BLE001 - no config yet: just go direct
        return None
    with socket.socket() as s:
        s.settimeout(0.5)
        return port if s.connect_ex(("127.0.0.1", port)) == 0 else None


def fetch(url: str, socks: int | None) -> str | None:
    cmd = ["curl", "-sf", "--max-time", "20", url]
    if socks:
        cmd[1:1] = ["--socks5-hostname", f"127.0.0.1:{socks}"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def base_domain(host: str) -> str:
    parts = host.lower().strip(".").split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in MULTI_SUFFIX:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


# --- source 1: the community list --------------------------------------------


def site_host(site: str) -> str:
    host = vpnconf.host_of(site)
    return host[4:] if host.startswith("www.") else host


def geosite_names(site: str) -> list[str]:
    """List names to try. youtube / youtube.com → youtube. A subdomain such as
    meet.google.com → only google-meet: never the parent's list, which would be
    all of Google (534 domains), not Meet."""
    host = site_host(site)
    if "." not in host:
        return [host]
    base = base_domain(host)
    company = base.split(".")[0]
    if host == base:
        return [company]
    return [f"{company}-{host[: -len(base) - 1].split('.')[-1]}"]


def own_keyword(site: str) -> str | None:
    """For a site on a shared domain (meet.google.com), the word its own hosts carry."""
    host = site_host(site)
    base = base_domain(host) if "." in host else host
    return host[: -len(base) - 1].split(".")[-1] if host != base and base in SHARED else None


def geosite(name: str, socks: int | None, depth: int = 0, seen: set | None = None) -> dict | None:
    """{'domains': [...], 'country': n, 'skipped': [...], 'name': name} or None if no such list."""
    seen = seen if seen is not None else set()
    if name in seen or depth > 2:
        return {"domains": [], "country": 0, "skipped": []}
    seen.add(name)
    text = fetch(GEOSITE.format(name=name), socks)
    if text is None:
        return None
    domains, skipped, country = [], [], 0
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        attrs = re.findall(r"@(\S+)", line)
        value = re.sub(r"\s*@\S+", "", line).strip()
        if "ads" in attrs or "cn" in attrs:
            continue  # ad servers and China-only mirrors
        kind, _, rest = value.partition(":")
        if not rest:
            kind, rest = "domain", value
        if kind == "include":
            sub = geosite(rest, socks, depth + 1, seen)
            if sub:
                domains += sub["domains"]
                country += sub["country"]
                skipped += sub["skipped"]
            continue
        if kind in ("regexp", "keyword"):
            skipped.append(f"{kind}:{rest}")
            continue
        d = rest.lower()
        # youtube.de, youtube.co.uk, … — the same site per country; rarely needed.
        if re.match(rf"^{re.escape(name)}\.([a-z]{{2}}|(co|com)\.[a-z]{{2}})$", d):
            country += 1
            continue
        if "." not in d:
            d = "*." + d  # a bare TLD line, e.g. "youtube" = every .youtube domain
        domains.append(d)
    out = []
    for d in domains:
        if d not in out:
            out.append(d)
    return {"domains": out, "country": country, "skipped": skipped, "name": name}


# --- source 2: load it in Chrome -----------------------------------------------


def live_hosts(url: str, socks: int | None, seconds: int) -> list[str] | None:
    if not Path(CHROME).exists():
        return None
    tmp = Path(tempfile.mkdtemp(prefix="vpn-domains-"))
    netlog = tmp / "net.json"
    args = [
        CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
        f"--user-data-dir={tmp / 'profile'}", f"--log-net-log={netlog}",
        # keep Chrome's own background traffic (updates, safe browsing…) out of the list
        "--disable-background-networking", "--disable-component-update", "--disable-sync",
        "--disable-domain-reliability", "--disable-client-side-phishing-detection", "--no-pings",
        "--disable-features=OptimizationHints,Translate,MediaRouter,AutofillServerCommunication",
        "--mute-audio", "--window-size=1366,900",
        f"--virtual-time-budget={seconds * 1000}", "--dump-dom", url,
    ]
    if socks:
        args.insert(1, f"--proxy-server=socks5://127.0.0.1:{socks}")
    try:
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=seconds + 40)
    except subprocess.TimeoutExpired:
        pass
    text = netlog.read_text(errors="ignore") if netlog.exists() else ""
    shutil.rmtree(tmp, ignore_errors=True)
    hosts = set(re.findall(r'"(?:https?|wss?)://([a-z0-9.-]+\.[a-z]{2,})[:/"]', text, re.I))
    hosts |= set(re.findall(r'"host":"([a-z0-9.-]+\.[a-z]{2,})(?::\d+)?"', text, re.I))
    return sorted(h.lower() for h in hosts)


# --- output -------------------------------------------------------------------


def route_now(data: dict | None, host: str, cisco_up: bool) -> str:
    if data is None:
        return ""
    rule, _ = vpnconf.match(data, host.lstrip("*."))
    return f'{vpnconf.effective(rule, cisco_up)} (rule "{rule["name"]}")' if rule else "vpn (not listed)"


def route_value(data: dict | None, host: str, cisco_up: bool) -> str:
    rule, _ = vpnconf.match(data, host.lstrip("*.")) if data is not None else (None, "")
    return vpnconf.effective(rule, cisco_up) if rule else "vpn"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="vpn domains", description="Find the domains a site uses.")
    p.add_argument("site", help="youtube, youtube.com or https://www.youtube.com/...")
    p.add_argument("--add", choices=vpnconf.ROUTE_NAMES, help="add the suggested domains with this route")
    p.add_argument("--name", help="rule name for --add (default: the site's name)")
    p.add_argument("--all", action="store_true", help="--add also the live-only and shared hosts")
    p.add_argument("--quick", action="store_true", help="skip loading the site in Chrome")
    p.add_argument("--seconds", type=int, default=15, help="how long Chrome lets the page run (default 15)")
    p.add_argument("--json", action="store_true", help="output the report as JSON")
    p.add_argument("--cisco", action="store_true", help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    if a.json and a.add:
        p.error("--json cannot be used with --add")

    socks = socks_port()
    via = f"through the VPN (127.0.0.1:{socks})" if socks else "directly (VPN is off)"
    try:
        data = vpnconf.load_routes()
    except vpnconf.ConfigError:
        data = None
    title = a.name or geosite_names(a.site)[0].replace("-", " ").title()
    if data is not None:  # reuse an existing rule's spelling (YouTube, not Youtube)
        same = [r["name"] for r in data["rules"] if r["name"].lower() == title.lower()]
        title = same[0] if same else title

    # 1) the community list
    listed = None
    for name in geosite_names(a.site):
        listed = geosite(name, socks)
        if listed is not None:
            break
    if not a.json:
        print(f"\n{title} — {via}\n")
        if listed:
            print(f"  From the community list (v2fly geosite: {listed['name']}), {len(listed['domains'])} domains:")
            for d in listed["domains"]:
                print(f"    {d:<40} now → {route_now(data, d, a.cisco)}")
            if listed["country"]:
                print(f"    (+ {listed['country']} per-country copies like {listed['name']}.de — left out)")
            if listed["skipped"]:
                print(f"    (+ {len(listed['skipped'])} pattern rules macOS can't use — left out)")
        else:
            print(f"  The community list has no entry for {', '.join(geosite_names(a.site))}.")

    # 2) live
    live_by_base: dict[str, list[str]] = defaultdict(list)
    live = None
    if not a.quick:
        host = vpnconf.host_of(a.site)
        url = a.site if "://" in a.site else f"https://{host if '.' in host else 'www.' + host + '.com'}"
        if not a.json:
            print(f"\n  Loading {url} in headless Chrome ({a.seconds}s)…", flush=True)
        live = live_hosts(url, socks, a.seconds)
        for h in live or []:
            live_by_base[base_domain(h)].append(h)
        if not a.json:
            if live is None:
                print("    Chrome not found — skipped")
            elif not live:
                print("    nothing recorded (the page didn't load?)")
            else:
                listed_names = {d.lstrip("*.") for d in (listed["domains"] if listed else [])}
                print(f"    {len(live)} hosts on {len(live_by_base)} domains:")
                for base in sorted(live_by_base, key=lambda b: (b in SHARED, -len(live_by_base[b]), b)):
                    tag = "  [shared]" if base in SHARED else ("  [in list]" if base in listed_names else "")
                    sample = ", ".join(live_by_base[base][:3]) + (" …" if len(live_by_base[base]) > 3 else "")
                    print(f"    {base:<26} {len(live_by_base[base]):>2} host(s){tag:<12} now → {route_now(data, base, a.cisco)}")
                    print(f"        {sample}")

    # what to add
    suggested: list[str] = list(listed["domains"]) if listed else []
    keyword = own_keyword(a.site)
    if keyword and not a.all:
        # The site sits on shared infrastructure: suggest only what is its own.
        host = site_host(a.site)
        suggested = [host] + [
            h for hosts in live_by_base.values() for h in hosts
            if keyword in h.split(".")[0] and h != host and not h.endswith("." + host)
        ]
        if not a.json:
            print(f"\n  {host} lives on {base_domain(host)}, which many Google/other services share:"
                  f" suggesting only {host} and hosts named after '{keyword}'.")
    elif not suggested or a.all:
        for base, hosts in live_by_base.items():
            if base in SHARED:
                if a.all:
                    suggested += [h for h in hosts if h not in suggested]
            elif base not in suggested and f"*.{base}" not in suggested:
                suggested.append(base)
    if a.json:
        print(json.dumps({
            "site": a.site, "title": title, "via": "vpn" if socks else "direct",
            "listed": {
                "name": listed["name"],
                "domains": [{"domain": d, "route": route_value(data, d, a.cisco)} for d in listed["domains"]],
            } if listed else None,
            "live": [{"host": h, "route": route_value(data, h, a.cisco)} for h in live] if live is not None else None,
            "suggested": suggested,
        }, ensure_ascii=False))
        return 0
    if not suggested:
        print("\n  Nothing to suggest.")
        return 0
    print("\n  Suggested (paste into a rule's \"domains\" in routes.json):")
    print("    " + vpnconf._dump(suggested).replace("\n", "\n    "))
    if not a.add:
        print(f"\n  Add them:  vpn domains {a.site} --add vpn|cisco|direct   (rule \"{title}\"; --name to change)")
        if listed and live_by_base:
            print("             --all also adds what Chrome saw beyond the list, shared hosts included")
        return 0

    if data is None:
        print("\n  routes.json has errors — fix it first (vpn config)", file=sys.stderr)
        return 1
    added = vpnconf.add_to_rule(data, title, a.add, suggested)
    errors = vpnconf.check_routes(data)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    vpnconf._write(vpnconf.ROUTES, vpnconf._with_guide(data, "routes.schema.json", vpnconf.ROUTES_GUIDE))
    rule = next(r for r in data["rules"] if r["name"].lower() == title.lower())
    title = rule["name"]
    note = "" if rule["route"] == a.add else f' (the rule\'s route is "{rule["route"]}"; change it in the file if needed)'
    print(f'\n  Added {len(added)} to rule "{title}" → {rule["route"]}{note}')
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
