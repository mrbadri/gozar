"""Reads, checks and edits laptop-vpn's two config files. Called by laptop-vpn.sh.

    routes.json      which site goes through the VPN, Cisco, or straight out
    connection.json  how the tunnel connects

Both live in ~/.config/laptop-vpn/ and are created from the *.default.json
next to this file on first use. Each carries a "_guide" — how to write it, in
Persian — that this module owns and refreshes; everything else is the user's.
Stdlib only (macOS's /usr/bin/python3 is 3.9).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = Path(os.environ.get("LAPTOP_VPN_STATE") or Path.home() / ".config" / "laptop-vpn")
ROUTES = STATE / "routes.json"
CONNECTION = STATE / "connection.json"
OLD_DIRECT = STATE / "direct.txt"  # the plain list routes.json replaced

ROUTE_NAMES = ("vpn", "cisco", "direct")
CLI_RULE = "Added with vpn set ({route})"
ROUTER_DEFAULTS = {"enabled": False, "upstream_port": 1081, "control_port": 1090}

# Always kept off the VPN, whatever the file says: the machine itself and the LAN.
FIXED_DIRECT = [
    "127.0.0.1", "localhost", "*.local", "169.254.0.0/16", "10.0.0.0/8",
    "172.16.0.0/12", "192.168.0.0/16", "<local>",
]

LABEL = r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
NAME_RE = re.compile(rf"^{LABEL}(?:\.{LABEL})*$")
HOST_RE = re.compile(r"^[A-Za-z0-9.*/:_-]+$")

ROUTES_GUIDE = [
    "راهنما — این بخش رو vpn خودش به‌روز نگه می‌داره؛ دست نزن. قانون‌های خودت توی rules.",
    "هر سایتی که اینجا نیست از VPN می‌ره. پس معمولاً فقط چیزهایی رو می‌نویسی که نباید از VPN برن.",
    "",
    "هر قانون: { \"name\": اسم دلخواه, \"route\": راه, \"domains\": [...] و/یا \"hosts\": [...] }",
    "route:  vpn = از VPN ِ ما  ·  cisco = از Cisco وقتی وصله  ·  direct = هیچ‌وقت از VPN ِ ما نه",
    "without_cisco: فقط برای cisco — وقتی Cisco وصل نیست: \"direct\" (پیش‌فرض) یا \"vpn\"",
    "enabled: false → قانون موقتاً خاموش، بدون پاک کردن",
    "note: هر توضیحی برای خودت (JSON کامنت // نداره)",
    "",
    "domains — شکل نوشتن:",
    "  \"youtube.com\"      خود youtube.com و همهٔ زیردامنه‌هاش (www.youtube.com، m.youtube.com، …)",
    "  \"*.company.example\"   فقط زیردامنه‌ها (api.company.example، …)، نه خود company.example",
    "  \"*.ir\"  یا  \"ir\"     همهٔ دامنه‌های .ir",
    "  آدرس کامل هم قبوله و خودش تمیزش می‌کنه: \"https://www.youtube.com/watch?v=x\" ← youtube.com",
    "hosts — اسم دقیق، بدون زیردامنه: \"corp-mgmt01\" · \"192.168.1.5\" · \"10.0.0.0/8\"",
    "",
    "اگه یه سایت با چند قانون جور شد: hosts به domains می‌چربه، و بین domains دقیق‌ترین (طولانی‌ترین).",
    "دامنه‌های یه سایت رو پیدا کن:  vpn domains youtube   (و با --add vpn اضافه‌شون کن)",
    "بعد از ذخیره:  vpn apply   ·   یا ویرایش با  vpn config  که خودش چک و اعمال می‌کنه",
]

CONNECTION_GUIDE = [
    "راهنما — این بخش رو vpn خودش به‌روز نگه می‌داره؛ دست نزن.",
    "relay: سرور ایران (relay) که تونل بهش وصل می‌شه — host، port (phone_vpn_relay_port)، user (phone_vpn_user)",
    "رمز اینجا نیست: توی Keychain ِ مکه (سرویس vpnuser-relay). پاک کردنش: vpn forget",
    "local_socks_port: proxy ِ محلی کجا گوش بده (پیش‌فرض 1080)",
    "keepalive: هر interval_seconds چک می‌کنه؛ max_missed بار بی‌جواب = قطع و وصل دوباره",
    "بعد از ذخیره:  vpn apply  — اگه وصلی، یه بار قطع و وصل می‌شه",
]


class ConfigError(Exception):
    pass


class ConfigArguments(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ConfigError(message)


# --- writing: compact, readable JSON ------------------------------------------


def _dump(value, indent: int = 0) -> str:
    """JSON with one key per line but short string lists kept on one (wrapped) line."""
    pad = "  " * indent
    inner = "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [f"{inner}{json.dumps(k, ensure_ascii=False)}: {_dump(v, indent + 1)}" for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        strings = all(isinstance(x, str) for x in value)
        if strings and any(len(x) > 60 for x in value):  # prose (the guide): one per line
            return "[\n" + ",\n".join(inner + json.dumps(x, ensure_ascii=False) for x in value) + "\n" + pad + "]"
        if strings:
            parts = [json.dumps(x, ensure_ascii=False) for x in value]
            lines, line = [], ""
            for p in parts:
                if line and len(inner) + len(line) + len(p) + 2 > 100:
                    lines.append(line + ",")
                    line = p
                else:
                    line = f"{line}, {p}" if line else p
            lines.append(line)
            if len(lines) == 1 and len(pad) + len(lines[0]) < 90:
                return "[" + lines[0] + "]"
            return "[\n" + "\n".join(inner + x for x in lines) + "\n" + pad + "]"
        return "[\n" + ",\n".join(inner + _dump(x, indent + 1) for x in value) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


def _write(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(_dump(data) + "\n")
    tmp.replace(path)


def _with_guide(data: dict, schema: str, guide: list[str]) -> dict:
    """$schema and _guide first, the user's keys after, in their order."""
    out = {"$schema": (HERE / schema).as_uri(), "_guide": guide}
    out.update({k: v for k, v in data.items() if k not in ("$schema", "_guide")})
    return out


