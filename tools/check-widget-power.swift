import Foundation

@main
struct WidgetPowerCheck {
    @MainActor
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fixture = URL(fileURLWithPath: "Fixtures/mac-plugged-not-charging.plist")
        let reading = try BatteryPlistParser.parseMac(Data(contentsOf: fixture), timestamp: now)
        var failures = 0

        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures += 1 }
        }

        func status(input: Double?, load: Double?, external: Bool = true,
                    kind: DeviceKind = .mac) -> DeviceStatus {
            var value = reading
            value.kind = kind
            value.externalConnected = external
            value.systemPowerInW = input
            value.systemLoadW = load
            return DeviceStatus(reading: value, lastSeen: now)
        }

        func changed(_ old: DeviceStatus, _ new: DeviceStatus) -> Bool {
            let phone = old.reading.kind == .iphone
            return WidgetBridge.materiallyChanged(
                from: TandemSnapshot(generatedAt: now, mac: phone ? nil : old, phone: phone ? old : nil),
                to: TandemSnapshot(generatedAt: now, mac: phone ? nil : new, phone: phone ? new : nil)
            )
        }

        let unknown = status(input: nil, load: nil)
        let holding = status(input: 9, load: 9)
        let tile = DevicePresentation(kind: .mac, status: holding, now: now)
        expect(reading.systemPowerInW == 13.307, "парсер различает измерение и номинал адаптера")
        expect(tile.powerText == "9/140W", "виджет показывает текущее потребление рядом с номиналом")
        expect(changed(unknown, holding), "появление измерения обновляет застывшие 140W")
        expect(changed(holding, unknown), "исчезновение измерения обновляет виджет")
        expect(changed(holding, status(input: 11, load: 9)), "изменение входной мощности обновляет виджет")
        expect(!changed(holding, status(input: 9.4, load: 9)), "колебание входной мощности ниже порога не будит виджет")
        expect(changed(holding, status(input: 10, load: 9)), "изменение ровно на порог обновляет виджет")
        expect(!changed(holding, holding), "неизменившееся потребление не будит виджет")

        let battery = status(input: nil, load: 9, external: false)
        let higherLoad = status(input: nil, load: 12, external: false)
        expect(DevicePresentation(kind: .mac, status: higherLoad, now: now).powerText == "−12W",
               "на батарее виджет использует нагрузку системы")
        expect(changed(battery, higherLoad), "изменение нагрузки системы обновляет виджет")
        expect(changed(status(input: nil, load: nil, external: false), battery),
               "появление нагрузки системы обновляет виджет")
        expect(!changed(battery, status(input: nil, load: 9.4, external: false)),
               "колебание нагрузки ниже порога не будит виджет")
        expect(changed(status(input: nil, load: nil, kind: .iphone), status(input: 9, load: nil, kind: .iphone)),
               "входная мощность iPhone проходит тот же фильтр обновлений")

        if failures > 0 { exit(1) }
    }
}
