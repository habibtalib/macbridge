import CryptoKit
import Foundation
import Testing
@testable import BridgeCore

@Suite struct IdentityTests {
    @Test func deviceIDIsSixteenServerSafeCharacters() {
        let id = Identity().deviceID
        #expect(id.count == 16)
        #expect(BridgeModel.isValidDeviceName(id))
        #expect(id.allSatisfy { Base32.lowercase.contains($0) })
    }

    @Test func deviceIDMatchesTheServersDerivation() throws {
        // Fixed vector shared with server/test: SHA-256 of 32 zero bytes, first 10 bytes, RFC 4648 base32.
        #expect(DeviceID.derive(fromPublicKey: Data(repeating: 0, count: 32)) == "mzuhvlpymk6xo3ep")
    }

    @Test func deviceIDIsStablePerKeyAndDistinctAcrossKeys() {
        let a = Identity(), b = Identity()
        #expect(a.deviceID == Identity(privateKey: a.privateKey).deviceID)
        #expect(a.deviceID != b.deviceID)
    }

    @Test func signaturesVerifyOnlyWithTheRightKeyAndMessage() {
        let a = Identity(), b = Identity()
        let message = Data("hello".utf8)
        let signature = a.sign(message)
        #expect(Identity.verify(signature, of: message, publicKey: a.publicKey))
        #expect(!Identity.verify(signature, of: Data("hellp".utf8), publicKey: a.publicKey))
        #expect(!Identity.verify(signature, of: message, publicKey: b.publicKey))
        #expect(!Identity.verify(signature, of: message, publicKey: Data([1, 2, 3])))
    }

    @Test func base32RoundTrips() {
        for alphabet in [Base32.lowercase, Base32.crockford] {
            for count in [0, 1, 5, 10, 32] {
                let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
                #expect(Base32.decode(Base32.encode(data, alphabet: alphabet), alphabet: alphabet) == data)
            }
        }
        #expect(Base32.encode(Data("foobar".utf8), alphabet: Base32.lowercase) == "mzxw6ytboi")
        #expect(Base32.decode("not base32!", alphabet: Base32.lowercase) == nil)
    }

    @Test func groupsIDsInFours() {
        #expect(DeviceID.grouped("abcdefghijklmnop") == "abcd-efgh-ijkl-mnop")
        #expect(DeviceID.grouped("abcdef") == "abcd-ef")
    }
}

@Suite struct PairingTests {
    let controller = Identity()
    let host = Identity()

    @Test func codeSurvivesBeingReadAndTyped() throws {
        let code = PairingCode()
        #expect(code.display.count == 19)
        #expect(PairingCode(code.display) == code)
        #expect(PairingCode(code.display.lowercased().replacingOccurrences(of: "-", with: " ")) == code)
        #expect(code.tag.count == 16)
        #expect(PairingCode() != code)
    }

    @Test func lookalikeLettersAreReadAsDigits() throws {
        #expect(PairingCode("OOOO-IIII-LLLL-0000") == PairingCode("0000-1111-1111-0000"))
    }

    @Test(arguments: ["", "1234", "0000-0000-0000-000", "0000-0000-0000-00000", "UUUU-UUUU-UUUU-UUUU", "0000-0000-0000-000!"])
    func rejectsMalformedCodes(_ text: String) {
        #expect(PairingCode(text) == nil)
    }

    @Test func bothSidesLearnEachOthersKeys() throws {
        let shown = PairingCode()
        let typed = try #require(PairingCode(shown.display))
        #expect(typed.tag == shown.tag)

        let hello = PairingCode.Introduction(publicKey: controller.publicKey, name: "Laptop")
        let sealed = try #require(typed.seal(hello, from: .controller))
        #expect(shown.open(sealed, from: .controller) == hello)

        let reply = PairingCode.Introduction(publicKey: host.publicKey, name: "Studio")
        let sealedReply = try #require(shown.seal(reply, from: .host))
        #expect(typed.open(sealedReply, from: .host) == reply)
    }

    @Test func aDifferentCodeCannotOpenOrForge() throws {
        let real = PairingCode(), guess = PairingCode()
        let intro = PairingCode.Introduction(publicKey: controller.publicKey, name: "Laptop")
        let sealed = try #require(real.seal(intro, from: .controller))
        #expect(guess.open(sealed, from: .controller) == nil)
        // Something sealed under a guessed code is rejected by the real one.
        let forged = try #require(guess.seal(intro, from: .controller))
        #expect(real.open(forged, from: .controller) == nil)
        #expect(real.tag != guess.tag)
    }

