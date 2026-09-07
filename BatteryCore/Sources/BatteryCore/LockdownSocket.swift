import Foundation
import CTandemTLS
#if canImport(Darwin)
import Darwin
#endif

/// A blocking TCP socket that can be upgraded to TLS in place, which is exactly
/// what lockdown's `EnableSessionSSL` requires: the same connection continues,
/// wrapped.
///
/// Everything here blocks. It is only ever used from inside the detached task
/// `DirectLockdownClient` runs its attempts on, never from an actor, and the
/// blocking is bounded three ways: a non-blocking `connect()` + `poll()` for the
/// connect timeout, `SO_RCVTIMEO`/`SO_SNDTIMEO` for every subsequent read and
/// write, and an overall cap enforced by the caller.
final class LockdownSocket {

    private(set) var fd: Int32
    private var tls: OpaquePointer?
    private var tlsContext: OpaquePointer?
    let ioTimeout: TimeInterval

    private init(fd: Int32, ioTimeout: TimeInterval) {
        self.fd = fd
        self.ioTimeout = ioTimeout
    }

    deinit { close() }

    // MARK: - Connecting

    /// Non-blocking `connect()` raced against `poll()`, so a phone that is asleep
    /// fails in `timeout` seconds instead of the kernel's ~75 s default.
    static func connect(
        host: String,
        port: UInt16,
        connectTimeout: TimeInterval,
        ioTimeout: TimeInterval
    ) throws -> LockdownSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        // The host is always a literal we recorded ourselves; no DNS round trip.
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV

        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let list else {
            throw DirectLockdownError.connectFailed(host: host, port: port, code: EINVAL)
        }
        defer { freeaddrinfo(list) }