# --- files -------------------------------------------------------------------


def init() -> list[str]:
    """Create missing files, fold an old direct.txt in, keep _guide current."""
    STATE.mkdir(parents=True, exist_ok=True)
    notes = []
    if not CONNECTION.exists():
        data = json.loads((HERE / "connection.default.json").read_text())
        _write(CONNECTION, _with_guide(data, "connection.schema.json", CONNECTION_GUIDE))
        notes.append(f"created {CONNECTION}")
    if not ROUTES.exists():
        routes = json.loads((HERE / "routes.default.json").read_text())
        if OLD_DIRECT.exists():
            known = {d for r in routes["rules"] for d in r.get("domains", [])}
            extra = [d for d in _read_old_direct() if d not in known]
            if extra:
                routes["rules"].append({"name": "From direct.txt", "route": "direct", "domains": extra})
                notes.append(f"moved {len(extra)} extra site(s) from direct.txt into routes.json")
            OLD_DIRECT.rename(OLD_DIRECT.with_suffix(".txt.old"))
        _write(ROUTES, _with_guide(routes, "routes.schema.json", ROUTES_GUIDE))
        notes.append(f"created {ROUTES}")
    for path, schema, guide in (
        (ROUTES, "routes.schema.json", ROUTES_GUIDE),
        (CONNECTION, "connection.schema.json", CONNECTION_GUIDE),
    ):
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue  # validate reports it; don't touch a file the user is mid-way through
        if isinstance(data, dict) and (data.get("_guide") != guide or data.get("$schema") != (HERE / schema).as_uri()):
            _write(path, _with_guide(data, schema, guide))
    return notes


def _read_old_direct() -> list[str]:
    out = []
    for line in OLD_DIRECT.read_text().splitlines():
        d = line.split("#", 1)[0].strip().lower()
        d = d[2:] if d.startswith("*.") else d
        if d and d not in out:
            out.append(d)
    return out


def _load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise ConfigError(
            f"{path}: line {e.lineno}, column {e.colno}: {e.msg}\n"
            "  (JSON: double quotes only, no comma after the last item, no // comments — use \"note\")"
        ) from None


# --- addresses ----------------------------------------------------------------


