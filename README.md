# گذر (Gozar)

اپ مک برای عبور دادن اینترنت از سرور خودت. یک VPN شخصی است که هم از دستور `vpn` در ترمینال کنترل می‌شود و هم از یک اپ SwiftUI فارسی.

- **مسیریابی برای هر سایت.** برای هر دامنه تعیین می‌کنی از کدام راه برود: `vpn` (تونل گذر)، `direct` (اینترنت خود مک) یا `cisco` (VPN ِ شرکت، وقتی وصل است).
- **سرورهای خروج.** SSH (با `ssh -D`)، و V2Ray با لینک VLESS، VMess، Trojan و Shadowsocks، لینک اشتراک (subscription) یا QR. Xray همراه اپ است.
- **دیدن زنده.** هر درخواست با مسیر، حجم، سرعت و زمان اتصال، پرمصرف‌ترین دامنه‌ها، و تأخیر هر حلقه از مک تا اینترنت.
- **مانیتورینگ اختیاری سرور** از Grafana (اگر سرورت متریک‌های این پروژه را دارد).
- **خودکفا.** Python، Xcode یا ابزار دیگری لازم نیست. بار اول یک راه‌اندازی ۵ مرحله‌ای باز می‌شود.

macOS 14 به بالا، Apple Silicon و Intel.

---

## فهرست