    @Test func messagesCannotBeReflectedOrTampered() throws {
        let code = PairingCode()
        let intro = PairingCode.Introduction(publicKey: controller.publicKey, name: "Laptop")
        var sealed = try #require(code.seal(intro, from: .controller))
        // The controller's own message bounced back as if it were the host's reply.
        #expect(code.open(sealed, from: .host) == nil)
        sealed[sealed.count / 2] ^= 0x01
        #expect(code.open(sealed, from: .controller) == nil)
        #expect(code.open(Data(), from: .controller) == nil)
    }

    @Test func rejectsIntroductionsWithAMalformedKey() throws {
        let code = PairingCode()
        let bad = PairingCode.Introduction(publicKey: Data([1, 2, 3]), name: "x")
        let sealed = try #require(code.seal(bad, from: .controller))
        #expect(code.open(sealed, from: .controller) == nil)
    }
}

@Suite struct SessionAuthTests {
    let controller = Identity()
    let host = Identity()
    let stranger = Identity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var controllerAsSeenByHost: PairedDevice {
        PairedDevice(id: controller.deviceID, publicKey: controller.publicKey, name: "Laptop", mayControlThisMac: true)
    }
    var hostAsSeenByController: PairedDevice {
        PairedDevice(id: host.deviceID, publicKey: host.publicKey, name: "Studio", thisMacMayControl: true)
    }

    static let sdp = "v=0\r\na=group:BUNDLE 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=ice-ufrag:abcd\r\na=fingerprint:sha-256 AA:BB:CC\r\na=setup:actpass\r\n"

