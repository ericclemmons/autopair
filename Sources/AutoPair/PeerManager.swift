import CryptoKit
import Foundation
import Network

struct ComputerInfo: Codable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct TrustedComputer: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    let secret: Data
}

enum ComputerPairingError: LocalizedError {
    case unavailable
    case invalidCode
    case expiredCode
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "That Mac is no longer available. Keep AutoPair open on both Macs and try again."
        case .invalidCode: "The pairing code didn't match. Show a new code on the other Mac and try again."
        case .expiredCode: "The pairing code expired. Show a new code on the other Mac and try again."
        case .connectionFailed: "AutoPair couldn't finish pairing. Check that both Macs are on the same network."
        }
    }
}

private struct PeerMessage: Codable {
    enum Action: String, Codable {
        case pair, paired, release, released, diagnostics, diagnosticsResult
    }
    let action: Action
    let senderID: String
    let senderName: String
    var addresses: [String]? = nil
    var nonce: String? = nil
    var timestamp: Int64? = nil
    var authentication: String? = nil
    var encryptedSecret: String? = nil
    var diagnosticData: String? = nil
    var error: String? = nil
}

enum PeerCrypto {
    static func randomData(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func pairingProof(code: String, senderID: String, nonce: String) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(code.utf8)))
        return Data(HMAC<SHA256>.authenticationCode(
            for: Data("\(senderID)|\(nonce)".utf8), using: key
        )).base64EncodedString()
    }

    static func isValidPairingProof(_ proof: String, code: String,
                                    senderID: String, nonce: String) -> Bool {
        guard let candidate = Data(base64Encoded: proof) else { return false }
        let key = SymmetricKey(data: SHA256.hash(data: Data(code.utf8)))
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate, authenticating: Data("\(senderID)|\(nonce)".utf8), using: key
        )
    }

    static func encrypt(secret: Data, code: String, nonce: String) -> String? {
        let keyData = SHA256.hash(data: Data("AutoPair|\(code)|\(nonce)".utf8))
        guard let sealed = try? AES.GCM.seal(secret, using: SymmetricKey(data: keyData)),
              let combined = sealed.combined else { return nil }
        return combined.base64EncodedString()
    }

    static func decrypt(_ value: String, code: String, nonce: String) -> Data? {
        let keyData = SHA256.hash(data: Data("AutoPair|\(code)|\(nonce)".utf8))
        guard let data = Data(base64Encoded: value),
              let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }

    fileprivate static func signature(action: PeerMessage.Action, senderID: String,
                          addresses: [String], timestamp: Int64, nonce: String,
                          secret: Data) -> String {
        let canonical = [
            action.rawValue, senderID, String(timestamp), nonce,
            addresses.map { $0.uppercased() }.sorted().joined(separator: ","),
        ].joined(separator: "|")
        return Data(HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8), using: SymmetricKey(data: secret)
        )).base64EncodedString()
    }

    fileprivate static func isValidSignature(
        _ signature: String, action: PeerMessage.Action, senderID: String,
        addresses: [String], timestamp: Int64, nonce: String, secret: Data
    ) -> Bool {
        guard let candidate = Data(base64Encoded: signature) else { return false }
        let canonical = [
            action.rawValue, senderID, String(timestamp), nonce,
            addresses.map { $0.uppercased() }.sorted().joined(separator: ","),
        ].joined(separator: "|")
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate, authenticating: Data(canonical.utf8),
            using: SymmetricKey(data: secret)
        )
    }
}

/// Discovers Macs over Bonjour, pairs them with a short-lived code, and accepts
/// handoff messages only when signed by a saved trusted computer.
final class PeerManager: PeerCoordinating {
    var onReleaseRequest: (([String], @escaping (Bool) -> Void) -> Void)?
    var onComputersChanged: (([ComputerInfo], [TrustedComputer]) -> Void)?

