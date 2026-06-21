// BLEAdapter — `MeshTransport` over the Meshtastic CoreBluetooth GATT service.
//
// Meshtastic exposes a single primary service whose characteristics mirror the
// USB-serial protocol:
//
//   Service  6ba1b218-15a8-461f-9fa8-5dcae273eafd
//     FromRadio  2c55e69e-4993-11ed-b878-0242ac120002  (read)   device → host
//     ToRadio    f75c76d2-129e-4dad-a1dd-7866124401e7  (write)  host → device
//     FromNum    ed9da18c-a800-4f66-a670-aa7547e34453  (notify) "data is waiting"
//
// The flow: subscribe to FromNum; whenever it fires, drain FromRadio by repeated
// reads until it returns empty. Each non-empty FromRadio read is one protobuf
// packet (BLE delivers whole packets, so there is no serial-style magic header to
// strip — we emit the bytes as-is with `transport: .ble`).
//
// Scope: this is **best-effort scaffolding** that needs real hardware to run and
// is therefore **untested** in CI. It is written to compile cleanly under Swift 6
// strict concurrency. The design keeps *all* CoreBluetooth interaction on the
// session object, which CoreBluetooth confines to a single private serial
// dispatch queue — that confinement is what serializes access, so the session is
// `@unchecked Sendable` (it holds only the continuation + clock, both already
// `Sendable`, plus CB objects it never touches off the CB queue). The non-Sendable
// `CBPeripheral`/`CBService`/`CBCharacteristic` references therefore never cross a
// concurrency boundary. Pairing/bonding, reconnection, the legacy "Send config"
// handshake (`want_config_id`), MTU negotiation, and packet writes are
// intentionally left as follow-ups for the hardware-in-the-loop phase (SPEC §6
// tier 6).
//
// `topic` and `gatewayID` are always `nil` for BLE: the connected node is the
// receiver, identified by transport.

import CoreBluetooth
import Domain
import Foundation

/// Well-known Meshtastic BLE GATT UUIDs.
///
/// The canonical values are the UUID *strings* (which are `Sendable`); the
/// `…UUID` accessors mint a fresh `CBUUID` each call. `CBUUID` is reference-typed
/// and not `Sendable`, so storing one in a `static let` would trip Swift 6 strict
/// concurrency — computing it on demand sidesteps that without any global state.
public enum MeshtasticBLE {
    /// Primary Meshtastic service.
    public static let service = "6ba1b218-15a8-461f-9fa8-5dcae273eafd"
    /// `FromRadio` — read to pull the next queued packet (device → host).
    public static let fromRadio = "2c55e69e-4993-11ed-b878-0242ac120002"
    /// `ToRadio` — write to send a packet to the device (host → device).
    public static let toRadio = "f75c76d2-129e-4dad-a1dd-7866124401e7"
    /// `FromNum` — notifies that data is waiting in `FromRadio`.
    public static let fromNum = "ed9da18c-a800-4f66-a670-aa7547e34453"

    /// `CBUUID` for the primary Meshtastic service.
    public static var serviceUUID: CBUUID {
        CBUUID(string: service)
    }

    /// `CBUUID` for the `FromRadio` characteristic.
    public static var fromRadioUUID: CBUUID {
        CBUUID(string: fromRadio)
    }

    /// `CBUUID` for the `ToRadio` characteristic.
    public static var toRadioUUID: CBUUID {
        CBUUID(string: toRadio)
    }

    /// `CBUUID` for the `FromNum` characteristic.
    public static var fromNumUUID: CBUUID {
        CBUUID(string: fromNum)
    }
}

/// Errors raised by the BLE adapter. Typed for precise reporting; the adapter
/// never traps. (Most BLE failures surface asynchronously via the stream simply
/// finishing; these cover the synchronous/static cases.)
public enum BLEError: Error, Equatable, Sendable {
    /// Bluetooth is powered off / unauthorized / unsupported on this host.
    case unavailable(state: String)
    /// No Meshtastic peripheral was found within the scan window.
    case noPeripheralFound
    /// The peripheral disconnected before the service was ready.
    case disconnected
}

/// A `MeshTransport` that streams Meshtastic packets over CoreBluetooth.
///
/// Scaffolding only: it scans for ``MeshtasticBLE/serviceUUID``, connects to the
/// first match, subscribes to `FromNum`, and drains `FromRadio` into the frame
/// stream. It needs hardware to exercise and is not covered by CI tests.
public struct BLEAdapter: MeshTransport {
    /// Clock used to stamp `receivedAt` on emitted frames.
    public let clock: any Clock

    /// - Parameter clock: source of `receivedAt`. The composition root passes the
    ///   system clock.
    public init(clock: any Clock) {
        self.clock = clock
    }

