import Foundation
import Testing
@testable import TelegraphCore

private actor ScriptedTransport: PacketTransport {
    enum Mode: Sendable { case container, badSalt, corrupt, silent }
    let key = Data((0..<256).map(UInt8.init))
    let codec: TLCodec
    let mode: Mode
    var queue: [Data] = []
    var receiver: CheckedContinuation<Data, any Error>?
    var closed = false
    var sentSequences: [Int32] = []
    var didCorrectSalt = false
    var lastServerID: Int64 = 0
    init(_ mode: Mode) throws { self.mode = mode; codec = try TLCodec() }
    func connect() {}
    func receive() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw TelegraphError.cancelled }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() { closed = true; receiver?.resume(throwing: TelegraphError.cancelled); receiver = nil }
    private func nextID() -> Int64 {
        lastServerID = max(lastServerID + 4, Int64(Date().timeIntervalSince1970 * 4_294_967_296) | 1)
        return lastServerID
    }
    private func deliver(_ data: Data) {
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { queue.append(data) }
    }
    func send(_ packet: Data) async throws {
        var reader = BinaryReader(data: try Crypto.decryptMessage(packet, authKey: key, incoming: false))
        let salt = try reader.integer(Int64.self), session = try reader.integer(Int64.self)
        let requestID = try reader.integer(Int64.self), seq = try reader.integer(Int32.self)
        let length = try reader.integer(Int32.self)
        let bytes = try reader.read(Int(length))
        if seq & 1 == 0 { return }
        sentSequences.append(seq)
        if mode == .silent { return }
        var response: Data
        if mode == .badSalt && !didCorrectSalt {
            didCorrectSalt = true
            response = try codec.encode(TLObject("bad_server_salt", ["bad_msg_id": .long(requestID),
                "bad_msg_seqno": .int(seq), "error_code": .int(48), "new_server_salt": .long(101)]))
        } else {
            if mode == .badSalt { #expect(salt == 101) }
            var request = try #require(try codec.decode(bytes).object)
            while let inner = request["query"].object { request = inner }
            #expect(request.name == "messages.readHistory")
            response = Data(); response.appendLE(UInt32(0xf35c6d01)); response.appendLE(requestID)
            response.append(try codec.encode(TLObject("messages.affectedMessages", ["pts": .int(7), "pts_count": .int(1)])))
            if mode == .container {
                let newSession = try codec.encode(TLObject("new_session_created", [
                    "first_msg_id": .long(requestID), "unique_id": .long(9), "server_salt": .long(101)
                ]))
                var container = Data(); container.appendLE(UInt32(0x73f1f8dc)); container.appendLE(Int32(2))
                for body in [newSession, response] {
                    container.appendLE(nextID()); container.appendLE(Int32(1))
                    container.appendLE(Int32(body.count)); container.append(body)
                }
                response = container
            }
        }
        var plain = Data(); plain.appendLE(Int64(101)); plain.appendLE(session); plain.appendLE(nextID())
        plain.appendLE(Int32(1)); plain.appendLE(Int32(response.count)); plain.append(response)
        var encrypted = try Crypto.encryptMessage(plain, authKey: key, incoming: true)
        if mode == .corrupt { encrypted[30] ^= 1 }
        deliver(encrypted)
    }
}

private func makeSession(_ transport: ScriptedTransport) async throws -> MTSession {
    let auth = DCAuth(dc: 2, key: transport.key, salt: 1, timeOffset: 0)
    return MTSession(endpoint: .bootstrap(test: true), test: true, apiID: 1, auth: auth,
                     codec: try TLCodec(), makeTransport: { _ in transport }, onAuth: { _ in })
}
private let readRequest = TLObject("messages.readHistory", ["peer": .object(TLObject("inputPeerSelf")), "max_id": .int(42)])

@Test func encryptedRPCContainersAndSaltRetry() async throws {
    for mode in [ScriptedTransport.Mode.container, .badSalt] {
        let transport = try ScriptedTransport(mode), session = try await makeSession(transport)
        do {
            let result = try await session.request(readRequest)
            #expect(result.object?["pts"].int == 7)
            if mode == .badSalt { #expect(await transport.sentSequences == [1, 1]) }
            await session.close()
        } catch { await session.close(); throw error }
    }
}

@Test func rejectsCorruptEncryptedResponses() async throws {
    let transport = try ScriptedTransport(.corrupt), session = try await makeSession(transport)
    do {
        _ = try await session.request(readRequest)
        Issue.record("Corrupt ciphertext was accepted")
    } catch { #expect(String(describing: error).contains("integrity")) }
    await session.close()
}

@Test func pendingRequestTimeoutAndCancellation() async throws {
    let transport = try ScriptedTransport(.silent), session = try await makeSession(transport)
    do {
        _ = try await session.request(readRequest, timeout: .milliseconds(20))
        Issue.record("A silent request did not time out")
    } catch { #expect(error as? TelegraphError != nil) }
    let task = Task { try await session.request(readRequest) }
    try await Task.sleep(for: .milliseconds(10))
    task.cancel()
    do { _ = try await task.value; Issue.record("A cancelled request succeeded") }
    catch { #expect(error is CancellationError) }
    await session.close()
}