def parse_domain(raw: str) -> tuple[str, str]:
    """A domains entry → (kind, name). kind "tree" = name and its subdomains,
    "sub" = only its subdomains. Accepts URLs. Raises ConfigError with a hint."""
    if not isinstance(raw, str) or not raw.strip():
        raise ConfigError(f"empty domain {raw!r}")
    s = raw.strip().lower()
    url = "://" in s or "/" in s or "?" in s
    if url:
        s = s.split("://", 1)[-1].split("/", 1)[0].split("?", 1)[0]
        s = s.rsplit("@", 1)[-1].split(":", 1)[0]
        s = s[4:] if s.startswith("www.") else s
    kind = "tree"
    if s.startswith("*."):
        kind, s = "sub", s[2:]
    elif s.startswith("."):
        kind, s = "sub", s[1:]
    s = s.rstrip(".")
    if not NAME_RE.match(s):
        hint = ""
        if " " in s:
            hint = " (no spaces)"
        elif "*" in s:
            hint = ' (a "*" only works at the start: "*.example.com")'
        elif "_" in s:
            hint = " (domains can't have _; for a machine name use \"hosts\")"
        raise ConfigError(f"bad domain {raw!r}{hint}")
    if "." not in s:
        kind = "sub"  # a TLD: "ir" = every .ir domain
    return kind, s


def domain_label(kind: str, name: str) -> str:
    return f"*.{name}" if kind == "sub" else name


def _rules(data: dict, include_disabled: bool = False) -> list[dict]:
    return [r for r in data["rules"] if include_disabled or r.get("enabled", True) is not False]


# --- routes ------------------------------------------------------------------


def load_routes() -> dict:
    data = _load(ROUTES)
    errors = check_routes(data)
    if errors:
        raise ConfigError("\n".join(f"{ROUTES}: {e}" for e in errors))
    return data


def check_routes(data: dict) -> list[str]:
    errors = []
    if not isinstance(data, dict) or not isinstance(data.get("rules"), list):
        return ['needs a top-level "rules": [ … ] list']
    for key in data:
        if key not in ("$schema", "_guide", "rules"):
            errors.append(f'unknown top-level key "{key}" (only "rules"; your notes go in a rule\'s "note")')
    allowed = {"name", "route", "without_cisco", "enabled", "note", "domains", "hosts"}
    for i, rule in enumerate(data["rules"], 1):
        if not isinstance(rule, dict):
            errors.append(f"rule {i}: must be an object {{ … }}")
            continue
        where = f"rule {i} ({rule.get('name', 'no name')})"
        for key in rule:
            if key not in allowed:
                close = [a for a in allowed if a[:3] == key[:3].lower()]
                hint = f' — did you mean "{close[0]}"?' if close else f' (allowed: {", ".join(sorted(allowed))})'
                errors.append(f'{where}: unknown key "{key}"{hint}')
        if not isinstance(rule.get("name"), str) or not rule["name"].strip():
            errors.append(f'{where}: needs a "name"')
        if "note" in rule and not isinstance(rule["note"], str):
            errors.append(f'{where}: "note" must be text in quotes')
        if rule.get("route") not in ROUTE_NAMES:
            errors.append(f'{where}: "route" must be "vpn", "cisco" or "direct", not {json.dumps(rule.get("route"))}')
        if "without_cisco" in rule:
            if rule.get("route") != "cisco":
                errors.append(f'{where}: "without_cisco" only means something with "route": "cisco"')
            elif rule["without_cisco"] not in ("vpn", "direct"):
                errors.append(f'{where}: "without_cisco" must be "vpn" or "direct"')
        if "enabled" in rule and not isinstance(rule["enabled"], bool):
            errors.append(f'{where}: "enabled" must be true or false (no quotes)')
        for key in ("domains", "hosts"):
            if key in rule and not isinstance(rule[key], list):
                errors.append(f'{where}: "{key}" must be a list: ["a.com", "b.com"]')
        if not rule.get("domains") and not rule.get("hosts"):
            errors.append(f'{where}: needs "domains" or "hosts" (a list)')
        for d in rule.get("domains", []) if isinstance(rule.get("domains"), list) else []:
            try:
                parse_domain(d)
            except ConfigError as e:
                errors.append(f"{where}: {e}")
        for h in rule.get("hosts", []) if isinstance(rule.get("hosts"), list) else []:
            if not isinstance(h, str) or not HOST_RE.match(h):
                errors.append(f"{where}: bad host {h!r}")
    return errors


