import Foundation
import Darwin

struct HistoryLine: Sendable {
    let text: String
    var media: Media?
    var mediaKey: String? { media.map { "\($0.messageID):\($0.key)" } }
}
struct MediaHit: Sendable {
    let x: Int, y: Int, width: Int
    let media: Media
    func contains(x: Int, y: Int) -> Bool { self.y == y && x >= self.x && x < self.x + width }
}
struct HistoryLayout {
    static func lines(_ messages: [ChatMessage], width: Int) -> [HistoryLine] {
        var result: [HistoryLine] = []
        for message in messages {
            let date = Date(timeIntervalSince1970: TimeInterval(message.date))
            let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            result.append(HistoryLine(text: "\(time)  \(message.outgoing ? "You" : "Them")"))
            if !message.text.isEmpty {
                result += TerminalText.wrap(message.text, width: max(1, width - 2)).map { HistoryLine(text: "  " + $0) }
            }
            if let media = message.media {
                result.append(HistoryLine(text: "  \(media.label)\(media.restricted ? " (saving restricted)" : "")", media: media))
            }
            if let other = message.unsupported { result.append(HistoryLine(text: "  \(other)")) }
            result.append(HistoryLine(text: ""))
        }
        return result
    }
}

@MainActor
final class TerminalUI {
    private enum Focus: Int { case chats, history, composer }
    private struct Draft {
        var characters: [Character] = []
        var cursor = 0
        var randomID: Int64?
        var text: String { String(characters) }
    }
    private let terminal: TerminalIO
    private let client: TelegramClient
    private let mediaStore: MediaStore
    private let opener = MediaOpener()
    private var decoder = InputDecoder()
    private var focus = Focus.chats
    private var snapshot = ClientSnapshot(conversations: [], selectedID: nil, messages: [], loading: false, hasOlder: true)
    private var chatCursor: Int64?
    private var chatOffset = 0, scrollOffset = 0
    private var mediaSelection: String?
    private var hits: [MediaHit] = []
    private var drafts: [Int64: Draft] = [:]
    private var sending: Set<Int64> = []
    private var downloading: Set<String> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var eventTask: Task<Void, Never>?
    private var finished: CheckedContinuation<Int32, Never>?
    private var status = "Connecting…"
    private var stopped = false
    private var olderRequested = false
    private var cachedHistory: [HistoryLine]?
    private var cachedHistoryWidth = 0