    @Test func acceptsAFreshSignedRequest() throws {
        let auth = SessionAuth.sign(.request, to: host.deviceID, identity: controller, now: now)
        let timestamp = try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID, now: now)
        #expect(timestamp == 1_800_000_000_000)
    }

    @Test func rejectsUnsignedOrForgedRequests() {
        #expect(throws: SessionAuth.Failure.unsigned) {
            try SessionAuth.verify(.request, auth: nil, from: controllerAsSeenByHost, to: host.deviceID, now: now)
        }
        // Signed by someone else, claiming to be the controller.
        let forged = SessionAuth.sign(.request, to: host.deviceID, identity: stranger, now: now)
        #expect(throws: SessionAuth.Failure.badSignature) {
            try SessionAuth.verify(.request, auth: forged, from: controllerAsSeenByHost, to: host.deviceID, now: now)
        }
    }

    @Test func rejectsARequestMeantForAnotherDevice() {
        let auth = SessionAuth.sign(.request, to: stranger.deviceID, identity: controller, now: now)
        #expect(throws: SessionAuth.Failure.badSignature) {
            try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID, now: now)
        }
    }

    @Test func rejectsStaleAndReplayedRequests() throws {
        let auth = SessionAuth.sign(.request, to: host.deviceID, identity: controller, now: now)
        #expect(throws: SessionAuth.Failure.stale) {
            try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID,
                                   now: now.addingTimeInterval(61))
        }
        #expect(throws: SessionAuth.Failure.stale) {
            try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID,
                                   now: now.addingTimeInterval(-61))
        }
        let accepted = try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID, now: now)
        #expect(throws: SessionAuth.Failure.replayed) {
            try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID,
                                   lastRequestTimestamp: accepted, now: now)
        }
    }

    @Test func rejectsARequestWithAnAlteredTimestamp() throws {
        var auth = try #require(SessionAuth.sign(.request, to: host.deviceID, identity: controller, now: now))
        auth.timestamp = auth.timestamp.map { $0 + 5_000 }
        #expect(throws: SessionAuth.Failure.badSignature) {
            try SessionAuth.verify(.request, auth: auth, from: controllerAsSeenByHost, to: host.deviceID, now: now)
        }
    }

    @Test func acceptsOfferAndAnswerFromThePairedDevice() throws {
        let offer = SignalPayload.offer(sdp: Self.sdp)
        let offerAuth = SessionAuth.sign(offer, to: controller.deviceID, identity: host)
        try SessionAuth.verify(offer, auth: offerAuth, from: hostAsSeenByController, to: controller.deviceID)

        let answer = SignalPayload.answer(sdp: Self.sdp)
        let answerAuth = SessionAuth.sign(answer, to: host.deviceID, identity: controller)
        try SessionAuth.verify(answer, auth: answerAuth, from: controllerAsSeenByHost, to: host.deviceID)
    }

    @Test func rejectsAnOfferWhoseCertificateWasSwapped() {
        // What a hostile server would do: keep the signature, replace the fingerprint with its own.
        let auth = SessionAuth.sign(.offer(sdp: Self.sdp), to: controller.deviceID, identity: host)
        let swapped = SignalPayload.offer(sdp: Self.sdp.replacingOccurrences(of: "AA:BB:CC", with: "11:22:33"))
        #expect(throws: SessionAuth.Failure.badSignature) {
            try SessionAuth.verify(swapped, auth: auth, from: hostAsSeenByController, to: controller.deviceID)
        }
        // Adding a second certificate next to the real one fails too.
        let added = SignalPayload.offer(sdp: Self.sdp + "a=fingerprint:sha-256 11:22:33\r\n")
        #expect(throws: SessionAuth.Failure.badSignature) {
            try SessionAuth.verify(added, auth: auth, from: hostAsSeenByController, to: controller.deviceID)
        }
    }

    @Test func rejectsUnsignedOrFingerprintlessSessionDescriptions() {
        #expect(throws: SessionAuth.Failure.unsigned) {
            try SessionAuth.verify(.offer(sdp: Self.sdp), auth: nil, from: hostAsSeenByController, to: controller.deviceID)
        }
        let bare = SignalPayload.answer(sdp: "v=0\r\n")
        let auth = SessionAuth.sign(bare, to: host.deviceID, identity: controller)
        #expect(throws: SessionAuth.Failure.noFingerprint) {
            try SessionAuth.verify(bare, auth: auth, from: controllerAsSeenByHost, to: host.deviceID)
        }
    }

    @Test func anAnswerSignatureDoesNotPassAsAnOffer() {
        let auth = SessionAuth.sign(.answer(sdp: Self.sdp), to: host.deviceID, identity: controller)
        #expect(throws: SessionAuth.Failure.badSignature) {
            try SessionAuth.verify(.offer(sdp: Self.sdp), auth: auth, from: controllerAsSeenByHost, to: host.deviceID)
        }
    }

    @Test func fingerprintComparisonIgnoresCaseOrderAndLineEndings() throws {
        let auth = SessionAuth.sign(.offer(sdp: "a=fingerprint:sha-256 AA:BB\r\na=fingerprint:sha-256 CC:DD\r\n"),
                                    to: controller.deviceID, identity: host)
        let reordered = SignalPayload.offer(sdp: "a=fingerprint:SHA-256 cc:dd\na=fingerprint:sha-256 aa:bb\na=fingerprint:sha-256 aa:bb\n")
        try SessionAuth.verify(reordered, auth: auth, from: hostAsSeenByController, to: controller.deviceID)
    }

    @Test func candidatesAndByeTravelUnsigned() throws {
        #expect(SessionAuth.sign(.bye, to: host.deviceID, identity: controller) == nil)
        try SessionAuth.verify(.bye, auth: nil, from: controllerAsSeenByHost, to: host.deviceID)
        try SessionAuth.verify(.candidate(sdp: "candidate:1", mLineIndex: 0, mid: nil), auth: nil,
                               from: controllerAsSeenByHost, to: host.deviceID)
    }

    @Test func realOffersCarryAFingerprint() async throws {
        // Guards the assumption the whole scheme rests on: WebRTC's SDP has a fingerprint line.
        let session = try #require(PeerSession(role: .host))
        defer { session.close() }
        let offer = await withCheckedContinuation { (continuation: CheckedContinuation<SignalPayload, Never>) in
            let resumed = NSLock()
            var done = false
            session.onSignal = { payload in
                guard case .offer = payload else { return }
                resumed.withLock {
                    guard !done else { return }
                    done = true
                    continuation.resume(returning: payload)
                }
            }
            session.start()
        }
        let fingerprints = SessionAuth.fingerprints(in: offer)
        #expect(fingerprints.count == 1)
        #expect(fingerprints.first?.hasPrefix("sha-256 ") == true)
    }
}