def notes(data: dict) -> list[str]:
    """Allowed, but worth saying: cleaned-up URLs, duplicates, unreachable vpn rules."""
    out = []
    for rule in _rules(data):
        for d in rule.get("domains", []):
            kind, name = parse_domain(d)
            if domain_label(kind, name) != d.strip().lower() and d.strip().lower() not in (name, "." + name):
                out.append(f'"{d}" read as "{domain_label(kind, name)}" (rule "{rule["name"]}")')
    seen: dict[str, str] = {}
    for rule in _rules(data):
        for d in [domain_label(*parse_domain(x)) for x in rule.get("domains", [])] + rule.get("hosts", []):
            if d.lower() in seen and seen[d.lower()] != rule["name"]:
                out.append(f'{d} is in both "{seen[d.lower()]}" and "{rule["name"]}"')
            seen.setdefault(d.lower(), rule["name"])
    # macOS's proxy list can only say "not through the proxy": a vpn rule for a
    # subdomain of a direct/cisco domain can't win over it.
    off_vpn = [(parse_domain(d)[1], r["name"]) for r in _rules(data) if r["route"] != "vpn" for d in r.get("domains", [])]
    for rule in _rules(data):
        if rule["route"] != "vpn":
            continue
        for d in rule.get("domains", []):
            name = parse_domain(d)[1]
            for parent, pname in off_vpn:
                if name != parent and name.endswith("." + parent):
                    out.append(
                        f'{name} ("{rule["name"]}", vpn) sits under {parent} ("{pname}"): macOS can\'t carve '
                        f"a subdomain back into the VPN, so it goes the way of {parent}"
                    )
    return out


def effective(rule: dict, cisco_up: bool) -> str:
    """Where this rule's sites go right now: vpn, cisco or direct."""
    if rule["route"] == "cisco" and not cisco_up:
        return rule.get("without_cisco", "direct")
    if rule["route"] == "direct" and cisco_up:
        return "cisco"  # Cisco carries all traffic while it's connected
    return rule["route"]


def bypass(data: dict, cisco_up: bool) -> list[str]:
    """The macOS proxy exception list: everything that must not use the VPN."""
    out = list(FIXED_DIRECT)
    for rule in _rules(data):
        if effective(rule, cisco_up) == "vpn":
            continue
        for d in rule.get("domains", []):
            kind, name = parse_domain(d)
            if kind == "tree":
                out.append(name)
            out.append("*." + name)
        out.extend(rule.get("hosts", []))
    seen = set()
    return [x for x in out if not (x in seen or seen.add(x))]


def match(data: dict, host: str) -> tuple[dict | None, str]:
    """The rule a host falls under: exact host first, then the most specific domain."""
    host = host.lower()
    for rule in _rules(data):
        for h in rule.get("hosts", []):
            if h.lower() == host or (h.startswith("*.") and host.endswith(h[1:].lower())):
                return rule, h
    best: tuple[dict | None, str] = (None, "")
    best_len = -1
    for rule in _rules(data):
        for d in rule.get("domains", []):
            kind, name = parse_domain(d)
            hit = host.endswith("." + name) or (kind == "tree" and host == name)
            if hit and len(name) > best_len:
                best, best_len = (rule, domain_label(kind, name)), len(name)
    return best


def host_of(site: str) -> str:
    s = site.strip().lower().split("://", 1)[-1]
    return s.split("/", 1)[0].split("?", 1)[0].rsplit("@", 1)[-1].split(":", 1)[0]


def cmd_check(site: str, cisco_up: bool, as_json: bool = False) -> None:
    data = load_routes()
    host = host_of(site)
    rule, pattern = match(data, host)
    now = effective(rule, cisco_up) if rule else "vpn"
    if as_json:
        print(json.dumps({
            "host": host, "route": now, "rule": rule["name"] if rule else None,
            "pattern": pattern or None, "rule_route": rule["route"] if rule else None, "cisco": cisco_up,
        }, ensure_ascii=False))
        return
    if rule is None:
        print(f"{host} → vpn (not listed: everything else goes through the VPN)")
        return
    extra = ""
    if rule["route"] != now:
        extra = f"  [rule says {rule['route']}; Cisco is {'connected' if cisco_up else 'not connected'}]"
    print(f'{host} → {now}  (rule "{rule["name"]}", matches {pattern}){extra}')