1. [نصب سریع (فقط اپ)](#نصب-سریع)
2. [ساختن از سورس](#ساختن-از-سورس)
3. [چطور کار می‌کند](#چطور-کار-میکند)
4. [ساختار repo](#ساختار-repo)
5. [فایل‌های تنظیمات و وضعیت](#فایلهای-تنظیمات-و-وضعیت)
6. [توسعه: اجرا، تست، اسکرین‌شات](#توسعه)
7. [چطور تغییرش بدهم](#چطور-تغییرش-بدهم)
8. [Grafana](#grafana)
9. [امنیت و حریم خصوصی](#امنیت-و-حریم-خصوصی)

راهنمای کامل دستور `vpn`: [`docs/LAPTOP-VPN.md`](docs/LAPTOP-VPN.md).

---

## نصب سریع

اگر `Gozar.app` ِ ساخته‌شده را داری:

1. آن را در `~/Applications` یا `/Applications` بگذار.
2. بار اول **راست‌کلیک ← Open** بزن. اپ امضای Developer ID ندارد و macOS بار اول می‌پرسد.
3. راه‌اندازی باز می‌شود: لینک سرور، لینک اشتراک یا QR را وارد کن (یا اطلاعات SSH)، آزمایش کن و «وصل شو» را بزن.

اگر macOS برای Keychain پرسید، «Always Allow» را بزن.

## ساختن از سورس

پیش‌نیاز: فقط **Command Line Tools** ِ مک (`xcode-select --install`). Xcode لازم نیست. Swift 6.1 به بالا.

```bash
git clone https://github.com/mrbadri/gozar.git
cd gozar
scripts/install.sh        # build + ساخت Gozar.app + نصب در ~/Applications
open ~/Applications/Gozar.app
```

`install.sh`:
- `scripts/build-app.sh` را اجرا می‌کند. این اسکریپت دو معماری را می‌سازد و Xray را از GitHub دانلود و با checksum ِ `Resources/xray.lock` چک می‌کند (`scripts/fetch-xray.sh`). خروجی `build/Gozar.app` است، universal و با امضای ad-hoc.
- اپ را در `~/Applications/Gozar.app` کپی می‌کند.
- `~/.local/bin/vpn-router` را به مسیریاب ِ داخل اپ لینک می‌کند.
- به `~/.local/bin/vpn` دست نمی‌زند. نصب دستور ترمینال اختیاری است (از راه‌اندازی ِ اپ، یا دستی):

```bash
ln -sf "$PWD/cli/laptop-vpn.sh" ~/.local/bin/vpn
vpn help
```

فقط ساختن، بدون نصب:

```bash
swift build -c release      # .build/release/{Gozar,vpn-router,gozarctl}
scripts/build-app.sh        # build/Gozar.app
```

## چطور کار میکند

```
 مرورگر و اپ‌ها
      │  (proxy ِ SOCKS ِ سیستم → 127.0.0.1:1080)
      ▼
 vpn-router  ── تصمیم برای هر اتصال با routes.json ──┐
      │ vpn                                          │ direct / cisco
      ▼                                              ▼
 upstream ِ SOCKS روی 127.0.0.1:1081            مستقیم از مک
   ├─ ssh -D   → سرور SSH ← اینترنت             (اگر Cisco وصل است، از Cisco)
   └─ xray     → سرور V2Ray ← اینترنت
      ▲
 کنترل و آمار: API ِ محلی روی 127.0.0.1:1090 (با توکن) ← Gozar.app
```

چهار بخش:

| بخش | زبان | کار |
|---|---|---|
| `cli/laptop-vpn.sh` (دستور `vpn`) | bash | روشن و خاموش، حلقهٔ اتصال دوباره برای ssh یا xray، proxy ِ سیستم (`networksetup`)، نسخهٔ proxy ِ Cisco (`scutil`)، و پیدا کردن رمز از Keychain |
| `gozarctl` | Swift | خواندن، چک و ویرایش فایل‌های تنظیمات، سرورها و اشتراک‌ها، تبدیل لینک به تنظیمات Xray، آزمایش سرور. خروجی‌اش دقیقاً مثل `cli/laptop-vpn.d/vpnconf.py` است، که فقط مرجع تست‌هاست. |
| `vpn-router` | Swift (Network.framework) | proxy ِ SOCKS4/4a/5 روی 1080: مسیریابی هر اتصال، شمردن بایت‌ها و زمان‌ها، probeها، و API ِ کنترل با رویدادهای زنده (SSE) |
| `Gozar.app` | SwiftUI | رابط کاربری. هیچ منطقی را دوباره نمی‌سازد: کارها را با `vpn` و `gozarctl` انجام می‌دهد و آمار را از `vpn-router` و Grafana می‌گیرد. |

**دو حالت:**
- **حالت مسیریاب** (`router.enabled: true`، پیشنهادی): `vpn-router` روی 1080 است و ssh یا xray روی 1081. همهٔ درخواست‌ها در اپ دیده می‌شوند.
- **حالت کلاسیک**: ssh یا xray مستقیم روی 1080 است و سایت‌های `direct` با فهرست استثنای proxy ِ macOS رد می‌شوند. اپ کار می‌کند، ولی صفحه‌های «زنده» و «دامنه‌ها» خالی می‌مانند.

**ترتیب تصمیم برای یک دامنه** (`RuleEngine`، یکسان با `vpnconf.py`):
1. اگر آدرس محلی است (`localhost`، `*.local`، شبکه‌های خصوصی) → `direct`.
2. در غیر این صورت، قانونی که `hosts` آن دقیقاً این اسم است.
3. در غیر این صورت، طولانی‌ترین دامنهٔ منطبق.
4. اگر هیچ قانونی نخورد → `vpn`.

`cisco` وقتی Cisco قطع است به `without_cisco` (پیش‌فرض `direct`) تبدیل می‌شود.

## ساختار repo

```
Package.swift
Sources/
  GozarCore/            کتابخانهٔ مشترک
    Models, RuleEngine, Config, ControlAPI, RouterClient
    Router/             پروتکل SOCKS، HTTP، متریک‌ها (قابل تست)
    Conf/               پیاده‌سازی gozarctl: routes، connection، exits، لینک‌ها، اشتراک، آزمایش
    App/                منطق قابل تست ِ اپ: Fmt، پاسخ Grafana، QR، ساخت دستور «افزودن سایت»
  vpn-router/           برنامهٔ مسیریاب
  gozarctl/             برنامهٔ تنظیمات
  Gozar/                اپ SwiftUI (صفحه‌ها، Theme، Strings، DemoData، Snapshots)
Tests/
  GozarCoreTests/       Swift Testing (نه XCTest)
  fixtures/             لینک‌ها، routes نمونه، SOCKS ِ ساختگی، Grafana ِ ضبط‌شده
cli/
  laptop-vpn.sh         دستور vpn
  laptop-vpn.d/         پیش‌فرض‌ها، schemaها، completion، vpnconf.py و sitedomains.py (مرجع و ابزار اختیاری)، tests/
Resources/              Info.plist، آیکن، فونت وزیرمتن (OFL)، gozar-askpass، xray.lock
scripts/                build-app.sh، install.sh، fetch-xray.sh، e2e.sh
docs/
  LAPTOP-VPN.md         راهنمای کامل دستور vpn (فارسی)
  design/               PLAN.md و PLAN2.md: قرارداد ساخت مرحلهٔ ۱ و ۲
```

> مسیرهای داخل `docs/design/PLAN*.md` مال زمانی است که این کد داخل یک repo ِ دیگر بود (`scripts/` ← الان `cli/`، `apps/laptop-vpn/` ← الان ریشهٔ repo).

## فایلهای تنظیمات و وضعیت

همه در `~/.config/laptop-vpn/` (با متغیر `LAPTOP_VPN_STATE` قابل تغییر است و تست‌ها همیشه همین کار را می‌کنند):

| فایل | محتوا |
|---|---|
| `routes.json` | قانون‌ها: `{name, route: vpn|cisco|direct, without_cisco?, enabled?, note?, domains[], hosts[]}` (schema: `cli/laptop-vpn.d/routes.schema.json`) |
| `connection.json` | تنظیمات محلی: پورت SOCKS، keepalive، cipherها، و `router: {enabled, upstream_port, control_port}` |
| `exits.json` (mode 0600) | سرورها و اشتراک‌ها و سرور فعال. لینک‌های V2Ray اینجاست. |
| `ssh.log` و `router.log` | لاگ اتصال و یک خط برای هر درخواست (`HH:MM:SS → host:port [route]`) |
| `router.json` و `router.token` | پورت API و توکن (0600) برای اپ |
| `proxy-before` | تنظیمات قبلی ِ proxy ِ سیستم، که `vpn off` برمی‌گرداند |

**رمزها:**
- رمز SSH در Keychain است، سرویس `phonevpn-relay` (سرور مهاجرت‌شدهٔ `relay`) یا `gozar-ssh` (بقیه).
- توکن Grafana در Keychain است، سرویس `gozar-grafana`.

## توسعه

```bash
swift build                       # debug
.build/debug/Gozar --demo         # اپ با دادهٔ نمایشی؛ به سیستم دست نمی‌زند
.build/debug/Gozar --snapshot /tmp/shots   # PNG ِ همهٔ صفحه‌ها، روشن و تیره
```

**تست‌ها:**

```bash
swift test                        # واحد + golden (مقایسه با vpnconf.py)
python3 -m unittest discover -s cli/laptop-vpn.d/tests -v
cli/laptop-vpn.d/tests/test_cli.sh
scripts/e2e.sh                    # همه: مسیریاب، CLI با ssh و xray ِ واقعی روی loopback، اشتراک، بدون python
```

قانون‌های تست، که شکستنشان می‌تواند VPN ِ واقعی‌ات را به هم بزند:
- هیچ تستی پورت‌های 1080، 1081 و 1090 یا `~/.config/laptop-vpn` را استفاده نمی‌کند. همیشه `LAPTOP_VPN_STATE=<tmp>` و پورت‌های بالای 18000.
- `e2e.sh` برای `networksetup`، `scutil`، `sudo` و `ssh` stub می‌گذارد و چک می‌کند که هیچ دستور واقعی سیستم اجرا نشده باشد.
- XCTest با Command Line Tools کار نمی‌کند. فقط `import Testing`.

## چطور تغییرش بدهم

| می‌خواهی… | کجا |
|---|---|
| متنی در اپ عوض شود | `Sources/Gozar/Strings.swift` (همهٔ متن‌های فارسی فقط آنجاست) |
| رنگ‌ها، فونت، کارت‌ها و درخشش | `Sources/Gozar/Theme.swift` |
| صفحهٔ تازه | یک View در `Sources/Gozar/`، اضافه به `Tab` در `GozarApp.swift`، و حالت demo و snapshot در `DemoData.swift` و `Snapshots.swift` |
| پروتکل لینک تازه یا پارامتر تازه برای VLESS | `Sources/GozarCore/Conf/Links.swift` + یک جفت fixture در `Tests/fixtures/links/<name>.link` و `.json` |
| دستور تازه در `gozarctl` | `Sources/GozarCore/Conf/ConfCLI.swift` (و اگر خروجی JSON دارد، نوعش در `ControlAPI` یا `App/`) |
| دستور تازه در `vpn` | `cli/laptop-vpn.sh` (`case` ِ آخر فایل و `cmd_help`) + `cli/laptop-vpn.d/_vpn` برای Tab |
| قانون‌های پیش‌فرض برای کاربر تازه | `cli/laptop-vpn.d/routes.default.json` |
| رفتار مسیریاب (probe، API و متریک‌ها) | `Sources/vpn-router/` و `Sources/GozarCore/Router/` |
| نسخهٔ Xray | نسخه را در `scripts/fetch-xray.sh` عوض کن، اجرایش کن تا checksum ِ تازه را از فایل `.dgst` ِ release در `Resources/xray.lock` بنویسد، بعد `scripts/build-app.sh` |
| Bundle ID و نسخه | `Resources/Info.plist` |

**نکته‌ها:**
- `gozarctl` باید با `vpnconf.py` یکسان بماند. اگر رفتار قانون‌ها یا فرمت فایل را عوض می‌کنی، هر دو را تغییر بده. تست golden بایت‌به‌بایت مقایسه می‌کند.
- اپ هیچ فایلی را مستقیم ویرایش نمی‌کند. همیشه از `vpn` یا `gozarctl` استفاده می‌کند تا ترمینال و اپ همیشه یک رفتار داشته باشند.
- `vpn-router` فقط روی `127.0.0.1` گوش می‌دهد و فقط اسم میزبان، پورت، تعداد بایت و زمان را ثبت می‌کند، هیچ‌وقت محتوای ترافیک را.

## Grafana

صفحهٔ «سرورها» یک بخش اختیاری «مانیتورینگ سرور» دارد. این بخش برای سروری است که متریک‌های `egress_tunnel_*` و `egress_host_*` را به Prometheus می‌دهد. کوئری‌ها در `Sources/Gozar/GrafanaClient.swift` هستند.

برای وصل کردنش:
1. در Grafana یک Service account با نقش **Viewer** بساز.
2. یک توکن برایش بساز.
3. در گذر، در تنظیمات، نشانی Grafana و توکن را وارد کن.

بدون Grafana هم همه‌چیز کار می‌کند.

## امنیت و حریم خصوصی

- اپ فقط به سرورهایی که خودت اضافه کرده‌ای، به Grafana ِ خودت (اگر تنظیم شده) و به لینک‌های اشتراکی که خودت داده‌ای وصل می‌شود.
- لینک‌ها و رمزها هیچ‌جا چاپ نمی‌شوند. `gozarctl exits --json` فقط host ِ اشتراک را نشان می‌دهد.
- API ِ کنترل ِ مسیریاب فقط روی loopback است و توکن تصادفی لازم دارد.
- اپ امضای ad-hoc دارد. اگر می‌خواهی پخشش کنی، با Developer ID امضا و notarize کن.

فونت وزیرمتن تحت مجوز SIL OFL 1.1 است (`Resources/fonts/OFL.txt`).
