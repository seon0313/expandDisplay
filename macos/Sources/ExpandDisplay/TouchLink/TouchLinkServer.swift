import Foundation
import Network

/// §1: TCP 47100, Bonjour `_touchlink._tcp` (TXT v=1, name), LAN peers only.
final class TouchLinkServer {
    private var listener: NWListener?
    var onStatus: ((String) -> Void)?

    func start() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.prohibitedInterfaceTypes = [.cellular]

        guard let port = NWEndpoint.Port(rawValue: TL.port),
              let l = try? NWListener(using: params, on: port) else {
            onStatus?("TouchLink: 포트 \(TL.port)을 열 수 없습니다")
            return
        }
        let name = Host.current().localizedName ?? "Mac"
        l.service = NWListener.Service(name: name, type: TL.serviceType, domain: nil,
                                       txtRecord: NWTXTRecord(["v": "1", "name": name]))
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStatus?("TouchLink: 대기 중 (포트 \(TL.port))")
            case .failed(let e): self?.onStatus?("TouchLink 오류: \(e.localizedDescription)")
            default: break
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        guard case let .hostPort(host, _) = conn.endpoint, Self.isLocal(host) else {
            conn.cancel() // §7: LAN only
            return
        }
        let session = TouchLinkSession(peer: "\(host)", trusted: false,
                                       send: { data in conn.send(content: data, completion: .idempotent) },
                                       close: { conn.cancel() })
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: Self.receive(conn, session)
            case .failed, .cancelled: session.transportClosed()
            default: break
            }
        }
        conn.start(queue: session.queue)
    }

    private static func receive(_ conn: NWConnection, _ session: TouchLinkSession) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
            if let data, !data.isEmpty { session.receive(data) }
            if done || error != nil {
                conn.cancel()
                session.transportClosed()
                return
            }
            receive(conn, session)
        }
    }

    static func isLocal(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a):
            return isLocalV4(a)
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return isLocalV4(v4) }
            if a.isLoopback || a.isLinkLocal || a.isUniqueLocal { return true }
            return false
        default:
            return false
        }
    }

    private static func isLocalV4(_ a: IPv4Address) -> Bool {
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return false }
        return b[0] == 10 || b[0] == 127
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)
    }
}
