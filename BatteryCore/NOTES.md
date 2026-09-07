# BatteryCore — implementation notes

Everything the menu-bar app author needs that is not obvious from the source.

## Document map

1. [Package layout](#1-package-layout) — targets, the C bridge, test fixtures.
2. [The C bridge](#2-the-c-bridge) — `systemLibrary` targets, pkg-config, C enums in Swift.
3. [The exact call sequence that works](#3-the-exact-call-sequence-that-works) — the libimobiledevice/lockdown handshake.
4. [Measured latencies](#4-measured-latencies-m-series-macbook-pro-iphone-on-ios-2661) — real timings on the dev machine.
5. [Wi-Fi is not continuously reachable](#5-wi-fi-is-not-continuously-reachable--this-is-the-big-one) — the Bonjour flapping problem.
6. [Field quirks found in the real dumps](#6-field-quirks-found-in-the-real-dumps) — plist gotchas from real devices.
7. [Notes for the menu-bar app](#7-notes-for-the-menu-bar-app) — dylibs, entitlements, snapshot file, threading.
8. [Polling cadence](#8-polling-cadence) — the pre-activity cadence table and backoff ladder.
9. [Charge maths](#9-charge-maths) — the EMA estimator, ETA-to-80%, the three power figures.
10. [Running it](#10-running-it) — `swift build`/`swift test` and `tandemctl` invocations.
11. [Appendix — raw observations from the live device](#11-appendix--raw-observations-from-the-live-device).
12. [Direct lockdown client](#12-direct-lockdown-client--talking-to-the-phone-without-usbmuxd) — talking to the phone without usbmuxd, TLS settings, the address book.
13. [Two tiers, one race](#13-two-tiers-one-race--the-read-as-it-now-works) — the shipped read path, partial readings, typed errors.
14. [Energy policy](#14-energy-policy--polling-only-as-often-as-somebody-is-looking) — `ActivityLevel`, the widget breadcrumb, instrumentation.
15. [History store](#15-history-store--accumulating-what-neither-os-will-tell-us) — SQLite schema, the skip rule, sessions, the summary JSON.
16. [Resync, and the 80 % milestone](#16-resync-and-the-80--milestone) — `TandemMonitor.resync()`, `ChargeMilestone`.
17. [tandemctl subcommands](#17-tandemctl-subcommands) — the CLI surface as implemented.

## 1. Package layout

```
BatteryCore/
  Package.swift                     swift-tools-version 6.0, macOS 15+, Swift 6 language mode
  Sources/CLibimobiledevice/        systemLibrary target: shim.h + module.modulemap
  Sources/CLibusbmuxd/              systemLibrary target: usbmuxd.h (pair records)
  Sources/COpenSSL/                 systemLibrary target: openssl@3
  Sources/CTandemTLS/               C shim over the OpenSSL macros (see §12)
  Sources/BatteryCore/              the library
  Sources/tandemctl/                the CLI
  Tests/BatteryCoreTests/Fixtures/  copies of /Tandem/Fixtures, bundled as test resources
```

## 2. The C bridge

`Sources/CLibimobiledevice` is a SwiftPM `systemLibrary` target:

```swift
.systemLibrary(
    name: "CLibimobiledevice",
    pkgConfig: "libimobiledevice-1.0",
    providers: [.brew(["libimobiledevice", "libplist"])]
)
```

`module.modulemap` declares `umbrella header "shim.h"` plus
`link "imobiledevice-1.0"` and `link "plist-2.0"`; `shim.h` just includes
`libimobiledevice/{libimobiledevice,lockdown,diagnostics_relay}.h` and
`plist/plist.h`. No `unsafeFlags`, so the package stays usable as a dependency.

**pkg-config is required at build time.** It was missing on this machine;
`brew install pkg-config` (which pours `pkgconf` 3.0.7) fixed it. Without it
SwiftPM cannot resolve the include/lib paths and the build fails at
`#include <libimobiledevice/...>`.

`pkg-config --cflags --libs libimobiledevice-1.0` resolves to the Cellar paths
for libimobiledevice 1.4.0, libusbmuxd 2.1.1, libimobiledevice-glue 1.3.2,
libplist 2.7.0 and openssl@3 3.6.3.

### C enums in Swift

Non-typedef'd C enums import as structs with a `rawValue`, so option sets have
to be rebuilt by hand:

```swift
idevice_options(rawValue: IDEVICE_LOOKUP_USBMUX.rawValue | IDEVICE_LOOKUP_NETWORK.rawValue)
```

### Known linker warnings (not introduced by this package)

```
ld: warning: building for macOS-15.0, but linking with dylib
'/opt/homebrew/opt/libimobiledevice/lib/libimobiledevice-1.0.6.dylib'
which was built for newer version 26.0
```

The Homebrew bottles are built for macOS 26 while the package targets macOS 15.
Harmless, and it disappears if you either raise the platform to `.v26` or ship
your own dylibs built with a 15.0 deployment target (see §7).

## 3. The exact call sequence that works

Taken from `tools/idevicediagnostics.c` and replicated in
`PhoneBatterySource.openSession` / `.query`:

```
idevice_new_with_options(&device, udid, USBMUX|NETWORK[|PREFER_NETWORK])
lockdownd_client_new_with_handshake(device, &client, "tandem")
lockdownd_start_service(client, "com.apple.mobile.diagnostics_relay", &service)
    └─ on LOCKDOWN_E_INVALID_SERVICE retry "com.apple.iosdiagnostics.relay"
lockdownd_client_free(client)                       // freed as soon as the port is known
diagnostics_relay_client_new(device, service, &relay)
diagnostics_relay_query_ioregistry_entry(relay, "AppleSmartBattery", "", &node)
plist_to_bin(node, &buf, &len)  →  Data  →  PropertyListSerialization
plist_free(node); plist_mem_free(buf)
diagnostics_relay_goodbye(relay); diagnostics_relay_client_free(relay)
lockdownd_service_descriptor_free(service); idevice_free(device)
```

Two details that matter:

* the **entry_name** argument is `"AppleSmartBattery"` and the **entry_class**
  argument is the empty string `""` — not `NULL`, and not swapped. Passing the
  name as the class returns success with an empty dictionary.
* the returned buffers must be released with `plist_mem_free`, not `free`.

Nothing shells out. `ioreg` / `idevicediagnostics` were only used to mint the
fixtures.

Device names come from `lockdownd_get_value(client, NULL, "DeviceName", &node)`
and are cached per UDID, because that call needs its own lockdown handshake.

## 4. Measured latencies (M-series MacBook Pro, iPhone on iOS 26.6.1)

| operation | USB | Wi-Fi |
| --- | --- | --- |
| `idevice_get_device_list_extended` (discovery only) | < 1 ms | < 1 ms |
| full `tandemctl once` (Mac + phone, session opened and closed) | ~0.05 s phone leg | **0.39–0.43 s** total |
| Mac IOKit read alone | < 1 ms | — |
| phone read against a **stale** Bonjour record | — | **up to 48 s** before libimobiledevice gives up |

The Mac read is an `IORegistryEntryCreateCFProperties` call, so it is free; poll
it as often as you like.

## 5. Wi-Fi is not continuously reachable — this is the big one

After the phone is unplugged, its `_apple-mobdev2._tcp` Bonjour record does not
appear for ~20 s, and then flaps: `idevice_id -n` alternates between listing the
device and returning nothing, over the course of a minute or more, even with the
phone on the same LAN and awake. Observed here: three consecutive `idevice_id -n`
calls seconds apart returned nothing, then twelve consecutive reads succeeded.

Consequences, all handled in the library:

* `PhoneError.noDevice` is **transient**, never fatal. `PhoneRetryPolicy`
  (default: 3 attempts, 3 s apart) is applied to both discovery
  (`discoverWithRetry()`) and reads (`read(_:)`).
* Only `.notPaired` is treated as permanent (`PhoneError.isTransient`).
* A **per-attempt deadline** (default 8 s) is enforced, because a stale Bonjour
  record makes `idevice_new_with_options` + the lockdown TCP connect block for
  ~48 s. The stateless read path runs on a detached task so the timeout can
  abandon it without wedging the actor; that is safe because the stateless path
  owns and frees every handle it touches. `PhoneError.timedOut` is transient.
* `TandemMonitor` keeps the last good reading with its `lastSeen` and flips
  `DeviceStatus.stale` after `Configuration.staleAfter` (default 180 s) rather
  than blanking the UI, and it keeps polling on the `PollingPolicy` backoff.
* The Mac loop and the phone loop are independent tasks, so a phone that is
  hanging on a dead TCP connect never delays the Mac readout.

### Keep-alive: does holding the connection open help?

`PhoneBatterySource.setKeepAlive(true)` (CLI: `--keep-alive`) holds the
`idevice_t` + `diagnostics_relay_client_t` open between reads instead of doing
open/query/close each time. Measured with `tandemctl probe --keep-alive
--interval 20 --count 20` against a live phone over Wi-Fi, with a
`tandemctl probe --interval 20` control running alongside — see §11 for the raw
logs. Conclusions:

* **It works, and it is ~4x faster while the session lives.** Reads on a reused
  session took 0.06–0.24 s against 0.29–0.50 s for a fresh open/query/close.
* **A session does survive minutes of idle** when the phone stays reachable —
  the longest observed here was 147 s (nine consecutive reads 20 s apart) on a
  single session before the phone disappeared from usbmuxd again.
* **But it does not remove the flapping.** When usbmuxd drops the phone the
  kept session dies with it, and the immediate reopen fails too; two blackout
  windows of ~40 s each occurred in a 7-minute run. Keep-alive is a latency
  optimisation, not a reachability fix — you still need the retry policy and the
  stale-reading logic.
* It can never wedge the loop: any query failure drops the session and the next
  attempt opens a fresh one.

Recommendation for the menu-bar app: leave keep-alive **off** at the 60/120 s
cadence (the session usually will not survive to the next poll anyway and the
0.3 s saving is invisible), and turn it on only if you ever poll at a few
seconds — e.g. while a popover is open.

### Discovery blackouts are not our bug

During a blackout the reference CLI behaves identically: `idevice_id -n` printed
nothing on three consecutive calls at the exact moment `tandemctl dump` was
failing with "No device found", while a process holding an already-open session
kept reading successfully. Treat `idevice_get_device_list_extended` returning an
empty list as "ask again later", never as "the phone is gone".

## 6. Field quirks found in the real dumps

* **Unsigned negatives.** IORegistry integers are often stored unsigned, so a
  negative current arrives as its 64-bit two's-complement bit pattern
  (`18446744073709550615` == `-1001`). `BatteryPlistParser.normalizedInt` treats
  anything above `Int64.max / 2` as signed. `plist_to_xml` normalises these back
  to signed for the XML fixtures, but the binary plist and IOKit paths do not, so
  the decoder has to handle both.
* **`BatteryPower` sign is not portable.** iPhone signs it (`-440` mW while
  discharging), the Mac does not (`+32554` mW while discharging, with
  `SystemLoad` carrying the `-32554`). The parser therefore takes the
  *magnitude* from `PowerTelemetryData.BatteryPower` and the *sign* from
  `InstantAmperage`, which is signed everywhere.
* **`SystemPowerIn` is `0`, not absent, on battery.** Parsed as `nil` so
  "unknown" and "zero watts from the wall" do not look alike. It is reported on
  the Mac exactly as it is on the iPhone, and it is the *only* honest answer
  while a Mac is plugged in and not charging — see the next bullet.
* **A plugged, not-charging Mac has `Amperage == 0`.** Nothing is entering or
  leaving the pack, so `Amperage × Voltage` is 0 W, and a UI that computes its
  wattage that way says "0 W" about a machine drawing 13 W from a 140 W brick
  (this was a real user report). `Fixtures/mac-plugged-not-charging.plist` is
  that state: `Amperage 0`, `PowerTelemetryData.BatteryPower 0`, but
  `SystemLoad 13307`, `SystemPowerIn 13307` and `AdapterDetails.Watts 140`. The
  rule the app now follows: **battery current answers "is the pack filling",
  `PowerTelemetryData` answers "how much power is moving".**
* **`SystemLoad`'s sign is not portable either.** It is what the machine itself
  is consuming, in mW, and both platforms report it plugged or not — but the Mac
  writes `-32554` on battery and `+13307` on the adapter, while the iPhone
  writes `+440` on battery. `BatteryReading.systemLoadW` therefore keeps the
  **magnitude** and the UI takes the direction from `externalConnected`, the
  same treatment `BatteryPower` gets. `0` is read as "not reported".
* **`AdapterDetails` is always present.** While unplugged the iPhone reports
  `{Description: "batt", Watts: 0}` and the Mac reports `{FamilyCode: 0}`.
  `adapterWatts` is `nil` when `Watts` is absent or `0`; `adapterDescription`
  passes `"batt"` through, so gate adapter UI on `externalConnected`.
* **`TimeRemaining` vs `AvgTimeToEmpty`.** iPhone `TimeRemaining` is nonsense
  while charging (582 min at 28 % on a 15 W charger). While discharging both
  keys agree (696 min) and are usable. The Mac's `TimeRemaining` is the number
  macOS itself shows. `ChargeEstimator` uses `AvgTimeToEmpty` for the iPhone and
  `TimeRemaining` for the Mac, both only while discharging, and never for the
  charge ETA. `65535` is the "unknown" sentinel; anything outside `1..<6000`
  minutes is discarded.
* **`CurrentCapacity` is a percentage** on Apple Silicon and on iOS
  (`MaxCapacity == 100`). Intel Macs report mAh in both, so the parser scales
  when `MaxCapacity != 100`.
* **Packaging differs.** iPhone dumps nest everything under a top-level
  `IORegistry` key; `ioreg -a -rc` emits a one-element array. Both are unwrapped
  by `BatteryPlistParser.rootDictionary`.
* **`Temperature` is centi-°C** (`2889` → 28.89 °C). There is also a
  `VirtualTemperature`; we use `Temperature`.
* **`InstantAmperage` vs `Amperage`.** `InstantAmperage` is the fresher sample
  and is what the estimator wants; `Amperage` is the fallback when it is absent.
* **The fixture values differ slightly from the numbers in the original brief**
  (`mac-discharging.plist` is 81 %, 6404 mAh, 12108 mV, −2724 mA, 166 min, not
  84 % / 6691 / 12305). The tests assert what is actually in the files.

## 7. Notes for the menu-bar app

**Dylibs to bundle** (or link against Homebrew and require it). `otool -L` on
`libimobiledevice-1.0` pulls in the whole chain:

```
/opt/homebrew/opt/libimobiledevice/lib/libimobiledevice-1.0.6.dylib
/opt/homebrew/opt/libusbmuxd/lib/libusbmuxd-2.0.7.dylib
/opt/homebrew/opt/libimobiledevice-glue/lib/libimobiledevice-glue-1.0.0.dylib
/opt/homebrew/opt/libplist/lib/libplist-2.0.4.dylib
/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib
/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib
```

Copy them into `Contents/Frameworks`, rewrite the install names with
`install_name_tool -change ... @rpath/...` (and add
`@executable_path/../Frameworks` to the rpath), then re-sign. They are all
LGPL/Apache/OpenSSL-licensed; ship the licences.

**Entitlements / sandbox.** usbmuxd is reached over the UNIX socket
`/var/run/usbmuxd`, which the App Sandbox blocks. Either ship unsandboxed
(Developer ID, outside the Mac App Store) or the phone half will not work. The
Mac half (IOKit) is fine in a sandbox. No USB entitlement is needed — usbmuxd
does the device I/O — and pairing must already exist (`idevicepair pair`, plus
"Trust This Computer" on the phone, plus Finder's "Show this iPhone when on
Wi-Fi" for the network path).

**Snapshot file.** `SnapshotStore` writes `TandemSnapshot` as pretty-printed,
key-sorted JSON with ISO-8601 dates via `Data.write(.atomic)`, creating
intermediate directories. Point it at the App Group container
(`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`) and
a widget or extension can read it without talking to usbmuxd at all.

**Threading.** `MacBatterySource`, `PhoneBatterySource`, `SnapshotStore` and
`TandemMonitor` are actors; `BatteryReading`, `TandemSnapshot`,
`ChargeEstimator`, `PollingPolicy` and `StatusFormatter` are `Sendable` value
types. `MacBatterySource.events` spins up its own `CFRunLoop` thread for
`IOPSNotificationCreateRunLoopSource`, so it does not need the main run loop —
useful in an agent with no NSApplication. `PhoneBatterySource.events` shares one
process-wide `idevice_event_subscribe` registration, reference counted across
streams, because the C callback is a bare function pointer.

**Wake-ups.** `TandemMonitor` never uses `Timer`; it races `Task.sleep` against
the two event streams via `AsyncSignal`, so an unplug or a USB attach produces a
reading immediately instead of at the next tick. Add your own signal for
`NSWorkspace.didWakeNotification` and network-reachability changes when you wire
up the UI.

## 8. Polling cadence

`PollingPolicy` is pure and unit-tested, and since §14 it takes an
`ActivityLevel` as well as a state: **how often the phone is dialled depends on
whether anybody can see the answer.** The full table is in §14; the short
version, for the phone:

| level | charging | on battery | unreachable |
| --- | --- | --- | --- |
| `.hidden` (display asleep / locked) | never | never | never |
| `.background` (menu bar only) | 120 s | 300 s | 300 → 300 → 300 → 600 s |
| `.widgetVisible` | 60 s | 120 s | 120 → 120 → 300 → 600 s |
| `.popoverOpen` | 15 s | 15 s | 15 s |
| any external event | 0 s (poll now), at every level but `.hidden` | | |

The Mac is never stopped, only slowed: `macDelay` is 60 s charging / 120 s on
battery, and 600 s while `.hidden` — a sanity read, since the IOKit call is
free and the label has to be right the moment the screen comes back.

`nextDelay(state:consecutiveFailures:externalEvent:)` is unchanged and still
means 60 s / 120 s / the backoff ladder, which is what a caller with no UI
(`tandemctl`) gets. The **ladder itself changed**: it is now
30 → 60 → 120 → 300 → `60 → 120 → 300 → 600`, capped at 600 s rather than 300 s,
and any event resets it to zero.

This is deliberately not real time. External events — IOKit power-source
notifications, usbmuxd attach/detach, and now `NWPathMonitor` path changes —
short-circuit the sleep, so plugging a cable in still updates instantly.

## 9. Charge maths

`ChargeEstimator` keeps an EMA (α = 0.3) of signed `InstantAmperage` per device
id, seeded by the first sample.

* `etaTo80 = (0.8 · rawMaxMAh − rawCurrentMAh) / smoothedMA` hours, only while
  charging, with `smoothedMA ≥ 50` and `percent < 80`. Worked example from the
  fixture: `(0.8·4966 − 1370)/2954 h = 0.881 h ≈ 53 min`.
* `timeToEmpty` while discharging: the device's own estimate when sane
  (`AvgTimeToEmpty` on iPhone, `TimeRemaining` on Mac), else
  `rawCurrentMAh / |smoothedMA|` hours, subject to the same 50 mA floor.
* `chargingWatts = systemPowerInW ?? batteryPowerW`, only while charging.

**What the UI prints is not what the estimator computes.** The estimator's job
is the ETA, and for that only battery current means anything —
`SystemLoad`/`SystemPowerIn` are never fed into it. The three power figures on
screen come straight off the reading, and there is one rule for all three
surfaces (popover columns, widget power line, summary window):

| state | "system" | "adapter" |
| --- | --- | --- |
| plugged, charging | `SystemLoad` → `2 W` | `SystemPowerIn`/`Watts` → `⚡ 36/45 W` |
| plugged, not charging | `SystemLoad` → `13 W` | `SystemPowerIn`/`Watts` → `13/140 W` |
| on battery, Mac | `−SystemLoad`, else `−|batteryPowerW|` | `—` |
| on battery, iPhone | `—` (deliberate) | `—` |

The orange bolt appears on the adapter figure and only while `isCharging`;
plugged-and-idle is a plain figure, because 13 W really is crossing the cable.
Whole watts everywhere — the tenths were never the point. When only the brick's
rating is known the widget prefixes a `powerplug` glyph, so a number that is an
*offer* never reads as a *flow*. `StatusFormatter.line` prints the same thing
with tenths for `tandemctl`: `MacBook Pro  90 %  plugged  13.3/140 W  system
13.3 W`.

## 10. Running it

```
swift build
swift test                    # needs Xcode's Testing.framework, see below
swift run tandemctl once      # both devices, one line each
swift run tandemctl once --json
swift run tandemctl watch --interval 30 --out /tmp/tandem.json
swift run tandemctl dump > new-fixture.plist
swift run tandemctl probe --keep-alive --interval 20 --count 20
swift run tandemctl once --direct-only        # no usbmuxd at all, see §12
swift run tandemctl once --no-direct          # usbmuxd only
swift run tandemctl addresses                 # the address book + the ARP lookup
swift run tandemctl probe --compare --interval 15 --count 20
swift run tandemctl probe --tiers --count 8 --interval 15   # which tier answered, §13
swift run tandemctl lockdown                  # raw GetValue on com.apple.mobile.battery
```

`probe` reads the phone repeatedly and prints one timed line per attempt with
the session age and the exact error on failure. It is the tool the numbers in
§5 came from.

`probe --tiers` runs the *shipped* read — the direct/usbmuxd race followed by
the degraded `GetValue` tier — and labels each iteration `full ok`,
`partial ok` or `failed` with its latency and the winning route. It is the tool
behind §13.

A `once` line now ends with `partial` when the reading came from the degraded
tier, and with `detail 3m ago` when the watt/adapter/ETA columns to its left are
that much older than the percent:

```
iPhone  73 %  charging  15.8 W (45 W adapter)  wifi  partial  detail 3m ago
```

`swift test` needs `swift-testing`, which ships with Xcode but **not** with the
CommandLineTools. With `xcode-select` pointing at the CLT, run:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`swift build` and `swift run` work with the CLT toolchain as-is.

## 11. Appendix — raw observations from the live device

Test rig: MacBook Pro (Apple Silicon, macOS 26.6), iPhone on iOS 26.6.1,
UDID `<udid>`, paired with `EnableWifiConnections=true`, same LAN.
The phone was charging on a 45 W adapter and USB was disconnected, so every
phone number below is the Wi-Fi path.

`tandemctl probe --keep-alive --interval 20 --count 20`:

```
12:24:42 #01 ok 0.517 s  69 %  +4470 mA  session 0 s old
12:25:03 #02 FAIL 0.002 s  No device found with udid 00001111-000A1B2C3D4E5F60
12:25:24 #03 FAIL 0.001 s  No device found
12:25:44 #04 ok 0.441 s  71 %  +3874 mA  session 0 s old
12:26:06 #05 ok 0.361 s  71 %  +3677 mA  session 0 s old
12:26:26 #06 ok 0.123 s  72 %  +3504 mA  session 21 s old
12:26:47 #07 ok 0.061 s  72 %  +3373 mA  session 41 s old
12:27:08 #08 FAIL 0.001 s  No device found with udid 00001111-000A1B2C3D4E5F60
12:27:29 #09 FAIL 0.001 s  No device found
12:27:50 #10 ok 0.294 s  73 %  +3340 mA  session 0 s old
12:28:11 #11 ok 0.075 s  74 %  +3340 mA  session 21 s old
12:28:32 #12 ok 0.076 s  74 %  +3341 mA  session 42 s old
12:28:52 #13 ok 0.175 s  74 %  +3342 mA  session 62 s old
12:29:13 #14 ok 0.215 s  75 %  +3200 mA  session 83 s old
12:29:35 #15 ok 0.242 s  75 %  +2986 mA  session 105 s old
12:29:56 #16 ok 0.139 s  75 %  +2841 mA  session 126 s old
12:30:17 #17 ok 0.042 s  76 %  +2700 mA  session 147 s old
12:30:38 #18 FAIL 0.001 s  No device found with udid 00001111-000A1B2C3D4E5F60
12:30:58 #19 FAIL 0.001 s  No device found
12:31:18 #20 FAIL 0.001 s  No device found
```

`tandemctl probe --interval 20 --count 12` (fresh session each read), running
concurrently:

```
12:27:59 #01 ok 0.501 s  73 %  +3342 mA  session fresh
12:28:20 #02 ok 0.298 s  74 %  +3340 mA  session fresh
12:28:42 #03 ok 0.426 s  74 %  +3341 mA  session fresh
12:29:02 #04 ok 0.367 s  74 %  +3342 mA  session fresh
12:29:24 #05 ok 0.357 s  75 %  +3200 mA  session fresh
12:29:45 #06 ok 0.310 s  75 %  +2841 mA  session fresh
12:30:06 #07 ok 0.357 s  75 %  +2717 mA  session fresh
12:30:28 #08 ok 0.483 s  76 %  +2575 mA  session fresh
12:30:49 #09 FAIL 0.001 s  No device found with udid 00001111-000A1B2C3D4E5F60
12:31:10 #10 FAIL 0.001 s  No device found
12:31:31 #11 FAIL 0.001 s  No device found
```

Note that the 12:30:38–12:31:18 blackout hit **both** processes at once, which is
what pins it on usbmuxd/Bonjour rather than on anything about session reuse.

A successful `tandemctl once` over Wi-Fi:

```
$ tandemctl once
took 0.407 s
MacBook Pro  73 %  discharging  −12.9 W  6:17 left
iPhone  73 %  charging  15.8 W (45 W adapter)  80 % in 7 min  wifi
```


## 12. Direct lockdown client — talking to the phone without usbmuxd

§5 established that the phone drops out of usbmuxd's Bonjour device list for
~40 s at a time while it sleeps, and that libimobiledevice fails identically in
those windows because it asks usbmuxd where the phone is. The phone itself never
stops listening on **port 62078**. `DirectLockdownClient` therefore skips
discovery entirely: it takes the pair record out of usbmuxd (which hands it over
whether or not the device is currently visible) and speaks lockdown straight to
a remembered IP.

### 12.1 The protocol sequence that works

Implemented in `DirectLockdownClient.performBlocking`, over a plain BSD socket
plus OpenSSL 3 — no `Network.framework`, no `SecIdentity`, nothing in a keychain.

```
usbmuxd_read_pair_record(udid)          -> plist: HostID, SystemBUID,
                                           HostCertificate, HostPrivateKey, ...
connect <ip>:62078
  ->  {Label:"tandem", Request:"QueryType"}
  <-  {Request:"QueryType", Type:"com.apple.mobile.lockdown"}
  ->  {Label, Request:"StartSession", HostID, SystemBUID}
  <-  {Request:"StartSession", SessionID:"...", EnableSessionSSL:true}
  ==  upgrade THIS socket to TLS, host certificate + key as the client identity
  ->  {Label, Request:"StartService", Service:"com.apple.mobile.diagnostics_relay"}
  <-  {Request:"StartService", Port:<n>, EnableServiceSSL:true}
connect <ip>:<n>
  ==  TLS again, same identity, because EnableServiceSSL was true
  ->  {Request:"IORegistry", EntryName:"AppleSmartBattery"}
  <-  {Status:"Success", Diagnostics:{IORegistry:{...}}}
  ->  {Request:"Goodbye"} on the relay, then on lockdown; close both
```

Details that matter:

* **Framing** is a 4-byte big-endian payload length followed by a property list
  (`LockdownWire`). We always send XML; lockdownd replies XML and
  diagnostics_relay replies **binary**, so the decoder must sniff —
  `PropertyListSerialization` does. The length prefix does not include itself,
  and a length of `0` or anything over 16 MB is treated as a desynchronised
  stream rather than trusted.
* The session TLS upgrade happens **on the same socket**, mid-conversation.
  Nothing after `StartSession` is readable in the clear.
* The service port is a *second* TCP connection, and it needs its own TLS
  handshake with the same client identity.
* `EntryName` here, unlike the libimobiledevice call in §3, takes no companion
  `EntryClass` — omit the key rather than sending `""`.
* No escrow bag is needed for diagnostics_relay. pymobiledevice3 does not send
  one either.
* The private key is read from the usbmuxd socket into memory, handed to OpenSSL
  through a `BIO_new_mem_buf`, and never written to disk. (pymobiledevice3 writes
  a temp file; we do not.) `PairRecord.description` redacts it.

### 12.2 TLS settings that were required

In `Sources/CTandemTLS/tandem_tls.c`, copied from pymobiledevice3's
`ServiceConnection.create_ssl_context`. Without these the handshake fails against
OpenSSL 3's defaults:

| setting | why |
| --- | --- |
| `SSL_CTX_set_security_level(ctx, 0)` | OpenSSL 3 refuses the device's suites/key sizes at its default level 1. pymobiledevice3 achieves the same with the `@SECLEVEL=0` cipher-string suffix. |
| `SSL_CTX_set_cipher_list("ALL:!aNULL:!eNULL:@SECLEVEL=0")` | as above, belt and braces |
| `SSL_OP_LEGACY_SERVER_CONNECT` | lockdownd does not send the renegotiation-info extension |
| min TLS 1.2 / max TLS 1.3 | iOS 5+ speaks 1.2; current devices offer 1.3 |
| `SSL_VERIFY_NONE` | the device's certificate is self-signed; trust flows the other way, from our client certificate |
| no SNI | pymobiledevice3 passes `server_hostname=""`; an IP would be rejected as a hostname anyway |

A small C shim exists only because `SSL_CTX_set_min_proto_version`,
`SSL_CTX_set_options` and friends are macros over `SSL_CTX_ctrl` and so are
invisible to Swift. Everything else is plain Swift.

### 12.3 The address problem — usbmuxd hands you the wrong address

This was the one real surprise, and it is worth knowing before anyone tries to
reproduce the work.

`idevice_get_device_list_extended` gives a `conn_data` sockaddr for network
devices. On this network it is always the phone's **IPv6 link-local**,
`fe80::1%en0` — and that address is *useless for our purpose*:

```
during a blackout, connect to fe80::…%en0:62078  -> times out at 8 s, every time
during the same blackout, connect to 192.0.2.10:62078 -> succeeds in ~10 ms
```

The asymmetry is Neighbour Discovery: resolving the link-local needs the phone's
own network stack to answer a solicitation, which a sleeping phone does not do,
whereas its IPv4 ARP is answered by the Wi-Fi chip (or the AP) throughout. A
first run of `probe --compare` against the link-local scored **direct 5/12 vs
usbmux 5/12** — no better than usbmuxd, and 8 s slower on every failure.

So `NeighborTable` reads the kernel's ARP and NDP caches directly
(`sysctl(NET_RT_FLAGS)`, no shelling out to `arp(8)`), finds the hardware address
that answers to the link-local, and looks up the IPv4 for the same hardware.
That IPv4 becomes the address we dial first; the link-local is kept as a
fallback for networks where no ARP entry exists. The promotion is persisted, so
the lookup happens once.

`inet_ntop` on the NDP entries needs the KAME de-embedding step: for link-local
addresses the interface index lives in bytes 2-3 of the address rather than in
`sin6_scope_id`, and must be zeroed before printing and re-attached as
`%interface`.

### 12.4 The address book

`PhoneAddressBook` is an actor over `~/Library/Application
Support/Tandem/addresses.json` (the directory is a constructor parameter):

```json
{
  "<udid>": {
    "udid": "<udid>",
    "host": "192.0.2.10",
    "alternateHosts": ["fe80::1%en0"],
    "name": "iPhone",
    "lastSeen": "2026-09-07T12:57:11Z"
  }
}
```

* Written every time usbmuxd *can* see the phone — which is the only moment it
  will tell us where the phone is. `discoverWithRetry()` and
  `addressableDevices()` both refresh it.
* Read back when usbmuxd cannot see the phone. `PhoneBatterySource
  .addressableDevices()` will offer a remembered phone as a `.wifi` device even
  during a total blackout, which is what lets `once --direct-only` work at all.
* Nothing secret is in the file: a UDID, an IP, a device name, a timestamp.
* `DirectFirstReader.maximumAddressAge` can expire entries; the default is never,
  because a stale address costs one fast connect refusal and a home DHCP lease
  outlives any window we care about.

### 12.5 Read path and API

`PhoneBatterySource.read(_:timestamp:useDirectClient:)` — `useDirectClient`
defaults to `true`, so existing call sites get the new behaviour unchanged:

1. Wi-Fi device with a remembered address → `DirectLockdownClient`, trying each
   candidate address in turn under one 15 s cap.
2. Anything else, or a direct failure → the original usbmuxd path, and on
   success the address book is refreshed from usbmuxd.
3. USB devices skip the direct path entirely; a cabled phone is not flapping.

The decision itself lives in `DirectFirstReader`, which takes the two reads as
closures and is unit-tested with a fake transport. `TandemMonitor.Configuration`
exposes `useDirectClient` and `directOnly`.

> **Superseded by §13.** The sequential "direct, then usbmuxd" ordering above is
> what made a blackout cost ~14 s. `PhoneBatterySource.read` now hands both
> transports to `PhoneReadRace` and takes the first success instead.
> `DirectFirstReader` is still the thing that decides *whether* the direct path
> is eligible (`useDirect`, `directOnly`, `maximumAddressAge`), and its API is
> unchanged; it just no longer sequences the two reads.

`BatteryReading` gains **`viaDirect: Bool`**. `Transport` is unchanged and stays
`.wifi` — adding a `.wifiDirect` case would break any exhaustive `switch` in the
app, and the transport really is still Wi-Fi. `viaDirect` decodes as `false` when
the key is absent (see `DecodesAsFalseWhenAbsent`), so snapshots written before
this change still load.

Timeouts: connect 8 s, every read and write 8 s (`SO_RCVTIMEO`/`SO_SNDTIMEO`),
whole attempt 15 s. The connect is a non-blocking `connect()` raced against
`poll()`, so a dead address fails in 8 s rather than the kernel's ~75 s. The
blocking work runs on a detached task, exactly as the libimobiledevice path
does, so Swift concurrency can abandon it.

### 12.6 CLI

```
tandemctl once --direct-only        # never touch usbmuxd; report the real failure
tandemctl once --no-direct          # the pre-§12 behaviour
tandemctl addresses                 # what the address book knows, plus the ARP lookup
tandemctl probe --compare --interval 15 --count 20
```

### 12.7 Measured — and an honest correction to the premise

`tandemctl probe --compare --interval 15 --count 20`, iPhone charging on a 45 W
adapter, screen off, same LAN, 13:00–13:08:

```
summary over 20 iterations at 15 s
  direct ok  6/20  median 0.26 s  max 0.42 s
  usbmux ok  6/20  median 0.27 s  max 0.31 s
  direct only: 0   usbmux only: 0   both failed: 14
  first direct failure: Timed out after 8.0 s during connect 192.0.2.10:62078
  first usbmux failure: No device found with udid 00001111-000A1B2C3D4E5F60
```

**Direct did not beat usbmuxd in this run, because in this phone state the phone
is not reachable at all during a blackout.** A 3.5-minute control, sampling raw
`nc 192.0.2.10 62078` and `idevice_id -n` together every 5 s, shows why:

```
13:02:04  nc timeout 8.00 s                        idevice_id[]
   … eight consecutive samples, both dead …
13:03:35  nc connected in 2.06 s                   idevice_id[]        <- TCP back first
13:03:42  nc timeout 8.00 s                        idevice_id[]
13:04:34  nc connected in 0.02 s                   idevice_id[]        <- TCP back first
13:04:39  nc connected in 0.22 s                   idevice_id[<udid>]
13:04:57  nc connected in 1.01 s                   idevice_id[]        <- TCP back first
13:05:03  nc connected in 0.01 s                   idevice_id[<udid>]
   … six good samples …
13:05:34  nc timeout 8.00 s                        idevice_id[]
13:06:39  nc connected in 0.21 s                   idevice_id[]        <- TCP back first
13:06:45  nc connected in 0.09 s                   idevice_id[<udid>]
   … seven good samples …
13:07:34  nc connected in 7.03 s                   idevice_id[]        <- TCP back first
13:07:46  nc timeout 8.00 s                        idevice_id[]
```

Over 43 samples: raw TCP succeeded 18 times, usbmuxd listed the device 13 times,
and **every** sample where TCP worked but usbmuxd did not was at the leading edge
of a recovery. So the two are strongly correlated here, and the real conclusion
is:

* The lead's measurement (TCP 23/24, direct read 13/14 *during* blackouts) does
  not reproduce with the phone in this state. What we see is the phone's Wi-Fi
  radio going away entirely for ~40 s at a time, not a Bonjour bookkeeping
  problem. Both paths then fail, necessarily.
* The direct client's real, measured advantage is **earlier recovery**: TCP comes
  back 5–10 s before the Bonjour record does, five times out of five here, and a
  first connect after a nap takes up to 7 s (matching the lead's "up to 2.3 s",
  only worse). At a 60–120 s polling cadence that is worth roughly one extra
  successful poll per blackout, not a transformation.
* It also removes usbmuxd as a *dependency* for the read, which matters
  independently: no `/var/run/usbmuxd` socket, no Bonjour, nothing to go stale.

The one cost is failure latency: a dead direct attempt spends 8 s in `connect`
where the usbmuxd path fails in under a millisecond. `DirectLockdownClient`
therefore stops trying further candidate addresses as soon as one fails with a
*connect* timeout — the phone is answering no SYN at all, so its other address
will not answer either — which caps a failed attempt at 8 s rather than 15 s.
Other failures (refused, unreachable, protocol) do fall through to the next
candidate.

Latency when it works is a wash: direct median 0.26 s against usbmux 0.27 s, and
direct's maximum was lower. The direct path does two TCP connects and two TLS
handshakes and still matches libimobiledevice, because libimobiledevice is doing
the same work through a socket relay.

### 12.8 Failure modes seen on the wire

* `Timed out after 8.0 s during connect <ip>:62078` — the phone is asleep or off
  the air. By far the most common failure. Transient.
* `I/O failed during IORegistry header: SSL error 1: … unexpected eof while
  reading` — the lockdown session, the TLS upgrade, `StartService` and the
  service-port TLS handshake all succeeded, and then diagnostics_relay closed the
  connection instead of answering. Seen twice in ~60 attempts, always with the
  phone half-awake, and it succeeds on the immediate retry. This is the same
  ~1-in-14 failure rate the lead saw with pymobiledevice3, so it is the device's
  behaviour and not ours. Transient; the retry policy covers it.
* `usbmuxd has no pair record for <udid>` — the only permanent failure
  (`DirectLockdownError.isTransient == false`). Pair the device.

Every error carries the protocol step it failed at (`DirectLockdownError.step`),
which is what made the two above diagnosable in the first place.

### 12.9 The lead worth following: lockdown `GetValue` outlives diagnostics_relay

The "unexpected eof" failure above is not the phone being unreachable — it gets
through `QueryType`, `StartSession`, the TLS upgrade and `StartService`, and only
then does the relay hang up. So lockdownd is alive while the diagnostics service
refuses. `DirectLockdownClient.lockdownValue` (CLI: `tandemctl lockdown`) stops
one step earlier and asks lockdownd itself, with no service involved.

Sampled every ~9 s for 4 minutes, all three against the same phone at the same
moment (13:24–13:28, phone at 100 % on a charger, screen off):

| path | succeeded |
| --- | --- |
| `tandemctl lockdown` (direct `GetValue`, domain `com.apple.mobile.battery`) | **9 / 14** |
| `tandemctl once --direct-only` (direct IORegistry via diagnostics_relay) | 4 / 14 |
| `idevice_id -n` (usbmuxd sees the device at all) | 4 / 14 |

Five of the fourteen samples had `GetValue` returning a battery reading at the
exact moment both the relay read and usbmuxd were failing, and `GetValue`
latency in those windows ran 0.1–7.1 s (the long ones are the phone waking).

`com.apple.mobile.battery` carries only `BatteryCurrentCapacity` (percent) and
`BatteryIsCharging` — no mAh, no amperage, no temperature, so it cannot fill a
`BatteryReading` on its own. But **percent + charging is most of what a menu bar
shows**, and it is available more than twice as often as the full read. The
obvious next step is a two-tier phone read: full IORegistry when the relay
answers, `GetValue` as a degraded-but-fresh fallback, with the reading marked as
partial. That is not implemented; only the transport for it is.
**(It is implemented now — see §13.)**


## 13. Two tiers, one race — the read as it now works

§12.9 ended with a lead: lockdown's `GetValue` on domain
`com.apple.mobile.battery` answered 9/14 in windows where the diagnostics_relay
read managed 4/14 and usbmuxd saw the phone 4/14. This section is that lead
implemented, plus the fix for what it cost.

### 13.1 The two tiers

| tier | wire | fields | when |
| --- | --- | --- | --- |
| **full** | diagnostics_relay `IORegistry AppleSmartBattery` | everything | first choice |
| **partial** | lockdown `GetValue`, domain `com.apple.mobile.battery` | `BatteryCurrentCapacity`, `BatteryIsCharging`, `ExternalConnected`, `FullyCharged` | only when a full read failed *reachably* |

Both tiers exist on both transports:

* direct-by-IP — `DirectLockdownClient.readBattery` and
  `.readBatteryDomain` (which is `lockdownValue` + `BatteryPlistParser.parseBatteryDomain`).
* usbmuxd — `PhoneBatterySource.readViaUSBMuxOnce` and `.readPartialViaUSBMux`,
  the latter being `lockdownd_get_value(client, "com.apple.mobile.battery",
  NULL, &plist)` with no service started at all.

**"Reachably" is the whole trick.** The degraded tier is worth a second dial
only in the state §12.8 describes: handshake, session TLS and `StartService` all
succeeded and only the relay hung up. If the failure was a *connect* timeout the
radio is off, and `GetValue` will fare no better — dialling twice would just
double an already expensive failure. `PhoneReadRace.suggestsPartialTier` is that
classifier, and it works off `MonitorError`, so:

* `relayRefused` (`serviceFailed`, `queryFailed`, `emptyResponse`, `ioFailed`,
  `tlsFailed`, `protocolError`, `lockdownRefused`) → try the partial tier
* `unreachable` (connect timeout, connect refused), `noDevice`, `notPaired` → do not

### 13.2 The rule for a partial reading

`BatteryReading.isPartial` (default `false`, decodes as `false` when the key is
absent, so old snapshots still load) means:

> **`percent`, `isCharging`, `externalConnected` and `fullyCharged` are current.
> Every other numeric field is `0` and every optional is `nil` because it is
> *unknown*, not because it is zero. Never render mAh, mV, mA, watts, adapter,
> temperature, cycle count or any ETA from a partial reading.**

Three places enforce it:

* `ChargeEstimator.ingest` **refuses** a partial reading: it does not touch the
  EMA and returns an estimate with no ETA and no watts. The battery domain does
  not report current, so one such sample at α = 0.3 would drag a 3000 mA EMA
  down to 2100 mA for no reason at all.
* `TandemMonitor` merges instead of replacing. `BatteryReading.updated(withPartial:)`
  takes the four live fields onto the last **full** reading and keeps that
  reading's watts, adapter, temperature and gas-gauge minutes; the previous
  `DeviceStatus`'s `etaTo80` / `timeToEmpty` / `chargingWatts` are carried
  across unchanged. If the plug state flipped since the last full read those
  three are dropped instead — the percent is still good, the ETA is not.
* `DeviceStatus.detailAge: TimeInterval?` is the seconds since the last full
  reading, recomputed on every `snapshot()`. It is `nil` when everything on show
  is as fresh as `lastSeen`. **Dim the watt/ETA columns when it is set.**
  `StatusFormatter` prints `partial` and `detail 3m ago`.

`TandemSnapshot` gained nothing that breaks an old file: `phoneError`,
`macError`, `DeviceStatus.error` and `DeviceStatus.detailAge` are all optional
and decode as `nil` when absent.

### 13.3 The race, and the blackout cost it removes

A failed direct attempt costs a whole connect timeout (8 s); a failed usbmuxd
attempt costs about a millisecond. Running them one after the other — which is
what `DirectFirstReader` did — meant `tandemctl once` spent **~14 s** in a
blackout to arrive at an answer that was never coming: 8 s of direct connect,
then three usbmuxd attempts 3 s apart.

`PhoneReadRace` runs them **together** instead:

```
tier 1   [ direct full ]  ||  [ usbmux full ]        first success wins, loser cancelled
                    ↓ both failed, and reachably
tier 2   [ direct GetValue ] || [ usbmux GetValue ]  first success wins
```

Budgets, all inside one hard 8 s cap (`PhoneReadRace.budget`):

| usbmuxd sees the phone | full tier | partial tier |
| --- | --- | --- |
| yes | 5 s (both legs, in parallel) | 3 s |
| no | 4 s (direct only; the usbmux leg still runs and fails in ~1 ms) | 4 s |

That is the "when usbmuxd reports no device, still try direct but with a 4 s
connect timeout" rule: there is nothing to race, so the connect is clipped to
leave the degraded tier room inside the same 8 s. `discover()` is a
sub-millisecond read of usbmuxd's list and never touches the device, so asking
which case we are in is free.

Two consequences worth knowing:

* the usbmuxd leg inside the race is `readViaUSBMuxOnce` — **one** attempt, no
  retry ladder. Retrying belongs to `PollingPolicy`, not inside a budget.
  `readViaUSBMux` (retrying) is unchanged and is still what a USB device and
  `--no-direct` use.
* `--direct-only` still reports the real direct failure, because the race throws
  the first error in *leg declaration* order and direct is always declared first.

`PhoneReadRace` takes its legs as closures, so the ordering, the cancellation
and the tier fallback are unit-tested against fake transports with no phone,
no socket and no usbmuxd (`Tests/BatteryCoreTests/TieredReadTests.swift`).

### 13.4 Typed errors

`MonitorError` replaces `String(describing: error)` on the monitor. It is
`Codable`, travels inside `TandemSnapshot` (`phoneError`, `macError`) and on
each `DeviceStatus` (`error`), and every case carries a stable `localizedKey`:

```
tandem.error.noDevice          usbmuxd has nothing and we remember no address
tandem.error.notPaired         no pair record / trust not granted — the only permanent one
tandem.error.unreachable       connect refused or timed out; the radio is off
tandem.error.timedOut          a step past connect ran out of budget
tandem.error.noAddress         --direct-only with an empty address book
tandem.error.relayRefused      lockdown answered, diagnostics_relay did not
tandem.error.malformedResponse the reply would not decode
tandem.error.macReadFailed     IOKit
tandem.error.cancelled
tandem.error.other             detail carries the original description
```

`isTransient` is false only for `.notPaired`. An unknown `kind` in JSON decodes
as `.other`, so adding cases later cannot break an old reader.
`TandemMonitor.lastPhoneError` / `.lastMacError` still exist and still return a
`String?` — now the typed error's `description` — so nothing that already reads
them has to change.

### 13.5 Runtime reconfiguration (what the app asked for)

Everything below is applied **in place**: no monitor is recreated, no reading,
`lastSeen` or EMA is lost. Each one wakes both loops, so a new setting takes
effect now rather than at the end of a 120 s sleep.

```swift
await monitor.update(configuration: newConfiguration)   // the whole struct
await monitor.setPolicy(PollingPolicy(chargingInterval: 30))
await monitor.setPreferNetworkTransport(true)
await monitor.setUseDirectClient(false)
await monitor.requestRefresh()          // poll now; coalesced
await monitor.setBoosted(true)          // 15 s cadence while the popover is open
```

* `update(configuration:)` carries the estimator's EMA across even when
  `estimatorAlpha` changes (`ChargeEstimator.seed(_:)`), and calls
  `setKeepAlive` / `setDirectPolicy` on the phone source only when those
  settings actually changed.
* `requestRefresh()` is **coalesced**: `AsyncSignal` collapses a burst of
  signals into one pending wake, so calling it on every reachability change,
  wake notification and popover open produces one extra poll, not one per call.
* `setBoosted(true)` clips every delay to `Configuration.boostedInterval`
  (15 s) and polls immediately. It **clears itself after
  `Configuration.boostDuration` (2 minutes)** whether or not anyone calls
  `setBoosted(false)`, so a popover left open — or a UI that forgets — cannot
  keep the phone awake indefinitely. `isBoosted` reports the current state.
* `TandemMonitor.configuration` is readable, so the app can round-trip its own
  settings through it.

### 13.6 Measured

`tandemctl probe --tiers --count 6 --interval 15`, iPhone at 99 % off the
charger, screen off, same LAN. usbmuxd could not see the phone at any point in
this run, so every direct connect ran under the 4 s solo budget:

```
tiered read of iPhone (<udid>) over wifi,
  addresses 192.0.2.10, fe80::1%en0
17:29:33 #01 failed     4.003 s  tandem.error.unreachable [Timed out after 4.0 s during connect 192.0.2.10:62078]
17:29:53 #02 failed     4.003 s  tandem.error.unreachable [Timed out after 4.0 s during connect 192.0.2.10:62078]
17:30:09 #03 full ok    0.433 s  99 %  -133 mA  via direct
17:30:25 #04 full ok    0.405 s  99 %  -115 mA  via direct
17:30:41 #05 full ok    0.365 s  99 %  -78 mA   via direct
17:31:01 #06 failed     4.003 s  tandem.error.unreachable [Timed out after 4.0 s during connect 192.0.2.10:62078]

summary over 6 iterations at 15 s
  full ok    3/6
  partial ok 0/6
  failed     3/6
  latency    median 0.40 s  max 0.43 s
  first full-tier failure: Timed out after 4.0 s during connect 192.0.2.10:62078
```

An earlier 8-iteration run in the same state scored full 2/8, partial 0/8,
failed 6/8, with every failure at 4.00 s.

**The number that matters is the 4.00 s.** Before this change the same blackout
iteration cost ~14 s: 8 s of direct connect, then three usbmuxd attempts 3 s
apart. The failure is now one connect timeout, not a connect timeout plus a
retry ladder, and the worst case with usbmuxd *visible* is 5 s (raced) + 3 s
(degraded tier) = the 8 s cap.

`partial ok 0/6` here is the classifier working, not the tier failing: every
failure above was a connect timeout, which means the radio was off, so the
degraded tier was correctly not dialled. It does fire when the phone *is*
answering — this `once`, taken between probe runs, is the degraded tier winning
live:

```
$ tandemctl once
took 0.705 s
MacBook Pro  90 %  plugged  0.0 W
iPhone  99 %  discharging  wifi  partial
```

No watts, no ETA and no `detail … ago` on that line: it was a single `once`, so
this process had never taken a full reading and there was no detail basis to be
old. Under `watch` or in the app — where a full reading precedes it — the same
line reads `… 99 %  discharging  −1.4 W  wifi  partial  detail 3m ago`.

And a fully healthy `once` from the same session:

```
$ tandemctl once
took 0.462 s
MacBook Pro  55 %  discharging  −10.9 W  3:49 left
iPhone  100 %  charging  0.8 W (15 W adapter)  wifi
```

### 13.7 What is still open

* The partial tier has been observed winning live exactly once (the `once`
  above), and never inside a `probe --tiers` run, so there is **no rate for it
  yet** — §12.9's 9/14-vs-4/14 sampling is still the only quantitative evidence.
  A longer capture in the half-awake state is the obvious follow-up. The
  ordering, cancellation and classifier are covered by unit tests against fake
  transports.
* A partial reading taken with no full reading behind it has no watts, no
  temperature and no ETA, and `StatusFormatter` omits those columns entirely
  rather than printing `0.0 W`. A UI must do the same: gate every detail column
  on `detailAge != nil || !reading.isPartial`, never on the value being non-zero.
* The degraded tier is iPhone-only. There is no Mac equivalent and none is
  needed: the Mac read is an in-process IOKit call.
* `keepPhoneSessionAlive` and the race do not interact: a kept-alive relay
  session is used by the usbmuxd leg exactly as before. At the 60/120 s cadence
  §5 still recommends leaving it off.


## 14. Energy policy — polling only as often as somebody is looking

The phone poll is the only expensive thing this package does. A Mac read is an
`IORegistryEntryCreateCFProperties` call in-process; a phone read opens a TCP
connection and a TLS session, which wakes `lockdownd` on the phone and its
radio with it (§4, §12). At the old fixed 60 s charging / 120 s discharging
cadence that is roughly **1400 phone requests a day**, whether or not anybody
has looked at the readout since breakfast. The target here is ~300.

### 14.1 `ActivityLevel`

```swift
public enum ActivityLevel { case hidden, background, widgetVisible, popoverOpen }
```

Ordered by visibility (`Comparable`), so `max(_:_:)` means "the more visible of
the two", and `pollsPhone` is false only for `.hidden`.

| level | what it means | who sets it |
| --- | --- | --- |
| `.hidden` | display asleep, system asleep, or the screen is locked | the app, from `NSWorkspace` + `com.apple.screenIsLocked` |
| `.background` | the app is running and only the menu-bar label is on screen | the default, and where `tandemctl` stays |
| `.widgetVisible` | a widget asked for a timeline in the last 10 minutes | the widget's own breadcrumb, §14.3 |
| `.popoverOpen` | somebody has the popover open right now | the app, on open/close |

`TandemMonitor.setActivity(_:)` is the setter. **Raising** the level polls
immediately (somebody just started looking); **lowering** it does not — the
sleep already in flight is never longer than the cadence being left, so
closing the popover costs nothing. `.popoverOpen` still clears itself after
`Configuration.boostDuration` (2 minutes) and falls back to the level in force
before it, so a popover that never reports closing cannot hold the phone at
15 s. `setBoosted(_:)` survives as a shim: `true` is `.popoverOpen`, `false` is
"back to what it was".

`.hidden` is not a slower cadence. The phone loop does not discover, does not
connect and does not read at all — it parks on its wake signal, so leaving
`.hidden` reads at once. The Mac loop keeps its event-driven reads plus a
600 s sanity read.

### 14.2 What resets the backoff

The unreachable ladder is now 60 → 120 → 300 → 600 s (§8), capped at 600.
Against §5's flapping that is the right shape — a phone that has been
unreachable for ten minutes is asleep, not momentarily busy — but it would be
the wrong shape if it survived an event, so **any** event resets it to zero:

* Mac plug/unplug (IOKit power-source notification)
* USB attach/detach (`idevice_event_subscribe`)
* **network path change (`NWPathMonitor`)** — new here, and the one that
  matters over Wi-Fi: rejoining a network is exactly when an unreachable phone
  becomes reachable. `TandemMonitor.networkPathChanges()` swallows the first
  callback (the path as it already is) so subscribing is not itself an event.
* wake from sleep, popover open, and any rise in activity level
* `requestRefresh()`

Mechanically: `AsyncSignal.sleep(seconds:)` now returns `Bool` — `true` when a
signal cut the sleep short — and each loop zeroes its failure counter when it
sees one. Nothing polls a "was there an event" flag; the wake *is* the flag.

### 14.3 The widget breadcrumb

There is no API that answers "is my widget on screen". WidgetKit only ever
*asks*, and it only asks a widget somebody has actually placed. So the
extension writes one, on every `getTimeline` (and every non-preview
`getSnapshot`):

```
~/Library/Containers/dev.tandem.app.widget/Data/Documents/widget-activity.json
{"family":"medium","requestedAt":"2026-09-07T18:41:07Z"}
```

Same container trick as `snapshot.json`, in the other direction: the extension
is sandboxed and writes into its own Documents, the app is not sandboxed and
reads the path directly. `WidgetActivityMarker` (Foundation-only, compiled into
both the package and the appex) owns the format, and `marker.isFresh(now:)`
plus `ActivityLevel.floor(marker:now:)` are pure functions with unit tests —
no widget, no container and no clock needed to test the rule.

The app hands the monitor a reader for it
(`setActivityFloorProvider { probe.level() }`), which is consulted **on every
scheduling decision** and raises `.background` to `.widgetVisible` while the
marker is under 10 minutes old. `.hidden` is never raised: a sleeping display
is not showing a widget either. The provider caches for 15 s so two loops
asking twice a second do not stat the file twice a second.

The timeline policy stays `.after(15 min)`, which is what keeps the marker
fresh; the entries inside it changed (§14.5).

### 14.4 Instrumentation

`TandemMonitor.stats` returns `PollStats`: phone requests attempted and
succeeded since launch, broken down by the level they were made at, plus a
Mac-read count and a projected per-day rate.

```
$ tandemctl watch --interval 45 --stats
18:52:31 stats  phone 2/2 ok  over 1m  ~2016/day  level background  [hidden 0, background 2, widgetVisible 0, popoverOpen 0]  mac 2
```

`--stats` prints that line to stderr once a minute; the app logs the same line
hourly under subsystem `dev.tandem`, category `energy`:

```
log show --predicate 'subsystem == "dev.tandem" && category == "energy"' --last 3h
```

### 14.5 Countdowns without polling

`DeviceStatus.etaTo80At: Date?` is the absolute moment `etaTo80` points at,
fixed at read time (`lastSeen + etaTo80`, rounded to the second so a snapshot
round-trips through its own ISO-8601 JSON). `timeTo80(now:)` clamps at zero and
`reached80(now:)` says when the target is met, so nothing renders "0 min" or a
negative.

That is what lets the UI stay live while the phone is left alone:

* the popover wraps its rows in a `TimelineView(.periodic(by: 60))` and passes
  the tick down as `now`;
* the widget returns **one entry a minute for fifteen minutes** instead of one
  entry, all built from the same snapshot — every time-dependent thing on it
  (the countdown, the staleness dimming, the `· 12 min` age) is computed from
  the entry's own date against absolute times in the snapshot.

It also survives the partial-reading merge (§13.2) unchanged: a fresher percent
must not push "80 % in 12 min" twelve minutes further out. Old snapshots have no
`etaTo80At` key and get one reconstructed on decode from `lastSeen + etaTo80`.

### 14.6 Reload budget

`WidgetCenter.reloadAllTimelines()` is a cross-process round trip, so the app
gates it twice: at most one per 30 s **and** only when
`WidgetBridge.materiallyChanged(from:to:)` says the widget would draw something
different — percent, charging/plugged/full state, a watt or more of power,
adapter watts, or a device appearing or disappearing. A drifting ETA no longer
counts, because the extension now counts down by itself. The menu-bar label is
rasterised (`ImageRenderer`) only when `MenuBarLabelState` — two percents and
two charging flags — actually changes.

### 14.7 What this is worth

At `.background` on battery the phone is polled every 300 s (288/day) and at
`.hidden` not at all, against 720–1440/day before. A day with the display
asleep for 8 hours, the menu bar alone for most of the rest, a widget on the
desktop for a couple of hours and a few popovers lands near the ~300 target;
the exact number is whatever `--stats` says on the day, which is why it is
measured rather than argued about.

The costs, stated plainly: a phone unplugged while the screen is locked is not
noticed until the screen comes back (the marker cannot help — `.hidden` wins),
and a `.background` phone reading can be five minutes old when the popover
opens. Opening the popover polls immediately, so the stale number is on screen
for one read at most.


## 15. History store — accumulating what neither OS will tell us

Neither macOS nor iOS exposes any battery history over the wire. Health and
cycle count arrive in *every* full reading (`rawMaxMAh`, `designMAh`,
`cycleCount`, `temperatureC`), but "what happened yesterday" does not exist
anywhere until we write it down ourselves. `HistoryStore` is that log: a SQLite
file the app appends to on every poll, and the only possible source for a
summary view, a last-charge-session line or a 24 h chart.

`Sources/BatteryCore/History/` is **Foundation plus `import SQLite3` and nothing
else**. No third-party package, no Homebrew dylib, nothing to bundle — because
the widget extension has to open the same file, and an extension cannot drag the
libimobiledevice chain along with it.

### 15.1 Schema

`meta(key, value)` carries `version` (currently **4**, `HistoryStore.schemaVersion`)
and `last_prune`. Migration is a straight walk in `HistoryStore.migrate`,
each step wrapped in one transaction:

* v0 → v1 (`createV1`) creates `readings` and its index;
* v1 → v2 (`migrateV1toV2`) adds `devices` and `sessions`;
* v2 → v3 (`migrateV2toV3`) adds `markers` — sleep/wake, §15.7;
* v3 → v4 (`migrateV3toV4`) is a plain `ALTER TABLE readings ADD COLUMN
  system_load_w REAL`, for the summary window's sparkline of what the machine
  itself was drawing (`PowerTelemetryData.SystemLoad`) at each reading.

A file newer than the running build is left alone; every column added since v1
is nullable, so an old reader still works.

```sql
readings(ts REAL, device TEXT, percent INT, is_charging INT, external INT,
         fully_charged INT, watts REAL, adapter_watts INT, raw_current_mah INT,
         raw_max_mah INT, design_mah INT, cycle_count INT, temperature_c REAL,
         is_partial INT, transport TEXT, system_load_w REAL)  -- system_load_w: v4
CREATE INDEX idx_readings_device_ts ON readings (device, ts);

devices(id TEXT PRIMARY KEY, kind TEXT, name TEXT, last_seen REAL)

sessions(device TEXT, start REAL, end REAL, from_percent INT, to_percent INT,
         peak_watts REAL, average_watts REAL, adapter_watts INT,
         reached_80_at REAL, energy_wh REAL, PRIMARY KEY (device, start))

markers(ts REAL, kind TEXT, PRIMARY KEY (ts, kind))              -- v3
CREATE INDEX idx_markers_ts ON markers (ts);
```

`device` is `BatteryReading.deviceID` — the Mac's hardware id, the phone's UDID —
so swapping phones does not merge two histories. `devices` exists so
`--device iphone` resolves to an id and so the summary can carry a name without
opening `snapshot.json`. `markers` is not per-device on purpose — it is *this
Mac* that sleeps, and while it does neither battery is read, so one marker
covers every device in the file; `kind` is `sleep` or `wake`
(`SleepMarker.Kind`), and `HistoryStore.recordSleep(at:)`/`recordWake(at:)`
write them with `INSERT OR REPLACE` so a duplicated notification costs
nothing. `recordWake(at:)` also re-derives sessions for every device that was
on external power when it went quiet, which is what bridges the sleep gap —
see §15.7.

`ts` is a Unix timestamp as `REAL`. **Every nullable column means *unknown*,
never zero**, which is the same rule §13.2 imposes on a partial reading: a row
built from the degraded tier has `percent`, `is_charging`, `external` and
`fully_charged` and NULL everywhere else. `HistoryReading(status:)` enforces it
by storing a detail only when it is non-zero.

Journal mode is **WAL** with `synchronous=NORMAL`, so the widget reading the file
never blocks the app writing it, and a crash mid-write cannot tear a row. The
`-wal` and `-shm` sidecars live next to the database; copy or delete all three
together.

### 15.2 The skip rule — why an idle week is not a million rows

`record(_ snapshot:)` writes **one row per device present**, and skips one when

* nothing material changed since that device's previous row — same `percent`,
  `isCharging`, `externalConnected`, `fullyCharged`, and watts within **0.5 W** —
  **and**
* less than **10 minutes** (`idleInterval`) have passed.

So a change is recorded the instant it is seen, and an unchanged battery still
leaves a heartbeat six times an hour. A laptop sitting at 100 % on a charger all
weekend costs ~860 rows rather than ~2900 at a 60 s cadence, and the chart still
has a point every 15 minutes.

A row whose timestamp is not newer than the newest row for that device is
refused outright, so a late reading cannot corrupt the series.

**Retention is 30 days.** `prune()` deletes older `readings` and any `sessions`
that finished before the cutoff. `record` calls it at most once a day, gated on
`meta.last_prune`, so the common path is one `SELECT` of a string.

### 15.3 Sessions

`ChargeSessionBuilder` is pure — rows in, values out, no database, no clock — and
is where all the rules live:

* a session **starts** at the first reading with `externalConnected` true after
  one where it was false (or at the first reading in the window, if that one is
  already plugged in — the start is then clipped by the window, not observed);
* it **ends** at the last reading that still showed external power, triggered
  either by a reading with `externalConnected` false or by a **gap longer than
  30 minutes** (`maximumGap`). A gap that long means the Mac slept or the phone
  went off the air (§5) and we know nothing about the interval;
* `end == nil` means the session is still running.

Fields: `fromPercent`/`toPercent`, `peakWatts` and `averageWatts` (the arithmetic
mean of the positive samples — use `energyWh` if you want the integral),
`adapterWatts` (the largest rating seen), `reached80At` (first reading at or
above 80 %) and `energyWh` = `Σ watts · Δt` with every interval clipped to
`maximumGap`.

`sessions` is materialised so the UI never rescans. `record` rebuilds only the
stretch back to the last reading that was *off* external power — a session
cannot span one, so everything before it is settled — which keeps the per-poll
cost bounded regardless of how much history has piled up.
`rebuildSessions(device:)` does the full 30 days when you want it.

**`DailyStat`** (last 7 days) is derived the same way: `percentConsumed` and
`percentGained` are the sums of the downward and upward percent steps inside one
day, `cyclesEstimate` is `percentGained / 100`, `minutesOnCharger` sums the
intervals whose earlier reading was plugged in (each clipped to `maximumGap`),
and `averageDrawWatts` is the mean magnitude of the negative samples.
**`screenOnMinutes` is always `nil`** — neither OS tells us, and the field exists
so the UI can render "unknown" rather than quietly invent a number.

### 15.4 The summary JSON

`summary()` builds a `HistorySummary`; `writeSummary(to:)` encodes it
pretty-printed, key-sorted, ISO-8601, `Data.write(.atomic)` — exactly like
`SnapshotStore`, so the widget parses both files the same way.

```jsonc
{
  "generatedAt": "2026-09-07T16:13:17Z",
  "devices": [                       // Mac first, then phone
    {
      "device": "<udid>",
      "kind": "iphone",
      "name": "iPhone",
      "lastSeen": "2026-09-07T16:13:17Z",
      "percent": 28, "isCharging": false,
      "health": { "rawMaxMAh": 4966, "designMAh": 4768,
                  "percent": 100, "fraction": 1.0415 },
      "cycleCount": 14,
      "temperatureC": 28.89,
      "lastSession": { "start": …, "end": …, "fromPercent": 28, "toPercent": 100,
                       "peakWatts": 15.6, "averageWatts": 12.58,
                       "adapterWatts": 45, "reached80At": …, "energyWh": 51.2 },
      "today": { "day": …, "minPercent": 28, "maxPercent": 100,
                 "percentConsumed": 120, "percentGained": 72,
                 "cyclesEstimate": 0.72, "minutesOnCharger": 250,
                 "averageDrawWatts": 1.4, "sampleCount": 145 },
      "week":   [ …up to seven DailyStat, today first… ],
      "series": [ { "t": …, "percent": 28, "isCharging": false }, … ]
    }
  ]
}
```

`health.percent` is **capped at 100** because a fresh pack routinely gauges above
its design figure (the iPhone fixture is 4966 mAh against a 4768 mAh
`NominalChargeCapacity`, i.e. 104 %); `rawMaxMAh`, `designMAh` and the uncapped
`fraction` are all kept so a detail view can show the real numbers. `designMAh`
is `DesignCapacity` where the device reports it and `NominalChargeCapacity`
otherwise — see `BatteryPlistParser` and §6.

`series` is the last 24 h bucketed into at most **96 points** (15-minute
resolution), taking the last reading of each bucket. Bucketing rather than
"every n-th row" keeps the x-axis linear in time, which matters precisely
because the skip rule makes the rows deliberately uneven.

`health`, `cycleCount` and `temperatureC` come from the newest **full** row, so
a phone that has only ever answered on the degraded tier reports them as `null`
rather than as zeroes.

### 15.5 Wiring it into the app

```swift
let history = HistoryStore(url: appGroupContainer.appending(path: "history.sqlite"))

// A process with no other consumer (an agent, tandemctl):
let recorder = HistoryRecorder.attach(to: monitor, store: history)

// An app that already iterates snapshots() for its UI — do this instead,
// because snapshots() starts its own polling loops and you do not want two:
for await snapshot in await monitor.snapshots() {
    render(snapshot)
    await HistoryRecorder.record(snapshot, into: history)   // never throws
}

// Whenever the widget needs refreshing (a session ended, or on a timer):
try await history.writeSummary(to: appGroupContainer.appending(path: "summary.json"))
```

Put `history.sqlite` and `summary.json` in the **App Group container**, next to
`snapshot.json` (§7). The widget should read `summary.json` and not the database
— it is one small file, it is atomic, and it costs the extension no SQLite work
at all. The exact filenames are the app author's call; nothing in BatteryCore
hard-codes them, and `HistoryStore.defaultURL`
(`~/Library/Application Support/Tandem/history.sqlite`) is only the CLI's
default.

`HistoryRecorder.record` swallows storage errors onto stderr on purpose: a full
disk must never take down the poll loop that feeds the menu bar.

### 15.6 CLI

```
tandemctl watch --record                       # append every snapshot to the default store
tandemctl history                              # both devices
tandemctl history --device iphone              # one of them
tandemctl history --device iphone --json       # the summary JSON, verbatim
```

`history` touches no device at all — it reads the SQLite file — so it works with
the phone off the air. A synthetic 24 h of readings renders as:

```
MacBook Pro - mac
  health   97 % (8355 / 8579 mAh)   cycles 33   30.3 °C   now 100 %
  session  07 Sep 16:23 → now  100 % → 100 %  avg 0.4 W  peak 0.4 W  96 W adapter  1.1 Wh
  today    24 %–100 %  used 76 %  gained 90 %  cycles 0.90  charger 7 h 00 min  avg draw 11.3 W  screen-on unknown
  24 h     ▅▆▆▆▆▆▆▆▆▆▆▇▇▇▇▇▇▇▇▇▇██████████████████████▇▇▇▇▇▇▇▇▆▆▆▆▆▆▆▅▅▅▅▅▅▅▄▄▄▄▄▄▄▄▃▃▃▃▃▃▃▃▂▂▂████████████   (96 pts)
           ++++++++++++++++++++++++++++++

iPhone - iphone
  health   100 % (4966 / 4768 mAh)   cycles 14   28.9 °C   now 28 %
  session  07 Sep 13:13 → 17:13  28 % → 100 %  avg 12.6 W  peak 15.6 W  45 W adapter  80 % at 15:53  51.2 Wh
  today    28 %–100 %  used 120 %  gained 72 %  cycles 0.72  charger 4 h 10 min  avg draw 1.4 W  screen-on unknown
  24 h     ███████▇▇▇▇▇▇▇▇▇▇▇▇▆▆▆▆▆▆▆▆▆▆▆▆▅▅▅▅▅▅▅▅▅▅▅▅▄▄▄▄▄▄▄▄▄▄▄▄▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▄▄▄▅▅▅▆▆▇▇▇████▃▃▃▃▃▃▃▃   (96 pts)
                                                                                  +++++++++++++++++
```

The sparkline is eight block glyphs over the full 0–100 % range — a battery that
never left 70–80 % renders flat, which is the honest picture — and the `+` line
underneath marks the points that were charging.

### 15.7 What is open

* ~~Sessions carry no "charged while asleep" notion.~~ Fixed: `markers`
  (v3, §15.1) records `NSWorkspace.willSleepNotification` /
  `didWakeNotification` as `recordSleep(at:)` / `recordWake(at:)`, and
  `ChargeSessionBuilder.sessions(from:device:markers:)` treats a gap bracketed
  by a sleep/wake pair as one uninterrupted session rather than splitting it —
  see `SleepMarkerTests.swift`. A gap with no bracketing markers (the app was
  simply not running, rather than the Mac asleep) still splits as before.
* `averageWatts` is a plain mean of the samples, not time-weighted; with the
  skip rule making samples uneven, `energyWh / duration` is the more defensible
  figure and the UI should prefer it for anything quantitative.
* Nothing vacuums the database. Thirty days of two devices is on the order of a
  megabyte, and SQLite reuses freed pages, so the file plateaus rather than
  grows without bound — but a long-running install will never shrink either.
* The store has no cross-process write lock beyond SQLite's own. Two writers
  (the app and `tandemctl watch --record`) are safe but will interleave rows;
  the 5 s busy timeout covers the contention.


## 16. Resync, and the 80 % milestone

Two small public additions, both driven by the menu-bar app.

### 16.1 `TandemMonitor.resync()`

`requestRefresh()` only asks the loops to poll sooner. It keeps dialling the
address on file, keeps a kept-alive relay session open, and stays on whatever
rung of the unreachable ladder (§14.2) it had reached — the right default, and
the wrong answer for a phone that has changed network, been re-paired, or
simply stopped answering the address we remember. That was the menu's "Resync"
until now, and it is why the plan's §6 asked for the address cache to be
"вывести наружу монитора".

`resync()` does, in this order:

1. `PhoneAddressBook.forgetAll()` — every remembered address, gone;
2. `PhoneBatterySource.closeAllSessions()` — any kept-alive lockdown /
   diagnostics_relay socket, closed;
3. `phoneFailures = 0` and the loop's cached `PhoneDevice` dropped, so the
   backoff starts again at the bottom and the next loop turn re-resolves;
4. `PhoneBatterySource.rediscover()` — usbmuxd's device list first (2 × 1 s
   rather than the default 3 × 3 s, because somebody is watching a menu item),
   and with it `refreshFromUSBMux`, which is where `NeighborTable` promotes an
   IPv4 over the Bonjour link-local. Only if usbmuxd stays blind does it fall
   back to the address book;
5. one read over whatever discovery found, applied and published.

**The order is the feature.** Forgetting *before* discovery is what makes the
next read go through usbmuxd and the neighbour table instead of straight back
to the direct client and the address that has stopped answering; only once
discovery has written a fresh entry does `readTiered` have anything to dial.
`ResyncSequence` owns that ordering and takes every step as a closure — the
same trick as `PhoneReadRace` (§13.3) — so it is unit-tested against fakes with
no usbmuxd, no socket and no phone (`Tests/BatteryCoreTests/ResyncTests.swift`).

It returns `ResyncOutcome`, which separates `discovered` ("something named a
device") from `found` ("a reading came back") because in a blackout those come
apart, and carries `summary` for one line of `os_log`. Measured on a healthy
LAN, with a deliberately stale address on file:

```
resync  found  iPhone  wifi  81 %  forgot 1 address(es)  0.55 s
```

The app's menu item shows "Resyncing…" while it runs, capped at 10 s
independently of the read, and the read `resync()` takes *is* the immediate
poll: the loops are woken without the urgent flag afterwards, so the phone is
not dialled twice in a row.

### 16.2 `ChargeMilestone`

The "iPhone reached 80 %" notification's whole decision, as a pure state
machine over the snapshot stream — no `UNUserNotificationCenter`, no clock of
its own, no UI, so it is testable in the package
(`Tests/BatteryCoreTests/ChargeMilestoneTests.swift`) rather than in an app
target that has no tests.

* fires when the percent crosses **from < 80 to ≥ 80 while `isCharging`**;
* **once per charging session** — the latch is released only when
  `externalConnected` turns false, i.e. the cable actually comes out;
* never on the first sample it sees, because a crossing needs a predecessor: a
  phone already at 90 % when the app launches is not news;
* a `nil` status is a missed poll, not an unplug.

`elapsed` is time since the session started, and the session start is either
*observed* (we watched `externalConnected` go true) or *assumed* (the first
sample was already on the charger — the app launched into a charge already
running). Only an assumed start may be corrected, by
`seedSessionStart(_:)`, and only backwards; the app feeds it the open session's
`start` from `HistoryStore.sessions` once per session. Everything unknown stays
`nil` all the way to the notification body, which then omits that half rather
than printing a zero — the same rule as §13.2's partial readings.


## 17. tandemctl subcommands

`Options.Command` (`Sources/tandemctl/main.swift`) as actually implemented;
`tandemctl --help` prints the same table with full flag lists.

| subcommand | what it does |
| --- | --- |
| `once` | one reading from each device, printed or written with `--out`; exits 1 if neither device answered |
| `watch` | streams `monitor.snapshots()`; `--stats` logs `PollStats` once a minute (§14.4), `--record` appends every snapshot to the local `HistoryStore` |
| `history` | reads the local store only, no device touched — health, last session, today's stats, a 24 h sparkline (§15.6); `--device mac\|iphone`, `--json` for the raw `HistorySummary` |
| `dump` | raw plist for one IORegistry/lockdown entry to stdout (`--entry`, default `AppleSmartBattery`) |
| `probe` | repeated timed reads of the phone, one line per attempt; `--compare` races the direct client against usbmuxd (§12.7), `--tiers` reports which tier of `PhoneBatterySource.read` answered each time (§13.6) |
| `addresses` | what `PhoneAddressBook` has on file for the phone: host, alternates, last seen, live vs. remembered |
| `lockdown` | one direct lockdown `GetValue`, no diagnostics_relay — a protocol-step-earlier diagnostic (`--domain`, `--key`, `--host`) |
| `help` | prints usage (also the default for an unrecognised subcommand or `--help`/`-h`) |

Flags that are not subcommand-specific: `--json`, `--network`/`-n` (force
Wi-Fi lookup), `--udid`/`-u`, `--keep-alive`, `--direct-only`/`--no-direct`,
`--host`, `--interval`, `--count`. See the "OPTIONS" block in `printUsage()`
for which subcommand honours which.
