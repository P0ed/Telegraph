import Foundation

enum SessionEvent: Sendable {
    case update(TLObject), connected, disconnected(String)
}

actor MTSession {
    private struct Pending {
        let token: UUID
        let body: Data
        let resultType: String
        let sequence: Int32
        let continuation: CheckedContinuation<TLValue, any Error>
        var retries = 0
    }
    let endpoint: DCEndpoint
    private let test: Bool
    private let apiID: Int32
    private let codec: TLCodec
    private let onAuth: @Sendable (DCAuth) async throws -> Void
    private let makeTransport: @Sendable (DCEndpoint) -> any PacketTransport
    let events: AsyncStream<SessionEvent>
    private let eventSink: AsyncStream<SessionEvent>.Continuation
    private var auth: DCAuth?
    private var transport: (any PacketTransport)?
    private var openingTransport: (any PacketTransport)?
    private var opening: Task<Void, any Error>?
    private var readerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var sessionID: Int64 = 0
    private var sequence: Int32 = 0
    private var lastID: Int64 = 0
    private var received: Set<Int64> = []
    private var pending: [Int64: Pending] = [:]
    private var initialized = false

    init(endpoint: DCEndpoint, test: Bool, apiID: Int32, auth: DCAuth?, codec: TLCodec,
         makeTransport: @escaping @Sendable (DCEndpoint) -> any PacketTransport = { TCPTransport(endpoint: $0) },
         onAuth: @escaping @Sendable (DCAuth) async throws -> Void) {
        self.endpoint = endpoint; self.test = test; self.apiID = apiID
        self.auth = auth; self.codec = codec; self.onAuth = onAuth; self.makeTransport = makeTransport
        (events, eventSink) = AsyncStream.makeStream()
    }

    func connect() async throws {
        if stopped { throw TelegraphError.cancelled }
        if let opening { return try await opening.value }
        if transport != nil { return }
        let task = Task { try await self.open() }
        opening = task
        do { try await task.value; opening = nil }
        catch { opening = nil; throw error }
    }
    private func open() async throws {
        let tcp = makeTransport(endpoint)
        openingTransport = tcp
        defer { openingTransport = nil }
        do {
            try await tcp.connect()
            if auth == nil {
                auth = try await KeyExchange.run(transport: tcp, dc: endpoint.id, test: test, codec: codec)
                try await onAuth(auth!)
            }
            guard !stopped else { throw TelegraphError.cancelled }
            transport = tcp
            sessionID = try Crypto.randomID(); sequence = 0; lastID = 0
            received.removeAll(); initialized = false; generation = UUID()
            let current = generation
            readerTask = Task { await self.readLoop(tcp, generation: current) }
            pingTask = Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(25))
                        try await self.sendControl(TLObject("ping_delay_disconnect", [
                            "ping_id": .long(Crypto.randomID()), "disconnect_delay": .int(40)
                        ]))
                    } catch { break }
                }
            }
            eventSink.yield(.connected)
        } catch { await tcp.close(); transport = nil; throw error }
    }
    private func nextID() -> Int64 {
        let now = Date().timeIntervalSince1970 + (auth?.timeOffset ?? 0)
        let id = Int64(now * 4_294_967_296) & ~3
        lastID = max(lastID + 4, id)
        return lastID
    }
    private func sendPacket(_ body: Data, sequence: Int32, id: Int64) async throws {
        guard let transport, let auth else { throw TelegraphError.connection("Not connected") }
        var plain = Data()
        plain.appendLE(auth.salt); plain.appendLE(sessionID); plain.appendLE(id)
        plain.appendLE(sequence); plain.appendLE(Int32(body.count)); plain.append(body)
        try await transport.send(Crypto.encryptMessage(plain, authKey: auth.key))
    }
    private func sendControl(_ object: TLObject) async throws {
        let data = try codec.encode(object)
        try await sendPacket(data, sequence: sequence * 2, id: nextID())
    }
    func request(_ object: TLObject, timeout: Duration = .seconds(45)) async throws -> TLValue {
        try await connect()
        try Task.checkCancellation()
        guard let definition = codec.byName[object.name] else { throw TelegraphError.invalid("Unknown API method") }
        var body = try codec.encode(object)
        if !initialized {
            let initConnection = try codec.encode(TLObject("initConnection", [
                "api_id": .int(apiID), "device_model": .string("Telegraph CLI"),
                "system_version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                "app_version": .string("0.1.0"), "system_lang_code": .string("en"),
                "lang_pack": .string(""), "lang_code": .string("en"), "query": .raw(body)
            ]))
            body = try codec.encode(TLObject("invokeWithLayer", ["layer": .int(TLCodec.layer), "query": .raw(initConnection)]))
            initialized = true
        }
        let token = UUID(), id = nextID(), seq = sequence * 2 + 1
        sequence += 1
        let requestBody = body
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(token: token, body: requestBody, resultType: definition.type,
                                      sequence: seq, continuation: continuation)
                Task {
                    do { try await self.sendPacket(requestBody, sequence: seq, id: id) }
                    catch { self.failToken(token, error: error) }
                }
                Task {
                    do { try await Task.sleep(for: timeout); self.failToken(token, error: TelegraphError.timeout) }
                    catch {}
                }
            }
        } onCancel: {
            Task { await self.failToken(token, error: CancellationError()) }
        }
    }
    private func failToken(_ token: UUID, error: any Error) {
        if let item = pending.first(where: { $0.value.token == token }) {
            pending.removeValue(forKey: item.key)?.continuation.resume(throwing: error)
        }
    }
    private func retry(_ id: Int64) async throws {
        guard var item = pending.removeValue(forKey: id) else { return }
        guard item.retries < 3 else { item.continuation.resume(throwing: TelegraphError.connection("Too many session retries")); return }
        item.retries += 1
        let newID = nextID()
        pending[newID] = item
        do { try await sendPacket(item.body, sequence: item.sequence, id: newID) }
        catch { failToken(item.token, error: error); throw error }
    }
    private func acknowledge(_ ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await sendControl(TLObject("msgs_ack", ["msg_ids": .vector(ids.map(TLValue.long))]))
    }
    private func accept(_ id: Int64, validateTime: Bool = true) throws -> Bool {
        guard id & 1 == 1 else { throw TelegraphError.invalid("Invalid server message ID") }
        if received.contains(id) { return false }
        if received.count >= 512, let smallest = received.min(), id < smallest { return false }
        if validateTime {
            let timestamp = Double(UInt64(bitPattern: id) >> 32)
            let now = Date().timeIntervalSince1970 + (auth?.timeOffset ?? 0)
            guard timestamp >= now - 300, timestamp <= now + 30 else {
                throw TelegraphError.invalid("Server message timestamp outside allowed window")
            }
        }
        received.insert(id)
        if received.count > 512, let first = received.min() { received.remove(first) }
        return true
    }
    private func readLoop(_ tcp: any PacketTransport, generation current: UUID) async {
        do {
            while !Task.isCancelled, current == generation {
                let frame = try await tcp.receive()
                guard current == generation, let auth else { return }
                let decrypted = try Crypto.decryptMessage(frame, authKey: auth.key)
                var reader = BinaryReader(data: decrypted)
                _ = try reader.integer(Int64.self) // salt is authenticated; new salts arrive in service messages
                guard try reader.integer(Int64.self) == sessionID else { throw TelegraphError.invalid("Telegram session ID mismatch") }
                let id = try reader.integer(Int64.self), seq = try reader.integer(Int32.self)
                let length = try reader.integer(Int32.self)
                guard length >= 4, length % 4 == 0, Int(length) <= reader.remaining else { throw TelegraphError.invalid("Invalid encrypted message length") }
                let body = try reader.read(Int(length))
                guard (12...1024).contains(reader.remaining) else { throw TelegraphError.invalid("Invalid encrypted padding length") }
                var peek = BinaryReader(data: body)
                let constructor = try peek.integer(UInt32.self)
                let timeCorrection = constructor == 0xa7eff811 || constructor == 0xedab447b
                let isNew = try accept(id, validateTime: !timeCorrection)
                if seq & 1 == 1 { try await acknowledge([id]) }
                if isNew { try await process(body, messageID: id) }
            }
        } catch {
            guard current == generation, !stopped else { return }
            await connectionFailed(error)
        }
    }
    private func process(_ body: Data, messageID: Int64, depth: Int = 0) async throws {
        guard depth <= 8 else { throw TelegraphError.invalid("Nested MTProto container limit exceeded") }
        var reader = BinaryReader(data: body)
        let id = try reader.integer(UInt32.self)
        if id == 0x73f1f8dc {
            let count = try reader.integer(Int32.self)
            guard count >= 0, count <= 1024 else { throw TelegraphError.invalid("Invalid MTProto container size") }
            for _ in 0..<count {
                let nestedID = try reader.integer(Int64.self), seq = try reader.integer(Int32.self)
                let length = try reader.integer(Int32.self)
                guard length >= 4, length % 4 == 0 else { throw TelegraphError.invalid("Invalid nested message length") }
                let bytes = try reader.read(Int(length))
                if seq & 1 == 1 { try await acknowledge([nestedID]) }
                if try accept(nestedID) { try await process(bytes, messageID: nestedID, depth: depth + 1) }
            }
            guard reader.remaining == 0 else { throw TelegraphError.invalid("Trailing MTProto container data") }
            return
        }
        if id == 0x3072cfa1 {
            let data = try gunzip(reader.bytes())
            guard reader.remaining == 0 else { throw TelegraphError.invalid("Trailing compressed message data") }
            try await process(data, messageID: messageID, depth: depth + 1); return
        }
        if id == 0xf35c6d01 {
            let requestID = try reader.integer(Int64.self)
            guard let item = pending.removeValue(forKey: requestID) else { return }
            do {
                var check = reader
                let next = try check.integer(UInt32.self)
                let result = try codec.decode(&reader, type: next == 0x2144ca19 ? "Object" : item.resultType)
                guard reader.remaining == 0 else { throw TelegraphError.invalid("Trailing RPC result data") }
                if let error = result.object, error.name == "rpc_error" {
                    item.continuation.resume(throwing: TelegraphError.rpc(error["error_code"].int, error["error_message"].string))
                } else { item.continuation.resume(returning: result) }
            } catch { item.continuation.resume(throwing: error); throw error }
            return
        }
        guard let obj = try codec.decode(body).object else { return }
        switch obj.name {
        case "new_session_created":
            auth?.salt = obj["server_salt"].long
            if let auth { try await onAuth(auth) }
        case "bad_server_salt":
            auth?.salt = obj["new_server_salt"].long
            if let auth { try await onAuth(auth) }
            try await retry(obj["bad_msg_id"].long)
        case "bad_msg_notification":
            let code = obj["error_code"].int
            if code == 16 || code == 17 {
                auth?.timeOffset = Double(UInt64(bitPattern: messageID) >> 32) - Date().timeIntervalSince1970
                lastID = 0
                try await retry(obj["bad_msg_id"].long)
            } else { throw TelegraphError.connection("Telegram rejected session sequence (\(code))") }
        case "msg_resend_req":
            for id in obj["msg_ids"].array { try await retry(id.long) }
        case "msg_detailed_info", "msg_new_detailed_info":
            let answerID = obj["answer_msg_id"].long
            if received.contains(answerID) { try await acknowledge([answerID]) }
            else { try await sendControl(TLObject("msg_resend_req", ["msg_ids": .vector([.long(answerID)])])) }
        case "msgs_ack", "pong", "msgs_all_info", "msgs_state_info": break
        default: eventSink.yield(.update(obj))
        }
    }
    private func connectionFailed(_ error: any Error) async {
        readerTask?.cancel(); pingTask?.cancel()
        let old = transport; transport = nil; generation = UUID()
        await old?.close()
        let requests = pending.values; pending.removeAll()
        for item in requests { item.continuation.resume(throwing: TelegraphError.connection(String(describing: error))) }
        eventSink.yield(.disconnected(String(describing: error)))
        guard reconnectTask == nil else { return }
        reconnectTask = Task {
            var delay = 1
            while !Task.isCancelled, !self.stopped {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    try await self.connect()
                    self.reconnectTask = nil
                    return
                } catch { delay = min(30, delay * 2) }
            }
            self.reconnectTask = nil
        }
    }
    func close() async {
        stopped = true
        opening?.cancel(); readerTask?.cancel(); pingTask?.cancel(); reconnectTask?.cancel()
        generation = UUID()
        await openingTransport?.close()
        await transport?.close(); transport = nil
        let requests = pending.values; pending.removeAll()
        for request in requests { request.continuation.resume(throwing: TelegraphError.cancelled) }
        eventSink.finish()
    }
}