    private let serviceType = "_autopair._tcp"
    private let queue = DispatchQueue(label: "com.ericclemmons.AutoPair.network", qos: .utility)
    private let instanceID: String
    private let computerName: String
    private let serviceName: String
    private let trustedKey = "AutoPairTrustedComputers"
    private let defaults: UserDefaults

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: (name: String, endpoint: NWEndpoint)] = [:]
    private var trusted: [String: TrustedComputer] = [:]
    private var pairingCode: (value: String, expires: Date, attemptsRemaining: Int)?
    private var recentNonces: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let idKey = "AutoPairInstanceID"
        if let existing = defaults.string(forKey: idKey) {
            instanceID = existing
        } else {
            instanceID = UUID().uuidString
            defaults.set(instanceID, forKey: idKey)
        }
        computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let asciiName = String(
            data: computerName.data(using: .ascii, allowLossyConversion: true) ?? Data("Mac".utf8),
            encoding: .ascii
        ) ?? "Mac"
        serviceName = "\(instanceID)|\(asciiName.prefix(20))"
        if let data = defaults.data(forKey: trustedKey),
           let saved = try? JSONDecoder().decode([TrustedComputer].self, from: data) {
            trusted = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
    }

    var thisComputer: ComputerInfo { ComputerInfo(id: instanceID, name: computerName) }

    func start() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: serviceName, type: serviceType)
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
            var found: [String: (String, NWEndpoint)] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      let separator = name.firstIndex(of: "|") else { continue }
                let id = String(name[..<separator])
                guard id != self.instanceID else { continue }
                let displayName = String(name[name.index(after: separator)...])
                found[id] = (displayName.isEmpty ? "Mac" : displayName, result.endpoint)
            }
            self.endpoints = found
            self.publishComputers()
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { log.error("Peer browser failed: \(error)") }
        }
        browser.start(queue: queue)
        self.browser = browser
        publishComputers()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        endpoints = [:]
    }

    func generatePairingCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        queue.sync { pairingCode = (code, Date().addingTimeInterval(300), 5) }
        return code
    }

    func cancelPairingCode() {
        queue.async { self.pairingCode = nil }
    }

    func pair(with computerID: String, code: String,
              completion: @escaping (Result<TrustedComputer, ComputerPairingError>) -> Void) {
        queue.async {
            guard let endpoint = self.endpoints[computerID]?.endpoint else {
                DispatchQueue.main.async { completion(.failure(.unavailable)) }
                return
            }
            let nonce = PeerCrypto.randomData(count: 16).base64EncodedString()
            let request = PeerMessage(
                action: .pair, senderID: self.instanceID, senderName: self.computerName,
                nonce: nonce,
                authentication: PeerCrypto.pairingProof(
                    code: code, senderID: self.instanceID, nonce: nonce
                )
            )
            self.exchange(request, with: endpoint) { response in
                guard let response else {
                    DispatchQueue.main.async { completion(.failure(.connectionFailed)) }
                    return
                }
                if response.error == "expired" {
                    DispatchQueue.main.async { completion(.failure(.expiredCode)) }
                    return
                }
                guard response.action == .paired,
                      response.senderID == computerID,
                      let encrypted = response.encryptedSecret,
                      let secret = PeerCrypto.decrypt(encrypted, code: code, nonce: nonce) else {
                    DispatchQueue.main.async { completion(.failure(.invalidCode)) }
                    return
                }
                let computer = TrustedComputer(id: response.senderID, name: response.senderName,
                                               secret: secret)
                self.trusted[computer.id] = computer
                self.persistTrusted()
                self.publishComputers()
                DispatchQueue.main.async { completion(.success(computer)) }
            }
        }
    }

    func forgetComputer(_ id: String) {
        queue.async {
            self.trusted.removeValue(forKey: id)
            self.persistTrusted()
            self.publishComputers()
        }
    }

    func requestRelease(of addresses: [String], completion: @escaping (Bool) -> Void) {
        queue.async {
            let targets = self.trusted.values.compactMap { computer -> (TrustedComputer, NWEndpoint)? in
                self.endpoints[computer.id].map { (computer, $0.endpoint) }
            }
            guard !targets.isEmpty else {
                DispatchQueue.main.async { completion(true) }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var allReleased = true
            for (computer, endpoint) in targets {
                group.enter()
                let nonce = PeerCrypto.randomData(count: 16).base64EncodedString()
                let timestamp = Int64(Date().timeIntervalSince1970)
                let signature = PeerCrypto.signature(
                    action: .release, senderID: self.instanceID, addresses: addresses,
                    timestamp: timestamp, nonce: nonce, secret: computer.secret
                )
                let request = PeerMessage(
                    action: .release, senderID: self.instanceID, senderName: self.computerName,
                    addresses: addresses, nonce: nonce, timestamp: timestamp,
                    authentication: signature
                )
                self.exchange(request, with: endpoint) { response in
                    let success = response.map {
                        self.authenticate($0, expectedAction: .released, computer: computer)
                    } ?? false
                    lock.lock(); allReleased = allReleased && success; lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(allReleased) }
        }
    }

    func requestDiagnostics(completion: @escaping ([String: String]) -> Void) {
        queue.async {
            let computers = Array(self.trusted.values)
            guard !computers.isEmpty else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var results: [String: String] = [:]
            for computer in computers {
                guard let endpoint = self.endpoints[computer.id]?.endpoint else {
                    results[computer.name] =
                        "Unavailable — this Mac may be sleeping, offline, or running an older AutoPair."
                    continue
                }
                group.enter()
                let nonce = PeerCrypto.randomData(count: 16).base64EncodedString()
                let timestamp = Int64(Date().timeIntervalSince1970)
                let signature = PeerCrypto.signature(
                    action: .diagnostics, senderID: self.instanceID, addresses: [],
                    timestamp: timestamp, nonce: nonce, secret: computer.secret
                )
                let request = PeerMessage(
                    action: .diagnostics, senderID: self.instanceID,
                    senderName: self.computerName, addresses: [], nonce: nonce,
                    timestamp: timestamp, authentication: signature
                )
                self.exchange(request, with: endpoint) { response in
                    let value = response.flatMap { message -> String? in
                        guard self.authenticate(
                            message, expectedAction: .diagnosticsResult, computer: computer
                        ) else { return nil }
                        return message.diagnosticData
                    }
                    lock.lock()
                    results[computer.name] = value ??
                        "Unavailable — this Mac may be sleeping, offline, or running an older AutoPair."
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(results) }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive(on: connection) { [weak self] message in
                    guard let self, let message else { connection.cancel(); return }
                    switch message.action {
                    case .pair: self.handlePair(message, on: connection)
                    case .release: self.handleRelease(message, on: connection)
                    case .diagnostics: self.handleDiagnostics(message, on: connection)
                    default: connection.cancel()
                    }
                }
            case .failed, .cancelled: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func handlePair(_ message: PeerMessage, on connection: NWConnection) {
        guard var pending = pairingCode else { sendPairingError("expired", on: connection); return }
        guard pending.expires > Date(), pending.attemptsRemaining > 0 else {
            pairingCode = nil
            sendPairingError("expired", on: connection)
            return
        }
        pending.attemptsRemaining -= 1
        pairingCode = pending
        guard let nonce = message.nonce, let proof = message.authentication,
              PeerCrypto.isValidPairingProof(
                proof, code: pending.value, senderID: message.senderID, nonce: nonce
              ) else {
            sendPairingError("invalid", on: connection)
            return
        }

        let secret = PeerCrypto.randomData(count: 32)
        guard let encrypted = PeerCrypto.encrypt(secret: secret, code: pending.value, nonce: nonce) else {
            sendPairingError("invalid", on: connection)
            return
        }
        pairingCode = nil
        trusted[message.senderID] = TrustedComputer(
            id: message.senderID, name: message.senderName, secret: secret
        )
        persistTrusted()
        publishComputers()
        let response = PeerMessage(
            action: .paired, senderID: instanceID, senderName: computerName,
            nonce: nonce, encryptedSecret: encrypted
        )
        send(response, on: connection) { _ in connection.cancel() }
    }

    private func sendPairingError(_ error: String, on connection: NWConnection) {
        let response = PeerMessage(
            action: .paired, senderID: instanceID, senderName: computerName, error: error
        )
        send(response, on: connection) { _ in connection.cancel() }
    }

    private func handleRelease(_ message: PeerMessage, on connection: NWConnection) {
        guard let computer = trusted[message.senderID],
              authenticate(message, expectedAction: .release, computer: computer),
              let addresses = message.addresses else {
            connection.cancel()
            return
        }
        DispatchQueue.main.async {
            guard let handler = self.onReleaseRequest else { connection.cancel(); return }
            handler(addresses) { success in
                guard success else { connection.cancel(); return }
                let nonce = PeerCrypto.randomData(count: 16).base64EncodedString()
                let timestamp = Int64(Date().timeIntervalSince1970)
                let signature = PeerCrypto.signature(
                    action: .released, senderID: self.instanceID, addresses: addresses,
                    timestamp: timestamp, nonce: nonce, secret: computer.secret
                )
                let response = PeerMessage(
                    action: .released, senderID: self.instanceID, senderName: self.computerName,
                    addresses: addresses, nonce: nonce, timestamp: timestamp,
                    authentication: signature
                )
                self.send(response, on: connection) { _ in connection.cancel() }
            }
        }
    }

    private func handleDiagnostics(_ message: PeerMessage, on connection: NWConnection) {
        guard let computer = trusted[message.senderID],
              authenticate(message, expectedAction: .diagnostics, computer: computer) else {
            connection.cancel()
            return
        }
        let nonce = PeerCrypto.randomData(count: 16).base64EncodedString()
        let timestamp = Int64(Date().timeIntervalSince1970)
        let signature = PeerCrypto.signature(
            action: .diagnosticsResult, senderID: instanceID, addresses: [],
            timestamp: timestamp, nonce: nonce, secret: computer.secret
        )
        let response = PeerMessage(
            action: .diagnosticsResult, senderID: instanceID, senderName: computerName,
            addresses: [], nonce: nonce, timestamp: timestamp,
            authentication: signature, diagnosticData: Diagnostics.contents(maxBytes: 48_000)
        )
        send(response, on: connection) { _ in connection.cancel() }
    }

    private func authenticate(_ message: PeerMessage, expectedAction: PeerMessage.Action,
                              computer: TrustedComputer) -> Bool {
        guard message.action == expectedAction, let addresses = message.addresses,
              message.senderID == computer.id,
              let nonce = message.nonce, let timestamp = message.timestamp,
              let signature = message.authentication,
              abs(Date().timeIntervalSince1970 - Double(timestamp)) <= 60,
              recentNonces[nonce] == nil else { return false }
        guard PeerCrypto.isValidSignature(
            signature, action: expectedAction, senderID: message.senderID,
            addresses: addresses, timestamp: timestamp, nonce: nonce,
            secret: computer.secret
        ) else { return false }
        recentNonces[nonce] = Date()
        recentNonces = recentNonces.filter { Date().timeIntervalSince($0.value) < 120 }
        return true
    }

    private func exchange(_ message: PeerMessage, with endpoint: NWEndpoint,
                          completion: @escaping (PeerMessage?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let finish = PeerOnce { response in connection.cancel(); completion(response) }
        queue.asyncAfter(deadline: .now() + 8) { finish.call(nil) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.send(message, on: connection) { sent in
                    guard sent else { finish.call(nil); return }
                    self?.receive(on: connection) { finish.call($0) }
                }
            case .failed: finish.call(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ message: PeerMessage, on connection: NWConnection,
                      completion: @escaping (Bool) -> Void) {
        guard let payload = try? JSONEncoder().encode(message), payload.count <= 65_536 else {
            completion(false); return
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { completion($0 == nil) })
    }

    private func receive(on connection: NWConnection,
                         completion: @escaping (PeerMessage?) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { completion(nil); return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            guard length > 0, length <= 65_536 else { completion(nil); return }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) {
                payload, _, _, _ in
                guard let payload, payload.count == Int(length) else { completion(nil); return }
                completion(try? JSONDecoder().decode(PeerMessage.self, from: payload))
            }
        }
    }

    private func persistTrusted() {
        if let data = try? JSONEncoder().encode(Array(trusted.values)) {
            defaults.set(data, forKey: trustedKey)
        }
    }

    private func publishComputers() {
        let discovered = endpoints.compactMap { id, value in
            trusted[id] == nil ? ComputerInfo(id: id, name: value.name) : nil
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let trustedList = trusted.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        DispatchQueue.main.async { [weak self] in
            self?.onComputersChanged?(discovered, trustedList)
        }
    }

    deinit { stop() }
}

private final class PeerOnce {
    private let lock = NSLock()
    private var completed = false
    private let body: (PeerMessage?) -> Void
    init(_ body: @escaping (PeerMessage?) -> Void) { self.body = body }

    func call(_ value: PeerMessage?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        body(value)
    }
}