def cmd_routes(cisco_up: bool, as_json: bool = False) -> None:
    data = load_routes()
    if as_json:
        rules = [{
            "name": rule["name"], "route": rule["route"], "without_cisco": rule.get("without_cisco"),
            "enabled": rule.get("enabled", True), "note": rule.get("note"),
            "domains": rule.get("domains", []), "hosts": rule.get("hosts", []),
            "effective": effective(rule, cisco_up) if rule.get("enabled", True) else "off",
        } for rule in data["rules"]]
        print(json.dumps({"path": str(ROUTES), "cisco": cisco_up, "rules": rules}, ensure_ascii=False))
        return
    print(f"{ROUTES}")
    print(f"Cisco: {'connected' if cisco_up else 'not connected'} · anything not listed → vpn\n")
    for rule in data["rules"]:
        if rule.get("enabled", True) is False:
            print(f"  {rule['name']}: off (enabled: false)")
            continue
        now = effective(rule, cisco_up)
        how = rule["route"]
        if rule["route"] == "cisco":
            how += f" (without Cisco: {rule.get('without_cisco', 'direct')})"
        print(f"  {rule['name']}: {how} → now {now}")
        items = [domain_label(*parse_domain(d)) for d in rule.get("domains", [])] + rule.get("hosts", [])
        print("      " + ", ".join(items))
    for n in notes(data):
        print(f"\n  note: {n}")


def add_to_rule(data: dict, name: str, route: str, entries: list[str]) -> list[str]:
    """Move entries into rule `name` (created with `route` if missing). Returns what was added."""
    added = []
    for raw in entries:
        if "." in raw.lstrip("*.") or raw.startswith("*."):
            kind, value = parse_domain(raw)
            key, entry = "domains", domain_label(kind, value)
        else:
            if not HOST_RE.match(raw):
                raise ConfigError(f"bad site {raw!r}")
            key, entry = "hosts", raw  # a name without a dot is one machine (corp-mgmt01)
        for rule in data["rules"]:
            for k in ("domains", "hosts"):
                if k in rule:
                    rule[k] = [x for x in rule[k] if _same(x, entry) is False]
        rule = next((r for r in data["rules"] if r["name"].lower() == name.lower()), None)
        if rule is None:
            rule = {"name": name, "route": route}
            data["rules"].append(rule)
        rule.setdefault(key, []).append(entry)
        added.append(entry)
    data["rules"] = [r for r in data["rules"] if r.get("domains") or r.get("hosts")]
    return added


def _same(a: str, b: str) -> bool:
    try:
        return domain_label(*parse_domain(a)) == domain_label(*parse_domain(b))
    except ConfigError:
        return a.lower() == b.lower()


def cmd_set(sites: list[str], route: str) -> None:
    if route not in ROUTE_NAMES and route != "none":
        raise ConfigError("route must be vpn, cisco or direct")
    data = load_routes()
    for raw in sites:
        entry = raw.strip()
        if "://" in entry or "/" in entry:
            entry = host_of(entry)
            entry = entry[4:] if entry.startswith("www.") else entry
        was = [r["name"] for r in data["rules"] for x in r.get("domains", []) + r.get("hosts", []) if _same(x, entry)]
        if route == "none":
            for rule in data["rules"]:
                for k in ("domains", "hosts"):
                    if k in rule:
                        rule[k] = [x for x in rule[k] if not _same(x, entry)]
            data["rules"] = [r for r in data["rules"] if r.get("domains") or r.get("hosts")]
            print(f"{entry}: removed from {', '.join(was)} → vpn" if was else f"{entry}: wasn't listed")
            continue
        added = add_to_rule(data, CLI_RULE.format(route=route), route, [entry])
        print(f"{added[0]} → {route}" + (f" (was in {', '.join(was)})" if was else ""))
    save_routes(data)


def save_routes(data: dict) -> None:
    errors = check_routes(data)
    if errors:
        raise ConfigError("\n".join(errors))
    _write(ROUTES, _with_guide(data, "routes.schema.json", ROUTES_GUIDE))


