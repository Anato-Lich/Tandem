# AirPods in Tandem

Design canvas: https://claude.ai/artifact/6gg4kMqmxJuWmYRTCwuREe (approved 2026-11-12).

- [x] 1. Core: `AirPodsStatus` model, `system_profiler` parser, proximity-packet parser, `AirPodsSource` (BLE liveness + charging flags), wired into `TandemSnapshot.airpods`; tests on real bytes.
- [x] 2. Popover: AirPods row — three bars (left / right / case) in the popover's columns; bolt when charging, clock + time when last known.
- [x] 3. Widget, medium: slots picked in Edit Widget (Mac / iPhone / AirPods), default Mac + iPhone; AirPods tile = split outer ring (L/R) + inner ring (case), number line in place of the day strip.
- [x] 4. Widget, small "Accessories": AirPods dual ring (+ Watch later).
- [x] 5. Widget, large: AirPods strip with three bars under the tiles.
- [x] 6. Build, install, check on the real AirPods; release notes.

Out of scope now: Apple Watch (no data source found yet), AirPods history/chart.
