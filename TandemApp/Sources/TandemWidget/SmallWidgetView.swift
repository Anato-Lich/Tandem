import SwiftUI

/// `systemSmall`: two concentric rings (Mac outside, iPhone inside) with a
/// single orange bolt in the middle whenever *either* device is charging, over
/// two columns of icon + percent + time.
struct SmallWidgetView: View {
    let mac: DevicePresentation
    let phone: DevicePresentation

    private var anyCharging: Bool { mac.isCharging || phone.isCharging }

    var body: some View {
        VStack(spacing: 10) {
            rings
            columns
        }
    }

    private var rings: some View {
        ZStack {
            RingView(percent: mac.percent, color: mac.levelColor, lineWidth: 7)
                .frame(width: 86, height: 86)
                .opacity(mac.dimming)
            RingView(percent: phone.percent, color: phone.levelColor, lineWidth: 7)
                .frame(width: 62, height: 62)
                // Slightly transparent so the two rings read as depth rather
                // than as one thick ring.
                .opacity(0.85 * phone.dimming)
            if anyCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 4) {
            column(mac, alignment: .leading)
            Spacer(minLength: 2)
            column(phone, alignment: .trailing)
        }
    }

    private func column(_ device: DevicePresentation, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: device.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(device.percentText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                if device.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            Text(device.timeLine)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        // Both columns must survive the smallest widget without colliding.
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .opacity(device.dimming)
    }
}