    init(terminal: TerminalIO, client: TelegramClient, downloadRoot: URL) {
        self.terminal = terminal; self.client = client
        mediaStore = MediaStore(root: downloadRoot)
    }
    private var sidebar: Int { terminal.size.width >= 90 ? 26 : 22 }
    private var historyWidth: Int { max(1, terminal.size.width - sidebar - 2) }
    private var visibleRows: Int { max(1, terminal.size.height - 5) }
    private var layout: [HistoryLine] {
        if let cachedHistory, cachedHistoryWidth == historyWidth { return cachedHistory }
        let lines = HistoryLayout.lines(snapshot.messages, width: historyWidth)
        cachedHistory = lines; cachedHistoryWidth = historyWidth
        return lines
    }
    private func launch(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { await work(); self.tasks.removeValue(forKey: id) }
    }
    func run() async throws -> Int32 {
        terminal.onData = { [weak self] data in self?.input(data) }
        terminal.onEOF = { [weak self] in self?.stop(0) }
        terminal.onSignal = { [weak self] signal in
            guard let self else { return }
            switch signal {
            case SIGWINCH: self.render()
            case SIGTSTP: self.terminal.suspend()
            case SIGCONT:
                do { try self.terminal.start(); self.render() }
                catch { self.stop(1) }
            default: self.stop(signal == SIGINT ? 130 : 128 + signal)
            }
        }
        try terminal.start()
        eventTask = Task {
            for await event in client.events {
                guard !self.stopped else { break }
                switch event {
                case .status(let text): self.status = text
                case .snapshot(let value): self.update(value)
                }
                self.render()
            }
        }
        launch {
            do { try await self.client.startMessaging() }
            catch { self.status = describe(error); self.render() }
        }
        render()
        let code = await withCheckedContinuation { finished = $0 }
        await client.close()
        await mediaStore.cancelAll()
        await terminal.drainOutput()
        return code
    }
    private func stop(_ code: Int32) {
        guard !stopped else { return }
        stopped = true; terminal.restore()
        eventTask?.cancel()
        for task in tasks.values { task.cancel() }
        opener.close()
        finished?.resume(returning: code); finished = nil
    }
    private func update(_ next: ClientSnapshot) {
        let old = snapshot
        if old.selectedID != next.selectedID {
            scrollOffset = 0; mediaSelection = nil; olderRequested = false
        } else if scrollOffset > 0, let previous = old.messages.last?.id,
                  let last = next.messages.last?.id, last > previous {
            let oldCount = HistoryLayout.lines(old.messages, width: historyWidth).count
            let newCount = HistoryLayout.lines(next.messages, width: historyWidth).count
            scrollOffset += max(0, newCount - oldCount)
        }
        if olderRequested, old.loading && !next.loading {
            if next.messages.first?.id != old.messages.first?.id { scrollOffset += visibleRows / 2 }
            olderRequested = false
        }
        snapshot = next
        cachedHistory = nil
        if chatCursor == nil || !next.conversations.contains(where: { $0.id == chatCursor }) {
            chatCursor = next.conversations.first?.id
        }
        if scrollOffset == 0, let peer = next.selectedID, let latest = next.messages.last?.id {
            launch { await self.client.markRead(peer: peer, maxID: latest) }
        }
    }
    private func input(_ data: Data) {
        for event in decoder.feed(data) { handle(event) }
        if decoder.pendingEscape {
            Task {
                try? await Task.sleep(for: .milliseconds(40))
                for event in self.decoder.flushEscape() { self.handle(event) }
                self.render()
            }
        }
        render()
    }
    private func edit(_ action: (inout Draft) -> Void) {
        guard let peer = snapshot.selectedID, !sending.contains(peer) else { return }
        var draft = drafts[peer] ?? Draft()
        let before = draft.text
        action(&draft)
        draft.cursor = min(max(0, draft.cursor), draft.characters.count)
        if draft.text != before { draft.randomID = nil }
        drafts[peer] = draft
    }
    private func handle(_ input: InputEvent) {
        guard !stopped else { return }
        switch input {
        case .quit: stop(0)
        case .suspend: terminal.suspend()
        case .redraw: break
        case .escape: focus = .chats
        case .tab, .backtab:
            let step = input == .tab ? 1 : 2
            focus = Focus(rawValue: (focus.rawValue + step) % 3)!
            if focus == .history, mediaSelection == nil { moveMedia(-1) }
        case .up, .down:
            let direction = input == .up ? -1 : 1
            if focus == .chats { moveChat(direction) }
            else if focus == .history { moveMedia(direction) }
        case .pageUp: scroll(visibleRows - 1)
        case .pageDown: scroll(-(visibleRows - 1))
        case .enter:
            switch focus {
            case .chats: openChat()
            case .history:
                if let line = layout.first(where: { $0.mediaKey == mediaSelection }), let media = line.media { openMedia(media) }
            case .composer: send()
            }
        case .text(let text), .paste(let text):
            guard focus == .composer else { return }
            let cleaned = Array(TerminalText.clean(text))
            edit { draft in
                let room = max(0, 4096 - draft.text.utf16.count)
                var insert: [Character] = [], used = 0
                for c in cleaned {
                    let size = String(c).utf16.count
                    if used + size > room { break }
                    insert.append(c); used += size
                }
                draft.characters.insert(contentsOf: insert, at: draft.cursor)
                draft.cursor += insert.count
            }
        case .left: if focus == .composer { edit { $0.cursor = max(0, $0.cursor - 1) } }
        case .right: if focus == .composer { edit { $0.cursor += 1 } }
        case .home: if focus == .composer { edit { $0.cursor = 0 } } else { scroll(Int.max / 2) }
        case .end: if focus == .composer { edit { $0.cursor = $0.characters.count } } else { scrollOffset = 0 }
        case .backspace:
            if focus == .composer { edit { if $0.cursor > 0 { $0.characters.remove(at: $0.cursor - 1); $0.cursor -= 1 } } }
        case .delete:
            if focus == .composer { edit { if $0.cursor < $0.characters.count { $0.characters.remove(at: $0.cursor) } } }
        case .clear:
            if focus == .composer { edit { $0.characters.removeSubrange(0..<$0.cursor); $0.cursor = 0 } }
        case .deleteWord:
            if focus == .composer {
                edit {
                    while $0.cursor > 0, $0.characters[$0.cursor - 1].isWhitespace { $0.characters.remove(at: $0.cursor - 1); $0.cursor -= 1 }
                    while $0.cursor > 0, !$0.characters[$0.cursor - 1].isWhitespace { $0.characters.remove(at: $0.cursor - 1); $0.cursor -= 1 }
                }
            }
        case .mouse(let x, let y, let button, let release):
            guard !release else { break }
            if button & 64 != 0 {
                let delta = button & 1 == 0 ? 3 : -3
                if x < sidebar { moveChat(-delta) } else { scroll(delta) }
            } else if button & 3 == 0 {
                if let hit = hits.first(where: { $0.contains(x: x, y: y) }) { openMedia(hit.media) }
                else if x < sidebar, y >= 1, y < 1 + visibleRows {
                    let index = chatOffset + y - 1
                    if snapshot.conversations.indices.contains(index) {
                        chatCursor = snapshot.conversations[index].id; openChat()
                    }
                } else if y >= terminal.size.height - 4 { focus = .composer }
                else if x > sidebar { focus = .history }
            }
        }
    }
    private func moveChat(_ direction: Int) {
        guard !snapshot.conversations.isEmpty else { return }
        let current = snapshot.conversations.firstIndex { $0.id == chatCursor } ?? 0
        let index = min(max(0, current + direction), snapshot.conversations.count - 1)
        chatCursor = snapshot.conversations[index].id
        if index < chatOffset { chatOffset = index }
        if index >= chatOffset + visibleRows { chatOffset = index - visibleRows + 1 }
    }
    private func openChat() {
        guard let id = chatCursor else { return }
        focus = .composer; scrollOffset = 0
        launch { await self.client.select(id) }
    }
    private func scroll(_ amount: Int) {
        let maxOffset = max(0, layout.count - visibleRows)
        scrollOffset = min(maxOffset, max(0, scrollOffset + amount))
        if amount > 0, scrollOffset >= maxOffset, snapshot.hasOlder, !snapshot.loading, !olderRequested {
            olderRequested = true
            launch { await self.client.older() }
        }
    }
    private func moveMedia(_ direction: Int) {
        let lines = layout
        let indices = lines.indices.filter { lines[$0].media != nil }
        guard !indices.isEmpty else { scroll(direction < 0 ? 1 : -1); return }
        let current = indices.firstIndex { lines[$0].mediaKey == mediaSelection }
        let position = current.map { min(max(0, $0 + direction), indices.count - 1) } ?? (direction < 0 ? indices.count - 1 : 0)
        let index = indices[position]
        mediaSelection = lines[index].mediaKey
        let end = max(0, lines.count - scrollOffset), start = max(0, end - visibleRows)
        if index < start { scrollOffset = max(0, lines.count - index - visibleRows) }
        if index >= end { scrollOffset = max(0, lines.count - index - 1) }
    }
    private func send() {
        guard let peer = snapshot.selectedID, !sending.contains(peer), var draft = drafts[peer],
              !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { if draft.randomID == nil { draft.randomID = try Crypto.randomID() } }
        catch { status = describe(error); return }
        drafts[peer] = draft; sending.insert(peer)
        let text = draft.text, token = draft.randomID!
        status = "Sending…"
        launch {
            defer { self.sending.remove(peer); self.render() }
            do {
                try await self.client.sendText(text, to: peer, randomID: token)
                self.drafts[peer] = Draft()
                if self.snapshot.selectedID == peer { self.scrollOffset = 0 }
                self.status = "Sent"
            } catch {
                self.status = "\(describe(error)) — Enter retries the same message"
            }
        }
    }
    private func openMedia(_ media: Media) {
        guard !media.restricted else { status = "Telegram restricts saving this attachment"; return }
        guard downloading.insert(media.key).inserted else { return }
        status = "Downloading \(media.label)…"
        launch { [self] in
            defer { self.downloading.remove(media.key); self.render() }
            do {
                let url = try await self.mediaStore.obtain(media, fetch: { [client = self.client] media, offset, limit in
                    try await client.fileChunk(media: media, offset: offset, limit: limit)
                }, refresh: { [client = self.client] media in
                    try await client.refreshMedia(media)
                }, progress: { [weak self] downloaded, total in
                    await self?.progress(media: media, downloaded: downloaded, total: total)
                })
                guard !self.stopped else { return }
                try self.opener.open(url)
                self.status = "Opened \(media.label) — \(url.lastPathComponent)"
            } catch { self.status = describe(error) }
        }
    }
    private func progress(media: Media, downloaded: Int64, total: Int64) {
        status = "\(media.label) \(downloaded * 100 / max(1, total))% — \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
        render()
    }
    private func render() {
        guard !stopped else { return }
        let (width, height) = terminal.size
        hits.removeAll()
        guard width >= 60, height >= 16 else {
            terminal.write("\u{1b}[H\u{1b}[2J" + TerminalText.fit("Resize to at least 60 × 16. Ctrl-C quits.", width: width))
            return
        }
        let leftWidth = sidebar, rightWidth = width - leftWidth - 1
        var left = [String](repeating: "", count: height), right = left
        left[0] = " TELEGRAPH"
        let title = snapshot.conversations.first { $0.id == snapshot.selectedID }?.title ?? "Select a conversation"
        right[0] = " \(title)"
        chatOffset = min(chatOffset, max(0, snapshot.conversations.count - visibleRows))
        for row in 0..<visibleRows {
            let index = chatOffset + row
            if snapshot.conversations.indices.contains(index) {
                let dialog = snapshot.conversations[index]
                let cursor = dialog.id == chatCursor ? "›" : " "
                let unread = dialog.unread > 0 ? " (\(dialog.unread))" : ""
                left[row + 1] = "\(cursor) \(dialog.title)\(unread)"
            }
        }
        let lines = layout
        scrollOffset = min(scrollOffset, max(0, lines.count - visibleRows))
        let end = max(0, lines.count - scrollOffset), start = max(0, end - visibleRows)
        if snapshot.loading, lines.isEmpty { right[1] = " Loading history…" }
        else if snapshot.selectedID != nil, lines.isEmpty { right[1] = " No messages yet" }
        for (row, index) in (start..<end).enumerated() {
            let line = lines[index]
            right[row + 1] = line.text
            if let media = line.media {
                hits.append(MediaHit(x: leftWidth + 3, y: row + 1, width: media.label.count, media: media))
            }
        }
        left[height - 4] = focus == .chats ? " Chats •" : " Chats"
        right[height - 4] = focus == .history ? " History •  Enter opens media" : " History"
        if snapshot.loading { right[height - 4] += " — loading…" }
        let draft = snapshot.selectedID.flatMap { drafts[$0] } ?? Draft()
        let flat: (Character) -> String = { $0 == "\n" ? "↵" : String($0) }
        let before = draft.characters.prefix(draft.cursor).map(flat).joined()
        let after = draft.characters.dropFirst(draft.cursor).map(flat).joined()
        let editWidth = max(1, rightWidth - 3)
        var visibleBefore = "", used = 0
        for character in before.reversed() {
            let size = TerminalText.width(character)
            if used + size >= editWidth { break }
            visibleBefore.insert(character, at: visibleBefore.startIndex); used += size
        }
        right[height - 3] = "> " + visibleBefore + after
        left[height - 3] = focus == .composer ? " Compose •" : " Compose"
        var rows: [String] = []
        for row in 0..<height {
            if row == height - 2 {
                rows.append("\u{1b}[0m" + TerminalText.fit(" " + status, width: width)); continue
            }
            if row == height - 1 {
                rows.append("\u{1b}[2m" + TerminalText.fit(" Tab focus · ↑↓ select · Enter open/send · PgUp/PgDn scroll · Ctrl-J newline · Ctrl-C quit", width: width) + "\u{1b}[0m")
                continue
            }
            let leftHighlighted = row == 0 || (focus == .chats && row > 0 && row <= visibleRows &&
                snapshot.conversations.indices.contains(chatOffset + row - 1) &&
                snapshot.conversations[chatOffset + row - 1].id == chatCursor)
            let mediaHighlighted = row > 0 && row <= visibleRows && start + row - 1 < end &&
                focus == .history && lines[start + row - 1].mediaKey != nil && lines[start + row - 1].mediaKey == mediaSelection
            let leftStyle = leftHighlighted ? "\u{1b}[7m" : "\u{1b}[0m"
            let rightStyle = row == 0 || mediaHighlighted ? "\u{1b}[7m" : "\u{1b}[0m"
            rows.append(leftStyle + TerminalText.fit(left[row], width: leftWidth) + "\u{1b}[0m│" +
                        rightStyle + TerminalText.fit(right[row], width: rightWidth) + "\u{1b}[0m")
        }
        var frame = "\u{1b}[?25l\u{1b}[H" + rows.joined(separator: "\r\n")
        if focus == .composer, snapshot.selectedID != nil {
            let x = leftWidth + 4 + TerminalText.width(visibleBefore)
            frame += "\u{1b}[\(height - 2);\(min(width, x))H\u{1b}[?25h"
        }
        terminal.write(frame)
    }
}
