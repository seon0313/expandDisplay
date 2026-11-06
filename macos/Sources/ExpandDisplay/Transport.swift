import Foundation
import Network
import VirtualDisplayBridge

/// A byte pipe to the phone: TCP over Wi-Fi, or USB accessory bulk endpoints.
protocol Transport: AnyObject {
    var displayName: String { get }
    var kind: String { get }
    /// Callbacks must be delivered on `queue`.
    func start(queue: DispatchQueue, onReceive: @escaping (Data) -> Void, onClose: @escaping () -> Void)
    /// Completion is called on the transport's queue once the data has been handed off.
    func send(_ data: Data, completion: @escaping () -> Void)
    func cancel()
}

final class TCPTransport: Transport {
    let connection: NWConnection
    private var queue: DispatchQueue?
    private var onReceive: ((Data) -> Void)?
    private var onClose: (() -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    var kind: String { "Wi-Fi" }
    var displayName: String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    func start(queue: DispatchQueue, onReceive: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.queue = queue
        self.onReceive = onReceive
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive()
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if isComplete || error != nil {
                self.connection.cancel()
                self.onClose?()
                return
            }
            self.receive()
        }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    func cancel() { connection.cancel() }
}

final class USBTransport: Transport {
    let connection: EDAccessoryConnection
    private var queue: DispatchQueue = .main

    init(_ connection: EDAccessoryConnection) { self.connection = connection }

    var kind: String { "USB" }
    var displayName: String { connection.deviceName }

    func start(queue: DispatchQueue, onReceive: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.queue = queue
        connection.onData = { data in queue.async { onReceive(data) } }
        connection.onClose = { queue.async { onClose() } }
        connection.startReading()
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        let q = queue
        connection.write(data) { _ in q.async { completion() } }
    }

    func cancel() { connection.close() }
}
