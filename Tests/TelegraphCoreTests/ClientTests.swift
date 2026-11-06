import Foundation
import Testing
import Darwin
@testable import TelegraphCore

private actor Scenario {
    let codec: TLCodec
    let me = TLObject("user", ["id": .long(42), "self": .bool(true), "first_name": .string("Test"), "access_hash": .long(7)])
    let friend = TLObject("user", ["id": .long(77), "first_name": .string("Friend"), "access_hash": .long(8)])
    var migrated = false
    var sends: [(String, Int64)] = []
    var failFirstSend = false
    var includeChannels = false
    var failFirstMediaSend = false
    var mediaSends: [TLObject] = []
    var uploaded: [Int64: [Int32: Data]] = [:]
    var readChannels: [Int64] = []
    var refreshedChannels: [Int64] = []
    var differenceRequests = 0
    var channelDifferenceRequests = 0
    var listeners: [@Sendable (TLObject) async throws -> Void] = []
    var recoveringGap = false
    init(failFirstSend: Bool = false, includeChannels: Bool = false, failFirstMediaSend: Bool = false) throws {
        codec = try TLCodec(); self.failFirstSend = failFirstSend
        self.includeChannels = includeChannels; self.failFirstMediaSend = failFirstMediaSend
    }
    private func channel(_ id: Int64 = 77) throws -> TLObject {
        try minimum("channel", ["id": .long(id), "access_hash": .long(900 + id), "broadcast": .bool(true),
            "title": .string(id == 77 ? "Memes" : "Read only"), "creator": .bool(id == 77), "photo": .object(TLObject("chatPhotoEmpty"))])
    }
    private func channelMessage(_ id: Int32, text: String, media: TLObject? = nil) throws -> TLObject {
        var fields: [String: TLValue] = ["id": .int(id), "date": .int(102), "out": .bool(true), "post": .bool(true),
            "peer_id": .object(TLObject("peerChannel", ["channel_id": .long(77)])), "message": .string(text)]
        if let media { fields["media"] = .object(media) }
        return try minimum("message", fields)
    }
    private func document() throws -> TLObject {
        try minimum("document", ["id": .long(200), "access_hash": .long(300), "file_reference": .bytes(Data([1])),
            "mime_type": .string("image/gif"), "size": .long(35), "dc_id": .int(2),
            "attributes": .vector([.object(TLObject("documentAttributeAnimated"))])])
    }
    func emitChannelUpdate(gap: Bool = false, deletePrivateMessage: Bool = false) async throws {
        let update: TLObject
        if deletePrivateMessage {
            update = TLObject("updateDeleteMessages", ["messages": .vector([.int(5)]), "pts": .int(11), "pts_count": .int(1)])
        } else {
            update = TLObject("updateNewChannelMessage", ["message": .object(try channelMessage(gap ? 9 : 6, text: "channel update")),
                "pts": .int(gap ? 24 : 21), "pts_count": .int(1)])
        }
        for listener in listeners { try await listener(TLObject("updateShort", ["date": .int(102), "update": .object(update)])) }
    }
    func register(_ listener: @escaping @Sendable (TLObject) async throws -> Void) { listeners.append(listener) }
    private func incoming(_ id: Int32, text: String) throws -> TLObject {
        try minimum("message", ["id": .int(id), "date": .int(101),
            "peer_id": .object(TLObject("peerUser", ["user_id": .long(77)])), "message": .string(text)])
    }
    func emitIncoming(gap: Bool) async throws {
        recoveringGap = gap
        let update = TLObject("updateShort", ["date": .int(101), "update": .object(TLObject("updateNewMessage", [
            "message": .object(try incoming(gap ? 8 : 6, text: gap ? "after gap" : "live message")),
            "pts": .int(gap ? 14 : 11), "pts_count": .int(1)
        ]))])
        for listener in listeners { try await listener(update) }
    }
    func minimum(_ name: String, _ overrides: [String: TLValue] = [:]) throws -> TLObject {
        let definition = try #require(codec.byName[name])
        var fields = overrides
        for p in definition.params where p.type != "#" && !p.type.contains("?") && fields[p.name] == nil {
            switch p.type {
            case "int": fields[p.name] = .int(0)
            case "long": fields[p.name] = .long(0)
            case "string": fields[p.name] = .string("")
            case "bytes": fields[p.name] = .bytes(Data())
            case "Bool": fields[p.name] = .bool(false)
            case "PeerNotifySettings": fields[p.name] = .object(TLObject("peerNotifySettings"))
            default:
                if p.type.hasPrefix("Vector<") { fields[p.name] = .vector([]) }
                else { throw TelegraphError.invalid("Missing test field \(name).\(p.name)") }
            }
        }
        return TLObject(name, fields)
    }
    func respond(_ request: TLObject, dc: Int32) throws -> TLValue {
        switch request.name {
        case "auth.sendCode":
            if !migrated { migrated = true; throw TelegraphError.rpc(303, "PHONE_MIGRATE_3") }
            #expect(dc == 3)
            return .object(TLObject("auth.sentCode", ["type": .object(TLObject("auth.sentCodeTypeApp", ["length": .int(5)])),
                                                     "phone_code_hash": .string("test-hash")]))
        case "auth.signIn":
            #expect(request["phone_code_hash"].string == "test-hash")
            if request["phone_code"].string == "00000" { throw TelegraphError.rpc(400, "PHONE_CODE_INVALID") }
            return .object(TLObject("auth.authorization", ["user": .object(me)]))
        case "users.getUsers": return .vector([.object(me)])
        case "help.getConfig": return .object(try minimum("config"))
        case "updates.getState": return .object(try minimum("updates.state", ["pts": .int(10), "date": .int(100)]))
        case "updates.getDifference":
            differenceRequests += 1
            if recoveringGap {
                return .object(try minimum("updates.difference", [
                    "new_messages": .vector([.object(try incoming(7, text: "recovered message")), .object(try incoming(8, text: "after gap"))]),
                    "state": .object(try minimum("updates.state", ["pts": .int(14), "date": .int(101)]))
                ]))
            }
            return .object(TLObject("updates.differenceEmpty", ["date": .int(100), "seq": .int(0)]))
        case "updates.getChannelDifference":
            channelDifferenceRequests += 1
            #expect(request["channel"].object?["channel_id"].long == 77)
            return .object(try minimum("updates.channelDifference", ["pts": .int(24), "final": .bool(true),
                "new_messages": .vector([.object(try channelMessage(8, text: "recovered channel message")),
                                          .object(try channelMessage(9, text: "channel update"))]),
                "chats": .vector([.object(try channel())])]))
        case "messages.getDialogs":
            let peer = TLObject("peerUser", ["user_id": .long(77)])
            let dm = try minimum("dialog", ["peer": .object(peer), "top_message": .int(5), "unread_count": .int(1)])
            let group = try minimum("dialog", ["peer": .object(TLObject("peerChat", ["chat_id": .long(99)])), "top_message": .int(6)])
            let message = try minimum("message", ["id": .int(5), "peer_id": .object(peer), "date": .int(100), "message": .string("Hello")])
            let empty = request["folder_id"].int == 1
            var dialogs = [dm, group], messages = [message], chats: [TLObject] = []
            if includeChannels {
                for id: Int64 in [77, 88] {
                    dialogs.append(try minimum("dialog", ["peer": .object(TLObject("peerChannel", ["channel_id": .long(id)])),
                        "top_message": .int(5), "pts": .int(20)]))
                    chats.append(try channel(id))
                }
                messages.append(try channelMessage(5, text: "Channel history"))
            }
            return .object(TLObject("messages.dialogs", [
                "dialogs": .vector(empty ? [] : dialogs.map { .object($0) }),
                "messages": .vector(empty ? [] : messages.map { .object($0) }), "chats": .vector(chats.map { .object($0) }),
                "users": .vector([.object(me), .object(friend)])
            ]))
        case "messages.getHistory":
            let peer = request["peer"].object
            if peer?.name == "inputPeerChannel" {
                #expect(peer?["channel_id"].long == 77)
                #expect(peer?["access_hash"].long == 977)
                return .object(try minimum("messages.channelMessages", ["pts": .int(20),
                    "messages": .vector([.object(try channelMessage(5, text: "Channel history"))]),
                    "chats": .vector([.object(try channel())])]))
            }
            let id: Int64 = peer?.name == "inputPeerSelf" ? 42 : 77
            let message = try minimum("message", ["id": .int(5), "date": .int(100),
                "peer_id": .object(TLObject("peerUser", ["user_id": .long(id)])), "message": .string("Hello history")])
            return .object(try minimum("messages.messages", ["messages": .vector([.object(message)]),
                "chats": .vector([]), "users": .vector([.object(me), .object(friend)])]))
        case "messages.readHistory": return .object(TLObject("messages.affectedMessages", ["pts": .int(10), "pts_count": .int(0)]))
        case "channels.readHistory":
            readChannels.append(request["channel"].object?["channel_id"].long ?? 0)
            return .bool(true)
        case "channels.getMessages":
            refreshedChannels.append(request["channel"].object?["channel_id"].long ?? 0)
            return .object(try minimum("messages.channelMessages", ["pts": .int(21), "messages": .vector([
                .object(try channelMessage(900, text: "caption", media: TLObject("messageMediaDocument", ["document": .object(try document())])))
            ])]))
        case "upload.saveFilePart", "upload.saveBigFilePart":
            uploaded[request["file_id"].long, default: [:]][request["file_part"].int] = request["bytes"].bytes
            return .bool(true)
        case "messages.sendMedia":
            mediaSends.append(request)
            if failFirstMediaSend, mediaSends.count == 1 { throw TelegraphError.rpc(500, "INTERNAL") }
            let media = try #require(request["media"].object), file = try #require(media["file"].object)
            let parts = try #require(uploaded[file["id"].long])
            #expect(parts.count == Int(file["parts"].int))
            let messageMedia = TLObject("messageMediaDocument", ["document": .object(try document())])
            if request["peer"].object?.name == "inputPeerChannel" {
                #expect(request["peer"].object?["access_hash"].long == 977)
                return .object(try minimum("updates", ["updates": .vector([.object(TLObject("updateNewChannelMessage", [
                    "message": .object(try channelMessage(900, text: request["message"].string, media: messageMedia)),
                    "pts": .int(21), "pts_count": .int(1)
                ]))]), "chats": .vector([.object(try channel())])]))
            }
            return .object(TLObject("updateShortSentMessage", ["out": .bool(true), "id": .int(900),
                "pts": .int(11), "pts_count": .int(1), "date": .int(101), "media": .object(messageMedia)]))
        case "messages.sendMessage":
            sends.append((request["message"].string, request["random_id"].long))
            if failFirstSend, sends.count == 1 { throw TelegraphError.rpc(500, "INTERNAL") }
            return .object(TLObject("updateShortSentMessage", ["out": .bool(true), "id": .int(900),
                "pts": .int(11), "pts_count": .int(1), "date": .int(101)]))
        case "auth.logOut": return .object(TLObject("auth.loggedOut"))
        default: throw TelegraphError.invalid("Unexpected test method \(request.name)")
        }
    }
}