        var lastErrno: Int32 = EHOSTUNREACH
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let info = candidate {
            defer { candidate = info.pointee.ai_next }
            let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if descriptor < 0 { lastErrno = errno; continue }

            var one: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            do {
                try connectWithTimeout(
                    descriptor,
                    address: info.pointee.ai_addr,
                    length: info.pointee.ai_addrlen,
                    timeout: connectTimeout,
                    host: host,
                    port: port
                )
            } catch let error as DirectLockdownError {
                Darwin.close(descriptor)
                if case .connectFailed(_, _, let code) = error {
                    lastErrno = code
                    continue
                }
                throw error
            }

            let socket = LockdownSocket(fd: descriptor, ioTimeout: ioTimeout)
            socket.applyIOTimeouts()
            return socket
        }
        throw DirectLockdownError.connectFailed(host: host, port: port, code: lastErrno)
    }

    private static func connectWithTimeout(
        _ descriptor: Int32,
        address: UnsafeMutablePointer<sockaddr>?,
        length: socklen_t,
        timeout: TimeInterval,
        host: String,
        port: UInt16
    ) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        let result = Darwin.connect(descriptor, address, length)
        if result != 0 {
            guard errno == EINPROGRESS else {
                throw DirectLockdownError.connectFailed(host: host, port: port, code: errno)
            }
            var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32((timeout * 1000).rounded())
            let ready = withUnsafeMutablePointer(to: &descriptors) { poll($0, 1, milliseconds) }
            if ready == 0 {
                throw DirectLockdownError.timedOut(step: "connect \(host):\(port)", after: timeout)
            }
            if ready < 0 {
                throw DirectLockdownError.connectFailed(host: host, port: port, code: errno)
            }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size)
            if socketError != 0 {
                throw DirectLockdownError.connectFailed(host: host, port: port, code: socketError)
            }
        }
        // Back to blocking; SO_RCVTIMEO/SO_SNDTIMEO bound everything from here.
        _ = fcntl(descriptor, F_SETFL, flags)
    }

    private func applyIOTimeouts() {
        guard ioTimeout > 0 else { return }
        var value = timeval(
            tv_sec: Int(ioTimeout),
            tv_usec: Int32((ioTimeout - Double(Int(ioTimeout))) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    // MARK: - TLS

    /// Wrap this connection in TLS using the pair record's host identity.
    ///
    /// The identity never touches the filesystem: OpenSSL reads both PEMs out of
    /// memory BIOs. See `tandem_tls.c` for the context settings, which are the
    /// ones pymobiledevice3 uses (security level 0, legacy server connect, no
    /// peer verification).
    func startTLS(certificate: Data, privateKey: Data, step: String) throws {
        var error = [CChar](repeating: 0, count: 256)
        let context: OpaquePointer? = certificate.withUnsafeBytes { certificateBytes in
            privateKey.withUnsafeBytes { keyBytes in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    tandem_tls_ctx_new(
                        certificateBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        certificate.count,
                        keyBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        privateKey.count,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
        }
        guard let context else {
            throw DirectLockdownError.tlsFailed(step: step, detail: Self.message(error))
        }

        let connection: OpaquePointer? = error.withUnsafeMutableBufferPointer { errorBuffer in
            tandem_tls_connect(context, fd, errorBuffer.baseAddress, errorBuffer.count)
        }
        guard let connection else {
            tandem_tls_ctx_free(context)
            throw DirectLockdownError.tlsFailed(step: step, detail: Self.message(error))
        }
        tlsContext = context
        tls = connection
    }

    private static func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    var isSecure: Bool { tls != nil }

    // MARK: - Framed messages

    func send(_ message: [String: Any], step: String) throws {
        try writeAll(try LockdownWire.encode(message), step: step)
    }

    func receive(step: String) throws -> [String: Any] {
        let header = try readExactly(4, step: step + " header")
        let length = try LockdownWire.payloadLength(from: header)
        let payload = try readExactly(length, step: step + " payload")
        return try LockdownWire.decode(payload)
    }

    /// Send a request and read the single reply, checking lockdown's `Error` key.
    func request(_ message: [String: Any], step: String) throws -> [String: Any] {
        try send(message, step: step)
        let reply = try receive(step: step)
        if let error = reply["Error"] as? String {
            throw DirectLockdownError.lockdownRefused(request: step, error: error)
        }
        return reply
    }

    // MARK: - Raw I/O

    private func writeAll(_ data: Data, step: String) throws {
        try data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written: Int
                if let tls {
                    var reason: Int32 = 0
                    let n = tandem_tls_write(
                        tls,
                        pointer,
                        Int32(min(remaining, Int(Int32.max))),
                        &reason
                    )
                    if n <= 0 { throw Self.tlsError(reason, step: step, timeout: ioTimeout) }
                    written = Int(n)
                } else {
                    let n = Darwin.send(fd, pointer, remaining, 0)
                    if n <= 0 {
                        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                            throw DirectLockdownError.timedOut(step: step, after: ioTimeout)
                        }
                        throw DirectLockdownError.ioFailed(
                            step: step,
                            detail: n == 0 ? "connection closed" : String(cString: strerror(errno))
                        )
                    }
                    written = n
                }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    private func readExactly(_ count: Int, step: String) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got: Int = try buffer.withUnsafeMutableBytes { bytes in
                let target = bytes.baseAddress!.advanced(by: filled)
                let want = count - filled
                if let tls {
                    var reason: Int32 = 0
                    let n = tandem_tls_read(
                        tls,
                        target,
                        Int32(min(want, Int(Int32.max))),
                        &reason
                    )
                    if n <= 0 { throw Self.tlsError(reason, step: step, timeout: ioTimeout) }
                    return Int(n)
                }
                let n = Darwin.recv(fd, target, want, 0)
                if n <= 0 {
                    if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        throw DirectLockdownError.timedOut(step: step, after: ioTimeout)
                    }
                    throw DirectLockdownError.ioFailed(
                        step: step,
                        detail: n == 0 ? "device closed the connection" : String(cString: strerror(errno))
                    )
                }
                return n
            }
            filled += got
        }
        return Data(buffer)
    }

    /// SSL_ERROR_SYSCALL with EAGAIN is what an `SO_RCVTIMEO` expiry looks like
    /// through OpenSSL, so it is reported as a timeout rather than as noise.
    private static func tlsError(_ reason: Int32, step: String, timeout: TimeInterval) -> DirectLockdownError {
        let sslErrorSyscall: Int32 = 5
        let sslErrorZeroReturn: Int32 = 6
        if reason == sslErrorSyscall && (errno == EAGAIN || errno == EWOULDBLOCK) {
            return .timedOut(step: step, after: timeout)
        }
        if reason == sslErrorZeroReturn {
            return .ioFailed(step: step, detail: "device closed the TLS session")
        }
        var buffer = [CChar](repeating: 0, count: 256)
        buffer.withUnsafeMutableBufferPointer { tandem_tls_error_string($0.baseAddress, $0.count) }
        let detail = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .ioFailed(step: step, detail: "SSL error \(reason): \(detail)")
    }

    // MARK: - Teardown

    func close() {
        if let tls {
            tandem_tls_close(tls)
            self.tls = nil
        }
        if let tlsContext {
            tandem_tls_ctx_free(tlsContext)
            self.tlsContext = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
