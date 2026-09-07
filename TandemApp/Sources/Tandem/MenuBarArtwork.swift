import SwiftUI
import BatteryCore

/// Everything the menu-bar label draws, and nothing else.
///
/// Two devices, each either absent or a percent plus a charging flag. A poll
/// that changes a watt, a temperature or a timestamp leaves this `==`, and the
/// label is then not re-rasterised at all.
struct MenuBarLabelState: Equatable {

    struct Chip: Equatable {
        var percent: Int
        var isCharging: Bool
    }

    var mac: Chip?
    var phone: Chip?

    init(mac: DeviceStatus?, phone: DeviceStatus?) {
        self.mac = mac.map { Chip(percent: $0.reading.percent, isCharging: $0.reading.isCharging) }
        self.phone = phone.map { Chip(percent: $0.reading.percent, isCharging: $0.reading.isCharging) }
    }
}

/// The actual pixel content, rendered once per snapshot rather than kept
/// live in the status item.
struct MenuBarArtwork: View {
    let mac: MenuBarLabelState.Chip?
    let phone: MenuBarLabelState.Chip?

    var body: some View {
        HStack(spacing: 5) {
            chip(symbol: "laptopcomputer", status: mac, unknownSymbol: nil)
            chip(symbol: "iphone", status: phone, unknownSymbol: "iphone.slash")
        }
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(.black)
        .fixedSize()
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func chip(symbol: String, status: MenuBarLabelState.Chip?, unknownSymbol: String?) -> some View {
        HStack(spacing: 2) {
            if let status {
                Image(systemName: symbol)
                Text("\(status.percent) %")
                    .monospacedDigit()
                if status.isCharging {
                    Image(systemName: "bolt.fill")
                        .imageScale(.small)
                }
            } else {
                Image(systemName: unknownSymbol ?? symbol)
            }
        }
    }
}
