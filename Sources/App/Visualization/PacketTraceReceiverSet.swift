// PacketTraceReceiverSet — receiver roster accumulation for PacketTraceBuilder.
// Keeps positioned receivers for drawing, unpositioned receivers for the legend, and
// the per-receiver router anchor used by the all-receivers fan-out overlay.

import Domain

struct PacketTraceReceiverSet {
    private var positionedByID: [Int64: TraceReceiver] = [:]
    private var unpositionedByID: [Int64: UnpositionedReceiver] = [:]
    private var edgesBuilt: Set<Int64> = []

    mutating func markEdgesBuilt(for reception: PacketReception) -> Bool {
        guard let gateway = reception.gatewayNode else { return false }
        return edgesBuilt.insert(gateway).inserted
    }

    func positionedGateway(_ reception: PacketReception, _ positions: [Int64: GeoPoint]) -> GeoPoint? {
        reception.gatewayNode.flatMap { positions[$0] }
    }

    mutating func record(
        _ nodeID: Int64,
        hop: Int,
        kind: TraceReceiver.Kind,
        _ positions: [Int64: GeoPoint],
        heardFrom: PacketReceiverAnchor? = nil,
        force: Bool = false
    ) {
        if let position = positions[nodeID] {
            let receiver = TraceReceiver(
                nodeID: nodeID,
                position: position,
                hop: hop,
                kind: kind,
                heardFromNodeID: heardFrom?.nodeID,
                heardFromPosition: heardFrom?.position
            )
            recordPositioned(receiver, force: force)
        } else {
            recordUnpositioned(nodeID, hop: hop, kind: kind, force: force)
        }
    }

    func positioned() -> [TraceReceiver] {
        positionedByID.values.sorted { $0.nodeID < $1.nodeID }
    }

    func unpositioned() -> [UnpositionedReceiver] {
        unpositionedByID.values.sorted { $0.nodeID < $1.nodeID }
    }

    private mutating func recordPositioned(_ receiver: TraceReceiver, force: Bool) {
        let keepExisting = positionedByID[receiver.nodeID].map {
            !force && shouldKeep(existing: $0, over: receiver)
        } ?? false
        if keepExisting {
            return
        }
        positionedByID[receiver.nodeID] = receiver
    }

    private mutating func recordUnpositioned(
        _ nodeID: Int64,
        hop: Int,
        kind: TraceReceiver.Kind,
        force: Bool
    ) {
        if let existing = unpositionedByID[nodeID], !force, existing.hop <= hop { return }
        unpositionedByID[nodeID] = UnpositionedReceiver(nodeID: nodeID, hop: hop, kind: kind)
    }

    private func shouldKeep(
        existing: TraceReceiver,
        over receiver: TraceReceiver
    ) -> Bool {
        if existing.hop < receiver.hop { return true }
        if existing.hop > receiver.hop { return false }
        if priority(existing.kind) > priority(receiver.kind) { return true }
        if priority(existing.kind) < priority(receiver.kind) { return false }
        return existing.heardFromPosition != nil || receiver.heardFromPosition == nil
    }

    private func priority(_ kind: TraceReceiver.Kind) -> Int {
        switch kind {
        case .gateway: 3
        case .destination: 2
        case .relay: 1
        }
    }
}
