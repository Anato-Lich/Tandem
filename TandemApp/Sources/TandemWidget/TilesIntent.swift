import AppIntents

/// A device a medium/large tile can show.
enum SlotDevice: String, AppEnum {
    case mac, iphone, airpods

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let caseDisplayRepresentations: [SlotDevice: DisplayRepresentation] = [
        .mac: "Mac",
        .iphone: "iPhone",
        .airpods: "AirPods",
    ]
}

/// Edit Widget: which device each tile shows. The defaults are the layout the
/// widget had before the choice existed, so placed widgets keep their look.
struct TilesIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Devices"

    @Parameter(title: "Left", default: .mac)
    var left: SlotDevice

    @Parameter(title: "Right", default: .iphone)
    var right: SlotDevice
}
