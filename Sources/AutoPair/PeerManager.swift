import Foundation
import Network

private struct HandoffMessage: Codable {
    enum Action: String, Codable { case release, released }
    let action: Action
    let addresses: [String]
}

/// Discovers other AutoPair instances over Bonjour and provides the acknowledgment
/// boundary that keeps acquisition from racing the source Mac's release.
final class PeerManager: PeerCoordinating {
    var onReleaseRequest: (([String], @escaping (Bool) -> Void) -> Void)?
    var onPeerCountChanged: ((Int) -> Void)?
    private let serviceType = "_autopair._tcp"
    private let queue = DispatchQueue(label: "com.ericclemmons.AutoPair.network", qos: .utility)
    private let instanceID: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peers: [String: NWEndpoint] = [:] {
        didSet {
            let count = peers.count
            DispatchQueue.main.async { [weak self] in self?.onPeerCountChanged?(count) }
        }
    }

    init() {
        let key = "AutoPairInstanceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            instanceID = existing
        } else {
            instanceID = UUID().uuidString
            UserDefaults.standard.set(instanceID, forKey: key)
        }
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: instanceID, type: serviceType)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { log.error("Peer listener failed: \(error)") }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log.error("Peer listener could not start: \(error)")
        }

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: NWEndpoint] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      name != self.instanceID else { continue }
                found[name] = result.endpoint
            }
            self.peers = found
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { log.error("Peer browser failed: \(error)") }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        peers = [:]
    }

    func requestRelease(of addresses: [String], completion: @escaping (Bool) -> Void) {
        queue.async {
            let endpoints = Array(self.peers.values)
            guard !endpoints.isEmpty else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var allReleased = true
            for endpoint in endpoints {
                group.enter()
                self.requestRelease(of: addresses, from: endpoint) { success in
                    lock.lock()
                    allReleased = allReleased && success
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(allReleased) }
        }
    }

    private func requestRelease(of addresses: [String], from endpoint: NWEndpoint,
                                completion: @escaping (Bool) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let finish = Once { success in
            connection.cancel()
            completion(success)
        }
        queue.asyncAfter(deadline: .now() + 8) { finish.call(false) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.send(HandoffMessage(action: .release, addresses: addresses), on: connection) { sent in
                    guard sent else { finish.call(false); return }
                    self?.receive(on: connection) { message in
                        finish.call(message?.action == .released)
                    }
                }
            case .failed: finish.call(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: connection) { [weak self] message in
                    guard let self, let message, message.action == .release else {
                        connection.cancel()
                        return
                    }
                    DispatchQueue.main.async {
                        guard let handler = self.onReleaseRequest else {
                            connection.cancel()
                            return
                        }
                        handler(message.addresses) { success in
                            guard success else { connection.cancel(); return }
                            self.send(HandoffMessage(action: .released, addresses: message.addresses),
                                      on: connection) { _ in connection.cancel() }
                        }
                    }
                }
            case .failed, .cancelled: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ message: HandoffMessage, on connection: NWConnection,
                      completion: @escaping (Bool) -> Void) {
        guard let payload = try? JSONEncoder().encode(message), payload.count <= 65_536 else {
            completion(false)
            return
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in completion(error == nil) })
    }

    private func receive(on connection: NWConnection,
                         completion: @escaping (HandoffMessage?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { completion(nil); return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length <= 65_536 else { completion(nil); return }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) {
                payload, _, _, _ in
                guard let payload, payload.count == Int(length) else { completion(nil); return }
                completion(try? JSONDecoder().decode(HandoffMessage.self, from: payload))
            }
        }
    }

    deinit { stop() }
}

private final class Once {
    private let lock = NSLock()
    private var completed = false
    private let body: (Bool) -> Void

    init(_ body: @escaping (Bool) -> Void) { self.body = body }

    func call(_ value: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        body(value)
    }
}