private actor RPCTransport: PacketTransport {
    let scenario: Scenario, dc: Int32, codec: TLCodec
    let key = Data(repeating: 19, count: 256)
    var packets: [Data] = []
    var waiter: CheckedContinuation<Data, any Error>?
    var closed = false
    var lastID: Int64 = 0
    var currentSession: Int64 = 0, currentSalt: Int64 = 0
    init(scenario: Scenario, dc: Int32, codec: TLCodec) { self.scenario = scenario; self.dc = dc; self.codec = codec }
    func connect() async {
        await scenario.register { [weak self] update in try await self?.push(update) }
    }
    func close() { closed = true; waiter?.resume(throwing: TelegraphError.cancelled); waiter = nil }
    func receive() async throws -> Data {
        if !packets.isEmpty { return packets.removeFirst() }
        if closed { throw TelegraphError.cancelled }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func send(_ packet: Data) async throws {
        var r = BinaryReader(data: try Crypto.decryptMessage(packet, authKey: key, incoming: false))
        let salt = try r.integer(Int64.self), session = try r.integer(Int64.self), requestID = try r.integer(Int64.self)
        currentSession = session; currentSalt = salt
        let seq = try r.integer(Int32.self), count = try r.integer(Int32.self)
        if seq & 1 == 0 { return }
        var object = try #require(try codec.decode(r.read(Int(count))).object)
        while let query = object["query"].object { object = query }
        let result: TLValue
        do { result = try await scenario.respond(object, dc: dc) }
        catch let error as TelegraphError {
            guard case .rpc(let code, let message) = error else { throw error }
            result = .object(TLObject("rpc_error", ["error_code": .int(code), "error_message": .string(message)]))
        }
        var body = Data(); body.appendLE(UInt32(0xf35c6d01)); body.appendLE(requestID)
        switch result {
        case .object(let obj): body.append(try codec.encode(obj))
        case .bool(let value): body.appendLE(UInt32(value ? 0x997275b5 : 0xbc799737))
        case .vector(let values):
            body.appendLE(UInt32(0x1cb5c415)); body.appendLE(Int32(values.count))
            for value in values { body.append(try codec.encode(#require(value.object))) }
        default: throw TelegraphError.invalid("Invalid test result")
        }
        lastID = max(lastID + 4, Int64(Date().timeIntervalSince1970 * 4_294_967_296) | 1)
        var plain = Data(); plain.appendLE(salt); plain.appendLE(session); plain.appendLE(lastID)
        plain.appendLE(Int32(1)); plain.appendLE(Int32(body.count)); plain.append(body)
        let encrypted = try Crypto.encryptMessage(plain, authKey: key, incoming: true)
        if let waiter { self.waiter = nil; waiter.resume(returning: encrypted) }
        else { packets.append(encrypted) }
    }
    func push(_ update: TLObject) throws {
        guard !closed, currentSession != 0 else { return }
        let body = try codec.encode(update)
        lastID = max(lastID + 4, Int64(Date().timeIntervalSince1970 * 4_294_967_296) | 1)
        var plain = Data(); plain.appendLE(currentSalt); plain.appendLE(currentSession); plain.appendLE(lastID)
        plain.appendLE(Int32(1)); plain.appendLE(Int32(body.count)); plain.append(body)
        let packet = try Crypto.encryptMessage(plain, authKey: key, incoming: true)
        if let waiter { self.waiter = nil; waiter.resume(returning: packet) }
        else { packets.append(packet) }
    }
}

private func fixtureClient(scenario: Scenario, signedIn: Bool) throws -> TelegramClient {
    var profile = ClientProfile(apiID: 1, apiHash: String(repeating: "1", count: 32))
    profile.keys = [2: DCAuth(dc: 2, key: Data(repeating: 19, count: 256), salt: 1, timeOffset: 0),
                    3: DCAuth(dc: 3, key: Data(repeating: 19, count: 256), salt: 1, timeOffset: 0)]
    if signedIn { profile.userID = 42; profile.authorizedDCs = [2] }
    let codec = try TLCodec()
    return try TelegramClient(profile: profile, test: true, persistence: ProfilePersistence(save: { _ in }, delete: {}),
                              transportFactory: { RPCTransport(scenario: scenario, dc: $0.id, codec: codec) })
}

@Test func loginRedirectInvalidCodeAndSessionReuse() async throws {
    let scenario = try Scenario(), client = try fixtureClient(scenario: scenario, signedIn: false)
    do {
        let sent = try await client.beginLogin(phone: "+9996630000")
        #expect(sent["type"].object?.name == "auth.sentCodeTypeApp")
        do { try await client.submitCode(phone: "+9996630000", sent: sent, code: "00000"); Issue.record("Invalid code accepted") }
        catch { #expect((error as? TelegraphError)?.rpcMessage == "PHONE_CODE_INVALID") }
        try await client.submitCode(phone: "+9996630000", sent: sent, code: "11111")
        #expect(await client.hasSession)
        try await client.validateSession()
        #expect(await client.accountID() == 42)
        try await client.logout()
    } catch { await client.close(); throw error }
}

@Test func privateDialogFilteringAndHistory() async throws {
    let scenario = try Scenario(), client = try fixtureClient(scenario: scenario, signedIn: true)
    let snapshots = Task { () -> ClientSnapshot? in
        for await event in await client.events {
            if case .snapshot(let value) = event, value.selectedID == 77, !value.loading, !value.messages.isEmpty { return value }
        }
        return nil
    }
    let timeout = Task {
        try? await Task.sleep(for: .seconds(3))
        snapshots.cancel()
    }
    do {
        try await client.startMessaging()
        await client.select(77)
        let value = try #require(await snapshots.value)
        timeout.cancel()
        #expect(Set(value.conversations.map(\.id)) == [42, 77])
        #expect(value.conversations.first?.title == "Saved Messages")
        #expect(value.messages.first?.text == "Hello history")
        await client.close()
    } catch { await client.close(); snapshots.cancel(); throw error }
}

@Test func livePrivateUpdatesAndGapRecovery() async throws {
    let scenario = try Scenario(), client = try fixtureClient(scenario: scenario, signedIn: true)
    let snapshots = Task { () -> ClientSnapshot? in
        for await event in await client.events {
            if case .snapshot(let value) = event, value.messages.contains(where: { $0.id == 8 }) { return value }
        }
        return nil
    }
    let timeout = Task { try? await Task.sleep(for: .seconds(3)); snapshots.cancel() }
    do {
        try await client.startMessaging()
        await client.select(77)
        try await scenario.emitIncoming(gap: false)
        try await Task.sleep(for: .milliseconds(20))
        try await scenario.emitIncoming(gap: true)
        let result = try #require(await snapshots.value)
        timeout.cancel()
        #expect(result.messages.map(\.id) == [5, 6, 7, 8])
        #expect(result.messages.filter { $0.id == 8 }.count == 1)
        await client.close()
    } catch { await client.close(); snapshots.cancel(); timeout.cancel(); throw error }
}

@Test(arguments: [false, true]) @MainActor func terminalComposerPasteRetryAndQuit(attachment: Bool) async throws {
    let scenario = try Scenario(failFirstSend: !attachment, includeChannels: attachment, failFirstMediaSend: attachment)
    let client = try fixtureClient(scenario: scenario, signedIn: true)
    var master: Int32 = -1, slave: Int32 = -1
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw TelegraphError.invalid("openpty failed") }
    defer { Darwin.close(master); Darwin.close(slave) }
    _ = fcntl(master, F_SETFL, O_NONBLOCK)
    let terminal = try TerminalIO(input: slave, output: slave, monitorSignals: false)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegraph-ui-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("my meme.gif")
    try uploadGIF.write(to: file)
    let ui = TerminalUI(terminal: terminal, client: client, downloadRoot: root)
    let running = Task { try await ui.run() }
    func send(_ text: String) { let bytes = Array(text.utf8); _ = Darwin.write(master, bytes, bytes.count) }
    var transcript = ""
    func waitFor(_ text: String) async throws {
        for _ in 0..<300 {
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(master, &bytes, bytes.count)
            if count > 0 { transcript += String(decoding: bytes.prefix(count), as: UTF8.self) }
            if transcript.contains(text) { transcript = ""; return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TelegraphError.invalid("Terminal did not display \(text)")
    }
    do {
        try await waitFor("Saved Messages")
        if attachment { send("\u{1b}[B") }
        send("\r")
        try await waitFor(attachment ? "Channel history" : "Hello history")
        if attachment {
            send("\u{06}")
            try await waitFor("File path")
            send("\u{1b}[200~'\(file.path)'\u{1b}[201~\r")
            try await waitFor("Attached my meme.gif")
            send("\u{18}\u{06}")
            try await waitFor("File path")
            send("\u{1b}")
            try await waitFor("Attachment cancelled")
            #expect(await scenario.mediaSends.isEmpty)
            send("\u{06}")
            try await waitFor("File path")
            send("\u{1b}[200~'\(file.path)'\u{1b}[201~\r")
            try await waitFor("Attached my meme.gif")
        }
        send("\u{1b}[200~hello 🌍\nsecond line\u{1b}[201~\r")
        try await waitFor("Enter retries")
        send(attachment ? "\r" : "\u{18}\r")
        try await waitFor("Sent")
        let sends = attachment ? await scenario.mediaSends.map { ($0["message"].string, $0["random_id"].long) } : await scenario.sends
        #expect(sends.count == 2)
        #expect(sends.first?.0 == "hello 🌍\nsecond line")
        #expect(sends.first?.1 == sends.last?.1)
        if attachment {
            #expect(await scenario.mediaSends.allSatisfy { $0["peer"].object?.name == "inputPeerChannel" })
            #expect(await scenario.uploaded.values.allSatisfy { $0[0] == uploadGIF })
            #expect(await scenario.readChannels.contains(77))
        }
        send("\u{04}")
        #expect(try await running.value == 0)
    } catch {
        send("\u{04}")
        _ = try? await running.value
        throw error
    }
}

@Test(arguments: [Int64(-77), Int64(42)], ["", "caption"])
func sendsMediaWithRetryAndCorrectMessageBox(peer: Int64, caption: String) async throws {
    let scenario = try Scenario(includeChannels: true, failFirstMediaSend: true)
    let client = try fixtureClient(scenario: scenario, signedIn: true)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("telegraph-send-\(UUID()).gif")
    try uploadGIF.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let attachment = try await OutgoingAttachment.prepare(url)
    let snapshots = Task { () -> ClientSnapshot? in
        for await event in await client.events {
            if case .snapshot(let value) = event, value.selectedID == peer, value.messages.contains(where: { $0.id == 900 }) { return value }
        }
        return nil
    }
    let timeout = Task { try? await Task.sleep(for: .seconds(3)); snapshots.cancel() }
    do {
        try await client.startMessaging()
        await client.select(peer)
        await #expect(throws: (any Error).self) {
            try await client.sendFile(attachment, caption: caption, to: peer, randomID: 12345, progress: { _, _ in })
        }
        try await client.sendFile(attachment, caption: caption, to: peer, randomID: 12345, progress: { _, _ in })
        let snapshot = try #require(await snapshots.value)
        timeout.cancel()
        let sent = try #require(snapshot.messages.first { $0.id == 900 })
        #expect(sent.peerID == peer && sent.text == caption && sent.outgoing)
        #expect(sent.media?.kind == .gif)
        #expect(Set(snapshot.conversations.map(\.id)) == [42, 77, -77, -88])
        #expect(snapshot.conversations.first { $0.id == -77 }?.canSend == true)
        #expect(snapshot.conversations.first { $0.id == -88 }?.canSend == false)
        #expect(await scenario.mediaSends.map { $0["random_id"].long } == [12345, 12345])
        if peer < 0 {
            let media = try #require(sent.media)
            #expect(try await client.refreshMedia(media).peerID == peer)
            #expect(await scenario.refreshedChannels == [77])
            await client.markRead(peer: peer, maxID: sent.id)
            #expect(await scenario.readChannels == [77])
        }
        let uploadCount = await scenario.uploaded.count
        await #expect(throws: (any Error).self) {
            try await client.sendFile(attachment, caption: "", to: -88, randomID: 222, progress: { _, _ in })
        }
        await #expect(throws: (any Error).self) {
            try await client.sendFile(attachment, caption: String(repeating: "x", count: 1025), to: peer, randomID: 223, progress: { _, _ in })
        }
        #expect(await scenario.uploaded.count == uploadCount)
        await client.close()
    } catch { await client.close(); snapshots.cancel(); timeout.cancel(); throw error }
}

@Test func channelUpdatesRecoverIndependentlyAndIgnorePrivateDeletions() async throws {
    let scenario = try Scenario(includeChannels: true), client = try fixtureClient(scenario: scenario, signedIn: true)
    let snapshots = Task { () -> ClientSnapshot? in
        for await event in await client.events {
            if case .snapshot(let value) = event, value.messages.contains(where: { $0.id == 9 }) { return value }
        }
        return nil
    }
    let timeout = Task { try? await Task.sleep(for: .seconds(3)); snapshots.cancel() }
    do {
        try await client.startMessaging()
        await client.select(-77)
        try await scenario.emitChannelUpdate(deletePrivateMessage: true)
        try await scenario.emitChannelUpdate()
        try await scenario.emitChannelUpdate(gap: true)
        let snapshot = try #require(await snapshots.value)
        timeout.cancel()
        #expect(snapshot.messages.map(\.id) == [5, 6, 8, 9])
        #expect(snapshot.messages.allSatisfy { $0.peerID == -77 })
        #expect(await scenario.channelDifferenceRequests == 1)
        #expect(await scenario.differenceRequests == 0)
        await client.close()
    } catch { await client.close(); snapshots.cancel(); timeout.cancel(); throw error }
}
