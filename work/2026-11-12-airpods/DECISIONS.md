# Decisions

1. **Numbers come from `system_profiler SPBluetoothDataType -json`, not from BLE packets.** It lists only the user's own paired AirPods, names left/right explicitly and costs ~0.06 s. A BLE proximity packet carries no name or address, so strangers' AirPods nearby would look the same.
2. **BLE (CoreBluetooth scan, Apple mfr data `4c 00 07`) is only a liveness and charging signal.** A short-form packet (`07 11 06 …`, lid closed) whose case/bud levels match the system_profiler values means "heard just now"; its 0x80 bits give charging. Measured 2026-11-12: packets every 2–20 s, no TCC prompt needed for the CLI probe.
3. **Last heard = max(BLE match time, time the system_profiler values last changed).** Open-lid / in-ear packets are encrypted, so a change in the values is the other proof of life.
4. **Order of L/R bytes in the short form is not relied on** (both were 100 % when captured); levels are matched as a multiset.
5. **Scan window 20 s with early exit, run after the Mac's publish in the Mac loop.** Closed-lid adverts come every 2–20 s, a 4 s window missed them; the scan stops at the first matching packet, so it usually costs a few seconds per Mac poll.
