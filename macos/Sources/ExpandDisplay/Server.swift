import Foundation
import Network

/// TCP listener advertised over Bonjour so the phone finds the Mac automatically.
final class Server {
    var onConnection: ((NWConnection) -> Void)?
    var onStateChange: ((String) -> Void)?
    private var listener: NWListener?

    func start() {
        do {
            listener = try makeListener(port: NWEndpoint.Port(rawValue: Proto.defaultPort)!)
        } catch {
            // Fixed port busy — fall back to any port (Bonjour still advertises it).
            listener = try? makeListener(port: .any)
        }
        guard let listener else {
            onStateChange?("서버를 시작할 수 없습니다")
            return
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func makeListener(port: NWEndpoint.Port) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo

        let l = try NWListener(using: params, on: port)
        let name = Host.current().localizedName ?? "Mac"
        l.service = NWListener.Service(name: name, type: Proto.serviceType)
        l.newConnectionHandler = { [weak self] conn in
            self?.onConnection?(conn)
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                let p = l?.port?.rawValue ?? 0
                self?.onStateChange?("연결 대기 중 (포트 \(p))")
            case .failed(let err):
                self?.onStateChange?("서버 오류: \(err.localizedDescription)")
            default:
                break
            }
        }
        return l
    }
}
