import XCTest
@testable import AutoPair

final class PeerCryptoTests: XCTestCase {
    func testPairingCodeIsSixDigits() {
        let suite = "AutoPairTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PeerManager(defaults: defaults)

        let code = manager.generatePairingCode()

        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        manager.cancelPairingCode()
    }

    func testPairingProofDependsOnCodeAndSender() {
        let proof = PeerCrypto.pairingProof(code: "123456", senderID: "personal", nonce: "n")
        XCTAssertTrue(PeerCrypto.isValidPairingProof(
            proof, code: "123456", senderID: "personal", nonce: "n"
        ))
        XCTAssertNotEqual(proof, PeerCrypto.pairingProof(code: "654321", senderID: "personal", nonce: "n"))
        XCTAssertNotEqual(proof, PeerCrypto.pairingProof(code: "123456", senderID: "work", nonce: "n"))
        XCTAssertFalse(PeerCrypto.isValidPairingProof(
            proof, code: "123456", senderID: "personal", nonce: "tampered"
        ))
    }

    func testPairingSecretRoundTripsOnlyWithCorrectCode() {
        let secret = PeerCrypto.randomData(count: 32)
        let encrypted = PeerCrypto.encrypt(secret: secret, code: "123456", nonce: "nonce")
        XCTAssertNotNil(encrypted)
        XCTAssertEqual(PeerCrypto.decrypt(encrypted!, code: "123456", nonce: "nonce"), secret)
        XCTAssertNil(PeerCrypto.decrypt(encrypted!, code: "999999", nonce: "nonce"))
    }
}
