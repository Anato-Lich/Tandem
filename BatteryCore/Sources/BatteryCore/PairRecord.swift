import Foundation
import CLibusbmuxd

/// The host half of an iOS pairing, as usbmuxd stores it.
///
/// This is the credential that lets us speak lockdown to the phone without
/// usbmuxd in the loop: `HostCertificate` + `HostPrivateKey` are the client
/// identity for the TLS session, and `HostID` + `SystemBUID` are what
/// `StartSession` is keyed on.
///
/// **Never written to disk by this package.** It is read from usbmuxd's own
/// store (`/var/db/lockdown`, via the usbmuxd socket — no root required),
/// held in memory for the duration of one connection attempt, and dropped.
/// `description` deliberately prints no key material.
public struct PairRecord: Sendable, Equatable, CustomStringConvertible {
    public var hostID: String
    public var systemBUID: String
    /// PEM. The client certificate we present to lockdownd.
    public var hostCertificate: Data
    /// PEM. Its private key.
    public var hostPrivateKey: Data
    /// PEM, informational: the device's own certificate.
    public var deviceCertificate: Data?
    /// PEM, informational: the CA that signed both.
    public var rootCertificate: Data?
    /// Opaque blob some services want in `StartService` so they can run while
    /// the device is locked. diagnostics_relay does not need it.
    public var escrowBag: Data?
    /// The phone's Wi-Fi MAC, as recorded at pairing time. Useful only as a
    /// sanity check that a cached IP still belongs to this phone.
    public var wifiMACAddress: String?

    public init(
        hostID: String,
        systemBUID: String,
        hostCertificate: Data,
        hostPrivateKey: Data,
        deviceCertificate: Data? = nil,
        rootCertificate: Data? = nil,
        escrowBag: Data? = nil,
        wifiMACAddress: String? = nil
    ) {
        self.hostID = hostID
        self.systemBUID = systemBUID
        self.hostCertificate = hostCertificate
        self.hostPrivateKey = hostPrivateKey
        self.deviceCertificate = deviceCertificate
        self.rootCertificate = rootCertificate
        self.escrowBag = escrowBag
        self.wifiMACAddress = wifiMACAddress
    }

    public var description: String {
        "PairRecord(hostID: \(hostID), systemBUID: \(systemBUID), "
            + "certificate: \(hostCertificate.count) B, key: <redacted>)"
    }

    // MARK: - Parsing

    /// Decode the plist usbmuxd hands back.
    ///
    /// The certificate/key values are normally `<data>` (raw PEM bytes) but some
    /// records — and every hand-written test fixture — store them as strings, so
    /// both are accepted.
    public init(plistData: Data) throws {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
        } catch {
            throw DirectLockdownError.malformedPairRecord(
                "not a property list: \(error.localizedDescription)"
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw DirectLockdownError.malformedPairRecord("top level is not a dictionary")
        }
        try self.init(plist: dictionary)
    }

    public init(plist: [String: Any]) throws {
        func data(_ key: String) -> Data? {
            switch plist[key] {
            case let value as Data: return value
            case let value as String: return Data(value.utf8)
            default: return nil
            }
        }
        func text(_ key: String) -> String? {
            switch plist[key] {
            case let value as String: return value
            case let value as Data: return String(data: value, encoding: .utf8)
            default: return nil
            }
        }

        guard let hostID = text("HostID"), !hostID.isEmpty else {
            throw DirectLockdownError.malformedPairRecord("missing HostID")
        }
        guard let systemBUID = text("SystemBUID"), !systemBUID.isEmpty else {
            throw DirectLockdownError.malformedPairRecord("missing SystemBUID")
        }
        guard let certificate = data("HostCertificate"), !certificate.isEmpty else {
            throw DirectLockdownError.malformedPairRecord("missing HostCertificate")
        }
        guard let key = data("HostPrivateKey"), !key.isEmpty else {
            throw DirectLockdownError.malformedPairRecord("missing HostPrivateKey")
        }

        self.init(
            hostID: hostID,
            systemBUID: systemBUID,
            hostCertificate: certificate,
            hostPrivateKey: key,
            deviceCertificate: data("DeviceCertificate"),
            rootCertificate: data("RootCertificate"),
            escrowBag: data("EscrowBag"),
            wifiMACAddress: text("WiFiMACAddress")
        )
    }
}

/// Reads pair records out of the running usbmuxd.
///
/// `usbmuxd_read_pair_record` talks to `/var/run/usbmuxd` as the current user;
/// it needs no privileges and, unlike the device list, it does **not** depend on
/// the phone being visible right now. That is the whole point: during a Bonjour
/// blackout the pair record is still there.
public enum PairRecordStore {

    /// Look up the record for `udid`. Returns the parsed record; nothing is cached.
    public static func read(udid: String) throws -> PairRecord {
        var buffer: UnsafeMutablePointer<CChar>?
        var size: UInt32 = 0
        let status = udid.withCString { identifier in
            usbmuxd_read_pair_record(identifier, &buffer, &size)
        }
        guard status == 0, let buffer else {
            if let buffer { free(buffer) }
            throw DirectLockdownError.noPairRecord(udid: udid, code: Int32(status))
        }
        defer {
            // usbmuxd_read_pair_record allocates with malloc().
            memset_s(buffer, Int(size), 0, Int(size))
            free(buffer)
        }
        guard size > 0 else {
            throw DirectLockdownError.noPairRecord(udid: udid, code: 0)
        }
        return try PairRecord(plistData: Data(bytes: buffer, count: Int(size)))
    }

    /// usbmuxd's own SystemBUID, for the (unusual) case of a record that omits it.
    public static func systemBUID() -> String? {
        var buffer: UnsafeMutablePointer<CChar>?
        guard usbmuxd_read_buid(&buffer) == 0, let buffer else { return nil }
        defer { free(buffer) }
        return String(cString: buffer)
    }
}