    /// Begin scanning/connecting and stream decoded packets. The stream finishes
    /// when the peripheral disconnects, Bluetooth becomes unavailable, or the
    /// consuming task is cancelled.
    public func frames() -> AsyncStream<InboundFrame> {
        let clock = clock
        return AsyncStream { continuation in
            // The session owns every CoreBluetooth object and runs entirely on
            // CB's private serial queue (passed below), which serializes access.
            let session = Session(clock: clock, continuation: continuation)
            session.start()
            continuation.onTermination = { _ in
                session.stop()
            }
        }
    }
}

extension BLEAdapter {
    /// Drives the CoreBluetooth scan → connect → discover → drain state machine
    /// and yields each `FromRadio` packet into the stream.
    ///
    /// `@unchecked Sendable` is sound here because CoreBluetooth delivers every
    /// delegate callback on the single serial queue handed to `CBCentralManager`,
    /// and all CB method calls are made from within those callbacks (or from
    /// `start`/`stop`, which dispatch onto that same queue). Thus the non-Sendable
    /// CB references are only ever touched on one queue and never escape it. The
    /// captured `continuation` and `clock` are themselves `Sendable`.
    final class Session: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
        private let clock: any Clock
        private let continuation: AsyncStream<InboundFrame>.Continuation
        /// CB's private callback queue; also where `start`/`stop` do their work.
        private let queue = DispatchQueue(label: "org.ansible.meshtrack.ble")

        private var central: CBCentralManager?
        private var peripheral: CBPeripheral?
        private var fromRadio: CBCharacteristic?

        init(clock: any Clock, continuation: AsyncStream<InboundFrame>.Continuation) {
            self.clock = clock
            self.continuation = continuation
        }

        /// Create the central manager (which begins reporting state on `queue`).
        func start() {
            central = CBCentralManager(delegate: self, queue: queue)
        }

        /// Tear down on `queue`: stop scanning, drop any connection, finish stream.
        func stop() {
            queue.async { [self] in
                if let central, let peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
                central?.stopScan()
                continuation.finish()
                central = nil
                peripheral = nil
                fromRadio = nil
            }
        }

        // MARK: CBCentralManagerDelegate

        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            switch central.state {
            case .poweredOn:
                central.scanForPeripherals(withServices: [MeshtasticBLE.serviceUUID])
            default:
                // Powered off / unauthorized / unsupported: nothing to stream.
                continuation.finish()
            }
        }

        func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        ) {
            guard self.peripheral == nil else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }

        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            peripheral.discoverServices([MeshtasticBLE.serviceUUID])
        }

        func centralManager(
            _ central: CBCentralManager,
            didDisconnectPeripheral peripheral: CBPeripheral,
            error: (any Error)?
        ) {
            continuation.finish()
        }

        func centralManager(
            _ central: CBCentralManager,
            didFailToConnect peripheral: CBPeripheral,
            error: (any Error)?
        ) {
            continuation.finish()
        }

        // MARK: CBPeripheralDelegate

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
            guard let service = peripheral.services?.first(where: {
                $0.uuid == MeshtasticBLE.serviceUUID
            }) else {
                continuation.finish()
                return
            }
            peripheral.discoverCharacteristics(
                [MeshtasticBLE.fromRadioUUID, MeshtasticBLE.toRadioUUID, MeshtasticBLE.fromNumUUID],
                for: service
            )
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didDiscoverCharacteristicsFor service: CBService,
            error: (any Error)?
        ) {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case MeshtasticBLE.fromRadioUUID:
                    fromRadio = characteristic
                    peripheral.readValue(for: characteristic) // initial drain
                case MeshtasticBLE.fromNumUUID:
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
        }

        func peripheral(
            _ peripheral: CBPeripheral,
            didUpdateValueFor characteristic: CBCharacteristic,
            error: (any Error)?
        ) {
            switch characteristic.uuid {
            case MeshtasticBLE.fromRadioUUID:
                // A non-empty read is one packet; emit it and read again to keep
                // draining. An empty read means the queue is drained — wait for
                // the next FromNum.
                if let value = characteristic.value, !value.isEmpty {
                    continuation.yield(
                        InboundFrame(
                            transport: .ble,
                            topic: nil,
                            payload: [UInt8](value),
                            receivedAt: clock.now()
                        )
                    )
                    if let fromRadio {
                        peripheral.readValue(for: fromRadio)
                    }
                }
            case MeshtasticBLE.fromNumUUID:
                // "Data waiting" notification: pull from FromRadio.
                if let fromRadio {
                    peripheral.readValue(for: fromRadio)
                }
            default:
                break
            }
        }
    }
}
