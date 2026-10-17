import Foundation

actor TelegramClient {
    private var profile: ClientProfile
    private let test: Bool
    private let codec: TLCodec
    private let persistence: ProfilePersistence
    private let transportFactory: @Sendable (DCEndpoint) -> any PacketTransport
    private var sessions: [Int32: MTSession] = [:]
    private var mediaSessions: [Int32: MTSession] = [:]
    private var eventTasks: [Task<Void, Never>] = []
    private var authorizing: [Int32: Task<MTSession, any Error>] = [:]
    let events: AsyncStream<ClientEvent>
    private let sink: AsyncStream<ClientEvent>.Continuation
    private var users: [Int64: TLObject] = [:]
    private var chats: [Int64: TLObject] = [:]
    private var dialogs: [Int64: Conversation] = [:]
    private var selectedID: Int64?
    private var messages: [ChatMessage] = []
    private var hasOlder = true
    private var loading = false
    private var selectionGeneration = UUID()
    private var readMax: [Int64: Int32] = [:]
    private var pts: Int32 = 0, qts: Int32 = 0, date: Int32 = 0, seq: Int32 = 0
    private var messaging = false
    private var wantsMessaging = false
    private var syncing = false
    private var buffered: [TLObject] = []
    private var floodUntil = Date.distantPast
    private var stopped = false

    init(profile: ClientProfile, test: Bool, persistence: ProfilePersistence? = nil,
         transportFactory: @escaping @Sendable (DCEndpoint) -> any PacketTransport = { TCPTransport(endpoint: $0) }) throws {
        self.profile = profile; self.test = test; codec = try TLCodec()
        self.persistence = persistence ?? .live(test: test)
        self.transportFactory = transportFactory
        (events, sink) = AsyncStream.makeStream()
    }
    var userID: Int64? { profile.userID }
    var hasSession: Bool { profile.userID != nil && profile.authorizedDCs.contains(profile.mainDC) }
    private func emit() {
        let sorted = dialogs.values.sorted {
            if $0.id == profile.userID { return $1.id != profile.userID }
            if $1.id == profile.userID { return false }
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }
        sink.yield(.snapshot(ClientSnapshot(conversations: sorted, selectedID: selectedID, messages: messages, loading: loading, hasOlder: hasOlder)))
    }
    private func save() throws { try persistence.save(profile) }
    private func record(_ auth: DCAuth) throws { profile.keys[auth.dc] = auth; try save() }
    private func session(dc: Int32? = nil) -> MTSession {
        let dc = dc ?? profile.mainDC
        if let existing = sessions[dc] { return existing }
        let endpoint = profile.endpoints.first { $0.id == dc && !$0.media } ?? .bootstrap(test: test, id: dc)
        let value = MTSession(endpoint: endpoint, test: test, apiID: profile.apiID, auth: profile.keys[dc], codec: codec, makeTransport: transportFactory) {
            [weak self] auth in try await self?.record(auth)
        }
        sessions[dc] = value
        if dc == profile.mainDC {
            eventTasks.append(Task { [weak self] in
                for await event in value.events { await self?.handle(event) }
            })
        }
        return value
    }
    private func handle(_ event: SessionEvent) async {
        guard !stopped else { return }
        switch event {
        case .connected:
            if messaging { await recover() }
            else if wantsMessaging && !syncing {
                do { try await startMessaging() }
                catch { sink.yield(.status(describe(error))) }
            }
        case .disconnected:
            sink.yield(.status("Disconnected. Reconnecting…"))
        case .update(let update):
            guard messaging else { return }
            if syncing { buffer(update) }
            else { await consume(update) }
        }
    }
    private func buffer(_ update: TLObject) {
        if buffered.count < 1024 { buffered.append(update) }
        else { buffered = [TLObject("updatesTooLong")] }
    }
    private func migration(_ message: String) -> Int32? {
        for prefix in ["PHONE_MIGRATE_", "NETWORK_MIGRATE_", "USER_MIGRATE_"] where message.hasPrefix(prefix) {
            return Int32(message.dropFirst(prefix.count))
        }
        return nil
    }
    private func rawRPC(_ object: TLObject, on target: MTSession? = nil) async throws -> TLValue {
        let wait = floodUntil.timeIntervalSinceNow
        if wait > 0 { throw TelegraphError.rpc(420, "FLOOD_WAIT_\(Int(ceil(wait)))") }
        var lastError: (any Error)?
        for attempt in 0..<3 {
            do { return try await (target ?? session()).request(object) }
            catch let error as TelegraphError {
                lastError = error
                if case .rpc(_, let message) = error {
                    if message.hasPrefix("FLOOD_WAIT_") || message.hasPrefix("FLOOD_PREMIUM_WAIT_") {
                        if let seconds = Int(message.split(separator: "_").last ?? "") {
                            floodUntil = Date().addingTimeInterval(Double(seconds))
                        }
                        throw error
                    }
                    if target == nil, let dc = migration(message), (1...(test ? 3 : 5)).contains(dc) {
                        let oldDC = profile.mainDC, old = session()
                        let wasAuthorized = profile.authorizedDCs.contains(profile.mainDC)
                        if wasAuthorized, !profile.authorizedDCs.contains(dc) {
                            let destination = session(dc: dc)
                            let exported = try await rpc("auth.exportAuthorization", ["dc_id": .int(dc)], on: old)
                            _ = try await rpc("auth.importAuthorization", ["id": exported["id"], "bytes": exported["bytes"]], on: destination)
                            profile.authorizedDCs.insert(dc)
                        }
                        profile.mainDC = dc
                        try save()
                        // Recreate the destination so its stream becomes the main update stream.
                        if let oldTarget = sessions.removeValue(forKey: dc) { await oldTarget.close() }
                        sessions.removeValue(forKey: oldDC); await old.close()
                        _ = session()
                        continue
                    }
                    throw error
                }
                if case .connection = error, attempt < 2 {
                    try await Task.sleep(for: .seconds(attempt + 1)); continue
                }
                throw error
            } catch { throw error }
        }
        throw lastError ?? TelegraphError.timeout
    }
    private func rpc(_ name: String, _ fields: [String: TLValue] = [:], on target: MTSession? = nil) async throws -> TLObject {
        let result = try await rawRPC(TLObject(name, fields), on: target)
        guard let object = result.object else { throw TelegraphError.invalid("Unexpected response to \(name)") }
        return object
    }
    func beginLogin(phone: String) async throws -> TLObject {
        let sent = try await rpc("auth.sendCode", [
            "phone_number": .string(phone), "api_id": .int(profile.apiID), "api_hash": .string(profile.apiHash),
            "settings": .object(TLObject("codeSettings"))
        ])
        if sent.name == "auth.sentCodeSuccess", let auth = sent["authorization"].object { try finishLogin(auth) }
        return sent
    }
    func resendCode(phone: String, hash: String) async throws -> TLObject {
        try await rpc("auth.resendCode", ["phone_number": .string(phone), "phone_code_hash": .string(hash)])
    }
    func submitCode(phone: String, sent: TLObject, code: String) async throws {
        var fields: [String: TLValue] = ["phone_number": .string(phone), "phone_code_hash": sent["phone_code_hash"]]
        if sent["type"].object?.name == "auth.sentCodeTypeEmailCode" {
            fields["email_verification"] = .object(TLObject("emailVerificationCode", ["code": .string(code)]))
        } else { fields["phone_code"] = .string(code) }
        let auth = try await rpc("auth.signIn", fields)
        try finishLogin(auth)
    }
    func submitPassword(_ password: String) async throws {
        for attempt in 0..<2 {
            let params = try await rpc("account.getPassword")
            let proof = try SRP.proof(password: password, parameters: params)
            do {
                let auth = try await rpc("auth.checkPassword", ["password": .object(proof)])
                try finishLogin(auth); return
            } catch let error as TelegraphError where error.rpcMessage == "SRP_ID_INVALID" && attempt == 0 { continue }
        }
    }
    private func finishLogin(_ auth: TLObject) throws {
        guard auth.name == "auth.authorization", let user = auth["user"].object, user["id"].long != 0 else {
            throw TelegraphError.invalid("Use an existing Telegram account; account creation is not supported")
        }
        profile.userID = user["id"].long; profile.authorizedDCs.insert(profile.mainDC)
        users[user["id"].long] = user
        try save()
    }
    func validateSession() async throws {
        let result = try await rawRPC(TLObject("users.getUsers", ["id": .vector([.object(TLObject("inputUserSelf"))])]))
        guard let user = result.objects.first, user["self"].bool else { throw TelegraphError.invalid("Telegram did not recognize this session") }
        users[user["id"].long] = user; profile.userID = user["id"].long
        try save()
    }
    func clearExpiredSession() async throws {
        for value in sessions.values { await value.close() }
        sessions.removeAll()
        profile.keys.removeAll(); profile.authorizedDCs.removeAll(); profile.userID = nil
        try save()
    }
    func startMessaging() async throws {
        wantsMessaging = true
        syncing = true
        defer { syncing = false }
        let config = try await rpc("help.getConfig")
        profile.endpoints = config["dc_options"].objects.compactMap { option in
            guard !option["cdn"].bool, !option["ipv6"].bool, !option["tcpo_only"].bool,
                  let port = UInt16(exactly: option["port"].int) else { return nil }
            return DCEndpoint(id: option["id"].int, host: option["ip_address"].string, port: port, media: option["media_only"].bool)
        }
        try save()
        let state = try await rpc("updates.getState")
        applyState(state)
        messaging = true
        try await loadDialogs()
        let queue = buffered; buffered.removeAll(); syncing = false
        for event in queue { await consume(event) }
        sink.yield(.status("Connected"))
    }
    private func cache(_ object: TLObject) {
        for user in object["users"].objects {
            let id = user["id"].long
            if user["min"].bool, let old = users[id], old.fields["access_hash"] != nil { continue }
            users[id] = user
        }
        for chat in object["chats"].objects { chats[chat["id"].long] = chat }
    }
    private func title(_ id: Int64) -> String {
        if id == profile.userID { return "Saved Messages" }
        guard let user = users[id] else { return "User \(id)" }
        let full = [user["first_name"].string, user["last_name"].string].filter { !$0.isEmpty }.joined(separator: " ")
        if !full.isEmpty { return full }
        if !user["username"].string.isEmpty { return "@\(user["username"].string)" }
        return user["deleted"].bool ? "Deleted account" : "User \(id)"
    }
    private func inputPeer(_ id: Int64) -> TLObject {
        if id == profile.userID { return TLObject("inputPeerSelf") }
        return TLObject("inputPeerUser", ["user_id": .long(id), "access_hash": .long(users[id]?["access_hash"].long ?? 0)])
    }
    private func inputPeer(_ peer: TLObject) -> TLObject? {
        switch peer.name {
        case "peerUser": return inputPeer(peer["user_id"].long)
        case "peerChat": return TLObject("inputPeerChat", ["chat_id": peer["chat_id"]])
        case "peerChannel":
            guard let chat = chats[peer["channel_id"].long] else { return nil }
            return TLObject("inputPeerChannel", ["channel_id": peer["channel_id"], "access_hash": chat["access_hash"]])
        default: return nil
        }
    }
    private func loadDialogs() async throws {
        if let own = profile.userID { dialogs[own] = dialogs[own] ?? Conversation(id: own, title: "Saved Messages") }
        for folder: Int32 in [0, 1] {
            var offsetPeer = TLObject("inputPeerEmpty"), offsetID: Int32 = 0, offsetDate: Int32 = 0
            var seen: Set<String> = []
            for page in 0..<1000 {
                var fields: [String: TLValue] = [
                    "folder_id": .int(folder), "offset_date": .int(offsetDate), "offset_id": .int(offsetID),
                    "offset_peer": .object(offsetPeer), "limit": .int(100), "hash": .long(0)
                ]
                if page > 0 { fields["exclude_pinned"] = .bool(true) }
                let reply = try await rpc("messages.getDialogs", fields)
                cache(reply)
                let objects = reply["dialogs"].objects
                let topMessages = reply["messages"].objects
                for dialog in objects {
                    guard dialog.name == "dialog", let peer = dialog["peer"].object, peer.name == "peerUser" else { continue }
                    let id = peer["user_id"].long
                    let top = topMessages.first { $0["id"].int == dialog["top_message"].int && $0["peer_id"].object == peer }
                    let message = top.flatMap(ChatMessage.from)
                    dialogs[id] = Conversation(id: id, title: title(id), unread: dialog["unread_count"].int,
                        date: top?["date"].int ?? 0,
                        preview: message.map { $0.text.isEmpty ? ($0.media?.label ?? $0.unsupported ?? "") : $0.text } ?? "",
                        pinned: dialog["pinned"].bool)
                }
                emit()
                guard reply.name != "messages.dialogs", !objects.isEmpty,
                      let last = objects.last(where: { $0.name == "dialog" && !$0["pinned"].bool }),
                      let peer = last["peer"].object, let input = inputPeer(peer),
                      let top = topMessages.first(where: { $0["id"].int == last["top_message"].int && $0["peer_id"].object == peer }) else { break }
                offsetID = last["top_message"].int; offsetDate = top["date"].int; offsetPeer = input
                let cursor = "\(peer.name):\(peer["user_id"].long):\(peer["chat_id"].long):\(peer["channel_id"].long):\(offsetID)"
                guard seen.insert(cursor).inserted else { break }
            }
        }
    }
    func select(_ id: Int64) async {
        guard dialogs[id] != nil else { return }
        selectedID = id; messages = []; hasOlder = true
        selectionGeneration = UUID()
        loading = true; emit()
        let generation = selectionGeneration
        do {
            let reply = try await history(peer: id, offset: 0)
            guard selectedID == id, generation == selectionGeneration else { return }
            cache(reply)
            let loaded = reply["messages"].objects.compactMap(ChatMessage.from).filter { $0.peerID == id }
            merge(loaded); hasOlder = reply["messages"].objects.count >= 50
            loading = false; emit()
        } catch {
            guard generation == selectionGeneration else { return }
            loading = false; sink.yield(.status(describe(error))); emit()
        }
    }
    private func history(peer: Int64, offset: Int32) async throws -> TLObject {
        try await rpc("messages.getHistory", [
            "peer": .object(inputPeer(peer)), "offset_id": .int(offset), "offset_date": .int(0),
            "add_offset": .int(0), "limit": .int(50), "max_id": .int(0), "min_id": .int(0), "hash": .long(0)
        ])
    }
    func older() async {
        guard !loading, hasOlder, let peer = selectedID, let oldest = messages.first else { return }
        let generation = selectionGeneration
        loading = true; emit()
        do {
            let result = try await history(peer: peer, offset: oldest.id)
            guard generation == selectionGeneration else { return }
            cache(result)
            merge(result["messages"].objects.compactMap(ChatMessage.from).filter { $0.peerID == peer })
            hasOlder = result["messages"].objects.count >= 50
            loading = false; emit()
        } catch {
            guard generation == selectionGeneration else { return }
            loading = false; sink.yield(.status(describe(error))); emit()
        }
    }
    private func merge(_ incoming: [ChatMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in incoming { byID[message.id] = message }
        messages = byID.values.sorted { $0.id < $1.id }
    }
    func sendText(_ text: String, to peer: Int64, randomID: Int64) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard text.utf16.count <= 4096 else { throw TelegraphError.invalid("Messages are limited to 4,096 UTF-16 units") }
        let result = try await rpc("messages.sendMessage", [
            "peer": .object(inputPeer(peer)), "message": .string(text), "random_id": .long(randomID),
            "no_webpage": .bool(true)
        ])
        if result.name == "updateShortSentMessage" {
            let msg = ChatMessage(id: result["id"].int, peerID: peer, date: result["date"].int, outgoing: true, text: text, media: nil, unsupported: nil)
            apply(msg)
            await advance(result)
        } else { await consume(result) }
        emit()
    }
    func markRead(peer: Int64, maxID: Int32) async {
        guard maxID > (readMax[peer] ?? 0) else { return }
        readMax[peer] = maxID
        do {
            let result = try await rpc("messages.readHistory", ["peer": .object(inputPeer(peer)), "max_id": .int(maxID)])
            dialogs[peer]?.unread = 0
            await advance(result); emit()
        } catch {
            readMax.removeValue(forKey: peer)
            sink.yield(.status(describe(error)))
        }
    }
    private func apply(_ message: ChatMessage) {
        if dialogs[message.peerID] == nil { dialogs[message.peerID] = Conversation(id: message.peerID, title: title(message.peerID)) }
        if message.date >= (dialogs[message.peerID]?.date ?? 0) {
            dialogs[message.peerID]?.date = message.date
            dialogs[message.peerID]?.preview = message.text.isEmpty ? (message.media?.label ?? message.unsupported ?? "") : message.text
        }
        if selectedID == message.peerID { merge([message]) }
    }
    private func applyState(_ state: TLObject) {
        pts = state["pts"].int; qts = state["qts"].int; date = state["date"].int; seq = state["seq"].int
    }
    private func advance(_ update: TLObject) async {
        guard update.fields["pts"] != nil else { return }
        let next = update["pts"].int, count = update["pts_count"].int
        if next > pts {
            if Int64(pts) + Int64(count) == Int64(next) { pts = next }
            else { await recover() }
        }
    }
    private func consume(_ envelope: TLObject) async {
        if syncing { buffer(envelope); return }
        cache(envelope)
        if envelope.name == "updatesTooLong" { await recover(); return }
        if envelope.name == "updates" || envelope.name == "updatesCombined" {
            let newSeq = envelope["seq"].int
            let start = envelope.fields["seq_start"]?.int ?? newSeq
            if newSeq != 0 {
                if newSeq <= seq { return }
                if start != seq + 1 { buffer(envelope); await recover(); return }
            }
            for update in envelope["updates"].objects { await applyUpdate(update) }
            if newSeq != 0 { seq = max(seq, newSeq) }
            date = max(date, envelope["date"].int)
        } else if envelope.name == "updateShort" {
            if let update = envelope["update"].object { await applyUpdate(update) }
            date = max(date, envelope["date"].int)
        } else if envelope.name == "updateShortMessage" {
            let peer = envelope["user_id"].long
            var fields = envelope.fields
            fields["peer_id"] = .object(TLObject("peerUser", ["user_id": .long(peer)]))
            let update = TLObject("updateNewMessage", [
                "message": .object(TLObject("message", fields)), "pts": envelope["pts"], "pts_count": envelope["pts_count"]
            ])
            await applyUpdate(update)
            date = max(date, envelope["date"].int)
        } else { await applyUpdate(envelope) }
        emit()
    }
    private func applyUpdate(_ update: TLObject, difference: Bool = false) async {
        // Channel pts is a separate sequence and must never advance account pts.
        if update.name.contains("Channel") || update.name.contains("channel") { return }
        if !difference, update.fields["pts"] != nil {
            let next = update["pts"].int, count = update["pts_count"].int
            if count > 0, next <= pts { return }
            if next > pts, Int64(pts) + Int64(count) != Int64(next) { buffer(update); await recover(); return }
            pts = max(pts, next)
        }
        if let nextQTS = update.fields["qts"]?.int { qts = max(qts, nextQTS) }
        switch update.name {
        case "updateNewMessage", "updateEditMessage":
            if let obj = update["message"].object, let message = ChatMessage.from(obj) {
                let alreadyKnown = messages.contains { $0.id == message.id }
                apply(message)
                if update.name == "updateNewMessage", !message.outgoing, !alreadyKnown { dialogs[message.peerID]?.unread += 1 }
            }
        case "updateDeleteMessages":
            let ids = Set(update["messages"].array.map(\.int))
            messages.removeAll { ids.contains($0.id) }
        case "updateReadHistoryInbox":
            if let peer = update["peer"].object, peer.name == "peerUser" {
                dialogs[peer["user_id"].long]?.unread = update["still_unread_count"].int
            }
        case "updateUserName":
            let id = update["user_id"].long
            if var user = users[id] {
                user.fields["first_name"] = update["first_name"]; user.fields["last_name"] = update["last_name"]
                users[id] = user; dialogs[id]?.title = title(id)
            }
        default: break
        }
    }
    private func recover() async {
        guard messaging, !syncing else { return }
        syncing = true
        sink.yield(.status("Synchronizing…"))
        do {
            for _ in 0..<100 {
                let result = try await rpc("updates.getDifference", ["pts": .int(pts), "date": .int(date), "qts": .int(qts)])
                cache(result)
                if result.name == "updates.differenceEmpty" {
                    date = result["date"].int; seq = result["seq"].int; break
                }
                if result.name == "updates.differenceTooLong" {
                    let state = try await rpc("updates.getState")
                    applyState(state)
                    try await loadDialogs()
                    if let selectedID { await select(selectedID) }
                    break
                }
                for obj in result["new_messages"].objects {
                    if let message = ChatMessage.from(obj) { apply(message) }
                }
                for update in result["other_updates"].objects { await applyUpdate(update, difference: true) }
                let state = result["state"].object ?? result["intermediate_state"].object
                guard let state else { throw TelegraphError.invalid("Missing synchronization state") }
                applyState(state)
                if result.name == "updates.difference" { break }
            }
            if qts > 0 { _ = try await rawRPC(TLObject("messages.receivedQueue", ["max_qts": .int(qts)])) }
            syncing = false
            let queue = buffered; buffered.removeAll()
            for update in queue { await consume(update) }
            sink.yield(.status("Connected")); emit()
        } catch {
            syncing = false
            sink.yield(.status(describe(error)))
        }
    }
    private func authorizedMediaSession(dc: Int32) async throws -> MTSession {
        if let task = authorizing[dc] { return try await task.value }
        if let existing = mediaSessions[dc] { return existing }
        let task = Task<MTSession, any Error> { [self] in
            let target = self.session(dc: dc)
            try await target.connect()
            try Task.checkCancellation()
            if !self.profile.authorizedDCs.contains(dc) {
                let exported = try await self.rpc("auth.exportAuthorization", ["dc_id": .int(dc)])
                _ = try await self.rpc("auth.importAuthorization", ["id": exported["id"], "bytes": exported["bytes"]], on: target)
                self.profile.authorizedDCs.insert(dc); try self.save()
            }
            // A separate file connection avoids bulk traffic blocking live updates.
            let endpoint = self.profile.endpoints.first { $0.id == dc && $0.media } ??
                           self.profile.endpoints.first { $0.id == dc && !$0.media } ?? .bootstrap(test: self.test, id: dc)
            let media = MTSession(endpoint: endpoint, test: self.test, apiID: self.profile.apiID,
                                  auth: self.profile.keys[dc], codec: self.codec, makeTransport: self.transportFactory) {
                [weak self] auth in try await self?.record(auth)
            }
            self.mediaSessions[dc] = media
            do { try await media.connect() }
            catch {
                self.mediaSessions.removeValue(forKey: dc)
                await media.close()
                throw error
            }
            return media
        }
        authorizing[dc] = task
        do {
            let target = try await task.value
            mediaSessions[dc] = target; authorizing.removeValue(forKey: dc)
            // Non-home authorization connections are unnecessary after the transfer.
            if dc != profile.mainDC, let extra = sessions.removeValue(forKey: dc) { await extra.close() }
            return target
        } catch { authorizing.removeValue(forKey: dc); throw error }
    }
    func fileChunk(media: Media, offset: Int64, limit: Int32) async throws -> Data {
        guard !media.restricted else { throw TelegraphError.invalid("Telegram restricts saving this attachment") }
        var dc = media.dc
        for _ in 0..<3 {
            let target = try await authorizedMediaSession(dc: dc)
            do {
                let result = try await rpc("upload.getFile", ["location": .object(media.location), "offset": .long(offset), "limit": .int(limit)], on: target)
                guard result.name == "upload.file" else { throw TelegraphError.invalid("Unexpected file redirect; CDN downloads were not requested") }
                return result["bytes"].bytes
            } catch let error as TelegraphError {
                if let message = error.rpcMessage, message.hasPrefix("FILE_MIGRATE_"),
                   let newDC = Int32(message.dropFirst("FILE_MIGRATE_".count)), (1...(test ? 3 : 5)).contains(newDC) { dc = newDC; continue }
                throw error
            }
        }
        throw TelegraphError.invalid("Too many file data-center redirects")
    }
    func refreshMedia(_ media: Media) async throws -> Media {
        let reply = try await rpc("messages.getMessages", ["id": .vector([
            .object(TLObject("inputMessageID", ["id": .int(media.messageID)]))
        ])])
        guard let refreshed = reply["messages"].objects.compactMap(ChatMessage.from).first(where: {
            $0.id == media.messageID && $0.peerID == media.peerID
        })?.media, refreshed.id == media.id else { throw TelegraphError.invalid("The attachment is no longer available") }
        return refreshed
    }
    func logout() async throws {
        // Revoke each retained per-DC authorization before deleting local keys.
        for dc in profile.authorizedDCs.sorted() {
            let target = session(dc: dc)
            do { _ = try await rpc("auth.logOut", on: target) }
            catch let error as TelegraphError where ["AUTH_KEY_UNREGISTERED", "SESSION_REVOKED", "SESSION_EXPIRED"].contains(error.rpcMessage ?? "") {}
        }
        try persistence.delete()
        await close()
    }
    func close() async {
        stopped = true
        for task in eventTasks { task.cancel() }
        for task in authorizing.values { task.cancel() }
        for value in sessions.values { await value.close() }
        for value in mediaSessions.values { await value.close() }
        sink.finish()
    }
    func accountID() -> Int64 { profile.userID ?? 0 }
}

func describe(_ error: any Error) -> String {
    if let error = error as? TelegraphError, let rpc = error.rpcMessage {
        if rpc.hasPrefix("FLOOD_WAIT_") || rpc.hasPrefix("FLOOD_PREMIUM_WAIT_") {
            return "Telegram rate limit: try again in \(rpc.split(separator: "_").last ?? "?") seconds"
        }
        switch rpc {
        case "CHAT_WRITE_FORBIDDEN", "USER_IS_BLOCKED", "YOU_BLOCKED_USER": return "Telegram does not allow sending to this conversation"
        case "ALLOW_PAYMENT_REQUIRED", "PAYMENT_REQUIRED": return "This chat requires payment; paid messages are not supported"
        case "PHONE_CODE_INVALID": return "Incorrect login code"
        case "PHONE_CODE_EXPIRED": return "Login code expired; request a new code"
        case "PASSWORD_HASH_INVALID": return "Incorrect 2FA password"
        default: break
        }
    }
    return String(describing: error)
}
