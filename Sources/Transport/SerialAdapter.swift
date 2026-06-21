// SerialAdapter — `MeshTransport` over a USB-serial Meshtastic node.
//
// Opens a `/dev/cu.*` character device with POSIX `termios`, puts it in raw mode
// at 115200 baud (the Meshtastic serial default), and reads bytes on a detached
// task. Raw bytes are decoded by the tested ``SerialFramer``; each completed
// protobuf frame is emitted as `InboundFrame(transport: .serial, …)` stamped with
// the injected `Clock`.
//
// Scope: the port I/O here is deliberately **thin and best-effort** — it does no
// reconnect/backoff, line discipline beyond raw mode, or device discovery, and it
// is NOT exercised in CI (no hardware). All the testable logic lives in
// ``SerialFramer``; this file is the I/O shell behind it. Real-hardware bring-up
// is a later, hardware-in-the-loop phase (SPEC §6 tier 6).
//
// `topic` is always `nil` for serial (topics are an MQTT concept). `gatewayID`
// is `nil`: the locally-attached node *is* the receiver, identified by transport,
// not a gateway USERID.

import Domain
import Foundation

/// Errors raised while opening/configuring the serial port. Typed so the caller
/// (composition root) can report precisely; the adapter never traps.
public enum SerialError: Error, Equatable, Sendable {
    /// `open(2)` on the device path failed. `errnoCode` is the POSIX `errno`.
    case openFailed(path: String, errnoCode: Int32)
    /// The opened descriptor is not a TTY (`isatty` was false).
    case notATTY(path: String)
    /// `tcgetattr`/`tcsetattr` failed while putting the port in raw mode.
    case configureFailed(path: String, errnoCode: Int32)
}

/// A `MeshTransport` that reads framed Meshtastic protobufs from a USB-serial port.
///
/// Construct with the device path (e.g. `/dev/cu.usbserial-0001`) and a `Clock`;
/// call ``frames()`` to start reading. The read loop runs until the device closes
/// or the consuming task is cancelled, at which point the stream finishes and the
/// descriptor is closed.
public struct SerialAdapter: MeshTransport {
    /// The character-device path to open (a `/dev/cu.*` entry on macOS).
    public let devicePath: String
    /// Baud rate to configure. Defaults to Meshtastic's 115200.
    public let baudRate: speed_t
    /// Clock used to stamp `receivedAt` on emitted frames.
    public let clock: any Clock

    /// - Parameters:
    ///   - devicePath: the `/dev/cu.*` device to open.
    ///   - baudRate: line speed; defaults to `115200`.
    ///   - clock: source of `receivedAt`. The composition root passes the system
    ///     clock; tests/replay can pass an injected one.
    public init(devicePath: String, baudRate: speed_t = speed_t(115_200), clock: any Clock) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.clock = clock
    }

    /// Open the port and stream decoded frames until it closes or the task is
    /// cancelled. If the port can't be opened/configured the stream finishes
    /// immediately (best-effort; see ``open()`` to surface the typed error).
    public func frames() -> AsyncStream<InboundFrame> {
        let devicePath = devicePath
        let baudRate = baudRate
        let clock = clock
        return AsyncStream { continuation in
            let descriptor: Int32
            do {
                descriptor = try Self.openRaw(path: devicePath, baudRate: baudRate)
            } catch {
                // Best-effort: no device → empty stream. Use `open()` directly to
                // get the typed error instead of swallowing it.
                continuation.finish()
                return
            }

            let task = Task.detached {
                var framer = SerialFramer()
                var scratch = [UInt8](repeating: 0, count: 4096)
                while !Task.isCancelled {
                    let count = scratch.withUnsafeMutableBytes { raw in
                        read(descriptor, raw.baseAddress, raw.count)
                    }
                    if count > 0 {
                        let output = framer.push(scratch[0 ..< count])
                        for payload in output.frames {
                            continuation.yield(
                                InboundFrame(
                                    transport: .serial,
                                    topic: nil,
                                    payload: payload,
                                    receivedAt: clock.now()
                                )
                            )
                        }
                    } else if count == 0 {
                        break // EOF: device closed.
                    } else if errno == EINTR {
                        continue // Interrupted syscall: retry.
                    } else {
                        break // Real read error: stop.
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                close(descriptor)
            }
        }
    }

    /// Open and configure the port, surfacing a typed ``SerialError`` on failure.
    /// Callers that want to react to open/config errors (rather than an empty
    /// stream) can call this first; ownership of the returned descriptor passes to
    /// the caller, who must `close` it.
    public func open() throws -> Int32 {
        try Self.openRaw(path: devicePath, baudRate: baudRate)
    }

    /// Open `path` non-blocking, verify it's a TTY, and put it in 8N1 raw mode at
    /// `baudRate`. Returns the descriptor on success.
    private static func openRaw(path: String, baudRate: speed_t) throws -> Int32 {
        let descriptor = path.withCString { cPath in
            // O_NOCTTY: don't let the TTY become our controlling terminal.
            // O_NONBLOCK: open() must not block waiting on DCD.
            Foundation.open(cPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw SerialError.openFailed(path: path, errnoCode: errno)
        }

        guard isatty(descriptor) == 1 else {
            close(descriptor)
            throw SerialError.notATTY(path: path)
        }

        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            let code = errno
            close(descriptor)
            throw SerialError.configureFailed(path: path, errnoCode: code)
        }

        // Raw mode: clear input/output/local/line-discipline processing so bytes
        // pass through untouched (`cfmakeraw` equivalent), then 8N1.
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CREAD | CLOCAL) // enable receiver, ignore modem lines
        settings.c_cflag &= ~tcflag_t(PARENB) // no parity
        settings.c_cflag &= ~tcflag_t(CSTOPB) // one stop bit
        settings.c_cflag &= ~tcflag_t(CSIZE)
        settings.c_cflag |= tcflag_t(CS8) // 8 data bits

        cfsetispeed(&settings, baudRate)
        cfsetospeed(&settings, baudRate)

        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            let code = errno
            close(descriptor)
            throw SerialError.configureFailed(path: path, errnoCode: code)
        }

        return descriptor
    }
}
