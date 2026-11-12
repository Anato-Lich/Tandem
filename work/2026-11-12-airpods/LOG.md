# Log

## 2026-11-12
- Research (agent): macOS bluetoothd hears AirPods BLE proximity-pairing ads even with the lid closed; system_profiler mirrors them without a timestamp.
- Probe: CoreBluetooth sees `4c 00 07 11 06 29 20 0d 4b e4 e4 5b 02 00 00 00 00 43 84 01 00` (case 75, buds 100 charging) every 2–20 s.
- Design approved on the canvas (popover bars, medium slots with dual ring, small accessories, large strip).
- Step 1 (core) done: `AirPodsStatus`, `AirPodsProfile` (system_profiler), `ProximityStatus` (closed-lid packet), `AirPodsSource` (D1–D5), `TandemSnapshot.airpods`, monitor Mac loop, `tandemctl` line. 215 tests pass. Live: `AirPods Pro  L 100 %+  R 100 %+  case 75 %  heard 0 s ago`. Not checked: the app's Bluetooth permission prompt (needs NSBluetoothAlwaysUsageDescription, step 2).

## Открыто
- L/R byte order in the short packet: confirm when the buds differ.
- Does the short form appear while the AirPods are in use (lid open / in ears)?