def cmd_edit_rule(cmd: str, args: list[str]) -> None:
    parser = ConfigArguments(prog=cmd, allow_abbrev=False)
    parser.add_argument("name")
    if cmd == "add-to":
        parser.add_argument("route", choices=ROUTE_NAMES)
        parser.add_argument("sites", nargs="+")
    elif cmd == "rule-set":
        parser.add_argument("--route", choices=ROUTE_NAMES)
        parser.add_argument("--without-cisco", choices=("direct", "vpn", "none"))
        parser.add_argument("--enabled", choices=("true", "false"))
        parser.add_argument("--rename")
        parser.add_argument("--note")
    elif cmd == "rule-move":
        parser.add_argument("--to", type=int, required=True)
    a = parser.parse_args(args)
    data = load_routes()
    rules = data["rules"]
    index = next((i for i, rule in enumerate(rules) if rule["name"].lower() == a.name.lower()), None)
    if cmd == "add-to":
        sites = [host_of(s).removeprefix("www.") if "://" in s else s for s in a.sites]
        added = add_to_rule(data, a.name, a.route, sites)
        rule = next(rule for rule in data["rules"] if rule["name"].lower() == a.name.lower())
        message = f'Added {len(added)} to rule "{rule["name"]}" → {rule["route"]}'
    else:
        if index is None:
            raise ConfigError(f'no rule named "{a.name}"')
        rule = rules[index]
        if cmd == "rule-delete":
            rules.pop(index)
            message = f'Deleted rule "{rule["name"]}"'
        elif cmd == "rule-move":
            if not 0 <= a.to < len(rules):
                raise ConfigError(f"--to must be between 0 and {len(rules) - 1}")
            rules.insert(a.to, rules.pop(index))
            message = f'Moved rule "{rule["name"]}" to index {a.to}'
        else:
            if a.rename is not None:
                if any(i != index and r["name"].lower() == a.rename.lower() for i, r in enumerate(rules)):
                    raise ConfigError(f'rule "{a.rename}" already exists')
                rule["name"] = a.rename
            if a.enabled is not None:
                rule["enabled"] = a.enabled == "true"
            if a.note is not None:
                rule["note"] = a.note
            if a.without_cisco not in (None, "none"):
                rule["without_cisco"] = a.without_cisco
            if a.route is not None:
                rule["route"] = a.route
            if a.without_cisco == "none" or a.route in ("direct", "vpn"):
                rule.pop("without_cisco", None)
            message = f'Updated rule "{rule["name"]}"'
    save_routes(data)
    print(message)


# --- connection ---------------------------------------------------------------


def load_connection(use_default: bool = False) -> dict:
    try:
        data = _load(CONNECTION)
    except FileNotFoundError:
        if not use_default:
            raise ConfigError(f"{CONNECTION}: file not found") from None
        data = _load(HERE / "connection.default.json")
    if not isinstance(data, dict):
        raise ConfigError(f"{CONNECTION}: must be an object")
    errors = []
    relay = data.get("relay")
    if not isinstance(relay, dict):
        errors.append('needs "relay": { "host": …, "port": …, "user": … }')
    else:
        for k, t, what in (("host", str, "text in quotes"), ("port", int, "number without quotes"),
                           ("user", str, "text in quotes")):
            if not isinstance(relay.get(k), t):
                errors.append(f'"relay.{k}" must be a {what}')
    for k in ("connect_timeout_seconds", "reconnect_delay_seconds"):
        if k in data and not isinstance(data[k], int):
            errors.append(f'"{k}" must be a whole number without quotes')
    ka = data.get("keepalive", {})
    if not isinstance(ka, dict):
        errors.append('"keepalive" must be an object')
    else:
        for k in ("interval_seconds", "max_missed"):
            if k in ka and not isinstance(ka[k], int):
                errors.append(f'"keepalive.{k}" must be a whole number without quotes')
    if "ciphers" in data and (not isinstance(data["ciphers"], list) or not data["ciphers"]):
        errors.append('"ciphers" must be a non-empty list')
    router = data.get("router", {})
    if not isinstance(router, dict):
        errors.append('"router" must be an object')
    else:
        errors += [f'unknown key "router.{k}"' for k in router if k not in ROUTER_DEFAULTS]
        settings = {**ROUTER_DEFAULTS, **router}
        if not isinstance(settings["enabled"], bool):
            errors.append('"router.enabled" must be true or false (no quotes)')
        ports = {"local_socks_port": data.get("local_socks_port", 1080),
                 "router.upstream_port": settings["upstream_port"], "router.control_port": settings["control_port"]}
        for name, port in ports.items():
            if type(port) is not int or not 1024 <= port <= 65535:
                errors.append(f'"{name}" must be an integer between 1024 and 65535')
        if all(type(port) is int for port in ports.values()) and len(set(ports.values())) != len(ports):
            errors.append('"local_socks_port", "router.upstream_port" and "router.control_port" must be distinct')
    allowed = {"$schema", "_guide", "relay", "local_socks_port", "keepalive", "connect_timeout_seconds",
               "reconnect_delay_seconds", "ciphers", "router"}
    errors += [f'unknown key "{k}"' for k in data if k not in allowed]
    if errors:
        raise ConfigError("\n".join(f"{CONNECTION}: {e}" for e in errors))
    return data


