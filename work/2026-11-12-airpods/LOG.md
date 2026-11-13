# Log

## 2026-11-12
- Research (agent): macOS bluetoothd hears AirPods BLE proximity-pairing ads even with the lid closed; system_profiler mirrors them without a timestamp.
- Probe: CoreBluetooth sees `4c 00 07 11 06 29 20 0d 4b e4 e4 5b 02 00 00 00 00 43 84 01 00` (case 75, buds 100 charging) every 2–20 s.
- Design approved on the canvas (popover bars, medium slots with dual ring, small accessories, large strip).
- Step 1 (core) done: `AirPodsStatus`, `AirPodsProfile` (system_profiler), `ProximityStatus` (closed-lid packet), `AirPodsSource` (D1–D5), `TandemSnapshot.airpods`, monitor Mac loop, `tandemctl` line. 215 tests pass. Live: `AirPods Pro  L 100 %+  R 100 %+  case 75 %  heard 0 s ago`. Not checked: the app's Bluetooth permission prompt (needs NSBluetoothAlwaysUsageDescription, step 2).
- Steps 2–5 (agents, reviewed): popover AirPods row with three bars (D6), Bluetooth usage string, WidgetBridge reloads on AirPods changes; medium slots via App Intent (D7), AirPods tile with the dual ring, small Accessories widget, large strip; renders checked at real sizes, Mac/iPhone tiles byte-identical to HEAD.
- Step 6: 1.4.0 (build 15) installed in /Applications; snapshot carries live AirPods (lastHeard from a BLE match inside the app); the placed medium widget migrated to the intent and reloads. Build products removed after install (stale appex lesson).
- Not checked: Edit Widget UI, Russian locale on screen, the Bluetooth permission prompt (none appeared in the logs), a real lid-open / in-ear session.

- Released: strict DMG rebuilt and reinstalled, main pushed (39ff63c), tag v1.4.0, GitHub release https://github.com/Anato-Lich/Tandem/releases/tag/v1.4.0 (includes the unreleased 1.3.7 fixes).


## 2026-11-13
- Bug: the Mac froze at 90 % / on adapter for ~14 h (real: 34 % on battery). `sample` showed the Mac loop parked in `AirPodsSource.runProfiler` → `Process.waitUntilExit` with no system_profiler process left — after the Mac slept. Fixed in b36f881: exit via `terminationHandler`, 10 s kill timeout, AirPods in their own loop (D10). 1.4.1 (build 16) installed; snapshot fresh again (Mac 33 %, on battery). Not pushed or released yet.
- Not checked: the timeout path itself (no test — runProfiler hardcodes system_profiler); a real sleep/wake cycle on 1.4.1.

## Открыто
- Apple Watch: no data source yet; the Accessories widget keeps its right column for it.
- L/R byte order in the short packet: confirm when the buds differ.
- Does the short form appear while the AirPods are in use (lid open / in ears)?
