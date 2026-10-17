import Foundation
@preconcurrency import Network

struct DCEndpoint: Codable, Sendable, Equatable {
    let id: Int32
    let host: String
    let port: UInt16
    var media = false
    static func bootstrap(test: Bool, id: Int32 = 2) -> Self {
        let production: [Int32: String] = [1: "149.154.175.53", 2: "149.154.167.51", 3: "149.154.175.100", 4: "149.154.167.91", 5: "91.108.56.130"]
        let testing: [Int32: String] = [1: "149.154.175.10", 2: "149.154.167.40", 3: "149.154.175.117"]
        return Self(id: id, host: (test ? testing : production)[id] ?? "149.154.167.40", port: 443)
    }
}

protocol PacketTransport: Sendable {
    func connect() async throws
    func send(_ packet: Data) async throws
    func receive() async throws -> Data
    func close() async
}

private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
        return c != nil
    }
}

actor TCPTransport: PacketTransport {
    let endpoint: DCEndpoint
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "telegraph.tcp")
    init(endpoint: DCEndpoint) { self.endpoint = endpoint }
    func connect() async throws {
        let c = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        connection = c
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OneShot(continuation)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success(()))
                case .failed(let error): once.finish(.failure(TelegraphError.connection(error.localizedDescription)))
                case .cancelled: once.finish(.failure(TelegraphError.cancelled))
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 15) {
                if once.finish(.failure(TelegraphError.timeout)) { c.cancel() }
            }
            c.start(queue: queue)
        }
        var preamble = Data(); preamble.appendLE(UInt32(0xeeeeeeee))
        try await write(preamble)
    }
    private func write(_ data: Data) async throws {
        guard let c = connection else { throw TelegraphError.connection("Not connected") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OneShot(continuation)
            c.send(content: data, completion: .contentProcessed { error in
                if let error { once.finish(.failure(TelegraphError.connection(error.localizedDescription))) }
                else { once.finish(.success(())) }
            })
            queue.asyncAfter(deadline: .now() + 30) {
                if once.finish(.failure(TelegraphError.timeout)) { c.cancel() }
            }
        }
    }
    func send(_ packet: Data) async throws {
        guard packet.count <= 16 * 1024 * 1024, packet.count.isMultiple(of: 4) else {
            throw TelegraphError.invalid("Invalid transport packet length")
        }
        var frame = Data(); frame.appendLE(UInt32(packet.count)); frame.append(packet)
        try await write(frame)
    }
    private func read(_ count: Int) async throws -> Data {
        guard let c = connection else { throw TelegraphError.connection("Not connected") }
        var result = Data()
        while result.count < count {
            let needed = count - result.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                let once = OneShot(continuation)
                c.receive(minimumIncompleteLength: needed, maximumLength: needed) { data, _, complete, error in
                    if let error { once.finish(.failure(TelegraphError.connection(error.localizedDescription))) }
                    else if let data, !data.isEmpty { once.finish(.success(data)) }
                    else { once.finish(.failure(TelegraphError.connection(complete ? "Connection closed" : "Empty network read"))) }
                }
                queue.asyncAfter(deadline: .now() + 65) {
                    if once.finish(.failure(TelegraphError.timeout)) { c.cancel() }
                }
            }
            result.append(chunk)
        }
        return result
    }
    func receive() async throws -> Data {
        var header = BinaryReader(data: try await read(4))
        let length = try header.integer(UInt32.self)
        guard length >= 4, length <= 16 * 1024 * 1024, length % 4 == 0 else {
            throw TelegraphError.invalid("Invalid Telegram transport frame")
        }
        let data = try await read(Int(length))
        if data.count == 4 {
            var reader = BinaryReader(data: data)
            let error = try reader.integer(Int32.self)
            if error < 0 { throw TelegraphError.connection("Telegram transport error \(error)") }
        }
        return data
    }
    func close() { connection?.cancel(); connection = nil }
}