def cmd_conn_env(use_default: bool = False) -> None:
    """Shell assignments for laptop-vpn.sh to eval."""
    c = load_connection(use_default)
    ka = c.get("keepalive", {})
    router = {**ROUTER_DEFAULTS, **c.get("router", {})}
    values = {
        "HOST": c["relay"]["host"],
        "PORT": c["relay"]["port"],
        "USER_NAME": c["relay"]["user"],
        "SOCKS_PORT": c.get("local_socks_port", 1080),
        "ROUTER_ENABLED": int(router["enabled"]),
        "UPSTREAM_PORT": router["upstream_port"],
        "CONTROL_PORT": router["control_port"],
        "KEEPALIVE_INTERVAL": ka.get("interval_seconds", 5),
        "KEEPALIVE_MISSED": ka.get("max_missed", 3),
        "CONNECT_TIMEOUT": c.get("connect_timeout_seconds", 15),
        "RECONNECT_DELAY": c.get("reconnect_delay_seconds", 3),
        "CIPHERS": ",".join(c.get("ciphers", ["aes128-gcm@openssh.com", "chacha20-poly1305@openssh.com"])),
    }
    for k, v in values.items():
        print(f"{k}={shlex.quote(str(v))}")


# --- entry point --------------------------------------------------------------


def main(argv: list[str]) -> int:
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "init":
            for n in init():
                print(n, file=sys.stderr)
        elif cmd == "validate":
            load_connection()
            for n in notes(load_routes()):
                print(f"note: {n}", file=sys.stderr)
        elif cmd in ("bypass", "check", "routes"):
            parser = ConfigArguments(prog=cmd, allow_abbrev=False)
            parser.add_argument("--cisco", action="store_true")
            if cmd == "bypass":
                parser.add_argument("--router", action="store_true")
                a = parser.parse_args(args)
                print("\n".join(FIXED_DIRECT if a.router else bypass(load_routes(), a.cisco)))
            else:
                parser.add_argument("--json", action="store_true")
                if cmd == "check":
                    parser.add_argument("site")
                    a = parser.parse_args(args)
                    cmd_check(a.site, a.cisco, a.json)
                else:
                    a = parser.parse_args(args)
                    cmd_routes(a.cisco, a.json)
        elif cmd == "set":
            cmd_set(args[:-1], args[-1])
        elif cmd == "unset":
            cmd_set(args, "none")
        elif cmd in ("add-to", "rule-set", "rule-delete", "rule-move"):
            cmd_edit_rule(cmd, args)
        elif cmd == "sites":  # for tab completion; quiet if the file is broken
            for rule in load_routes()["rules"]:
                for d in rule.get("domains", []):
                    print(domain_label(*parse_domain(d)))
                for h in rule.get("hosts", []):
                    print(h)
        elif cmd == "conn-env":
            cmd_conn_env("--defaults" in args)
        else:
            print(f"vpnconf: unknown command {cmd}", file=sys.stderr)
            return 2
    except ConfigError as e:
        print(f"config error:\n{e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
