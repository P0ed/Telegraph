import Foundation
import Darwin

enum InputEvent: Equatable, Sendable {
    case text(String), paste(String), up, down, left, right, home, end, pageUp, pageDown
    case enter, backspace, delete, tab, backtab, escape, quit, redraw, suspend, clear, deleteWord
    case mouse(x: Int, y: Int, button: Int, release: Bool)
}

struct InputDecoder {
    private var buffer: [UInt8] = []
    private var paste: [UInt8]?
    private let pasteEnd: [UInt8] = [27, 91, 50, 48, 49, 126]
    var pendingEscape: Bool { buffer == [27] && paste == nil }

    mutating func flushEscape() -> [InputEvent] {
        guard pendingEscape else { return [] }
        buffer.removeAll(); return [.escape]
    }
    mutating func feed(_ data: Data) -> [InputEvent] {
        buffer.append(contentsOf: data)
        var events: [InputEvent] = []
        while !buffer.isEmpty {
            if paste != nil {
                if buffer.starts(with: pasteEnd) {
                    events.append(.paste(String(decoding: paste!, as: UTF8.self)))
                    paste = nil; buffer.removeFirst(pasteEnd.count); continue
                }
                if buffer.count < pasteEnd.count, pasteEnd.starts(with: buffer) { break }
                if paste!.count < 32_768 { paste!.append(buffer[0]) }
                buffer.removeFirst(); continue
            }
            let b = buffer[0]
            if b == 27 {
                guard buffer.count >= 2 else { break }
                if buffer[1] != 91 {
                    if buffer[1] == 79, buffer.count < 3 { break }
                    if buffer[1] == 79, buffer.count >= 3 {
                        let code = buffer[2]; buffer.removeFirst(3)
                        if code == 72 { events.append(.home) }; if code == 70 { events.append(.end) }
                    } else { buffer.removeFirst(2) }
                    continue
                }
                // Legacy X10 mouse reporting, used when SGR mouse is unavailable.
                if buffer.count >= 3, buffer[2] == 77 {
                    guard buffer.count >= 6 else { break }
                    let button = Int(buffer[3]) - 32
                    events.append(.mouse(x: Int(buffer[4]) - 33, y: Int(buffer[5]) - 33,
                                         button: button, release: button & 3 == 3))
                    buffer.removeFirst(6); continue
                }
                guard let end = buffer.indices.dropFirst(2).first(where: { (0x40...0x7e).contains(buffer[$0]) }) else {
                    if buffer.count > 128 { buffer.removeAll() }
                    break
                }
                let seq = String(decoding: buffer[2...end], as: UTF8.self)
                buffer.removeFirst(end + 1)
                if seq == "200~" { paste = []; continue }
                if seq.hasPrefix("<"), seq.hasSuffix("M") || seq.hasSuffix("m") {
                    let fields = seq.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
                    if fields.count == 3, fields[1] > 0, fields[2] > 0, fields[1] < 100_000, fields[2] < 100_000 {
                        events.append(.mouse(x: fields[1] - 1, y: fields[2] - 1, button: fields[0], release: seq.hasSuffix("m")))
                    }
                    continue
                }
                let mapping: [String: InputEvent] = ["A": .up, "B": .down, "C": .right, "D": .left,
                    "H": .home, "F": .end, "1~": .home, "4~": .end, "7~": .home, "8~": .end,
                    "3~": .delete, "5~": .pageUp, "6~": .pageDown, "Z": .backtab]
                if let event = mapping[seq] { events.append(event) }
                continue
            }
            if b < 32 || b == 127 {
                buffer.removeFirst()
                let mapping: [UInt8: InputEvent] = [1: .home, 3: .quit, 4: .quit, 5: .end, 8: .backspace,
                    9: .tab, 10: .text("\n"), 12: .redraw, 13: .enter, 21: .clear, 23: .deleteWord,
                    26: .suspend, 127: .backspace]
                if let event = mapping[b] { events.append(event) }
                continue
            }
            let count: Int
            if b < 128 { count = 1 }
            else if b >= 0xc2, b <= 0xdf { count = 2 }
            else if b <= 0xef, b >= 0xe0 { count = 3 }
            else if b <= 0xf4, b >= 0xf0 { count = 4 }
            else { buffer.removeFirst(); continue }
            guard buffer.count >= count else { break }
            let bytes = buffer.prefix(count)
            if let text = String(bytes: bytes, encoding: .utf8) { events.append(.text(text)) }
            buffer.removeFirst(count)
        }
        return events
    }
}

enum TerminalText {
    private static let utf8Locale: Void = {
        if setlocale(LC_CTYPE, "") == nil { setlocale(LC_CTYPE, "en_US.UTF-8") }
    }()
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || ($0.value >= 32 && !($0.value >= 0x7f && $0.value <= 0x9f))
        })).replacingOccurrences(of: "\t", with: "    ")
    }
    static func width(_ character: Character) -> Int {
        _ = utf8Locale
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.value == 0xfe0f || $0.value == 0x20e3 }) { return 2 }
        if !scalars.contains(where: { $0.value == 0xfe0e }), scalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        return max(0, scalars.map { max(0, Int(wcwidth(wchar_t($0.value)))) }.max() ?? 0)
    }
    static func width(_ text: String) -> Int { text.reduce(0) { $0 + width($1) } }
    static func fit(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        var output = "", used = 0
        for c in clean(text).replacingOccurrences(of: "\n", with: " ") {
            let size = self.width(c)
            if used + size > width { break }
            output.append(c); used += size
        }
        return output + String(repeating: " ", count: width - used)
    }
    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var lines: [String] = [], line = "", used = 0
        for c in clean(text) {
            if c == "\n" { lines.append(line); line = ""; used = 0; continue }
            let size = self.width(c)
            if used + size > width { lines.append(line); line = ""; used = 0 }
            if size <= width { line.append(c); used += size }
        }
        lines.append(line); return lines
    }
}

@MainActor
final class TerminalIO {
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private var original = termios()
    private var originalFlags: Int32 = 0
    private var raw = false
    private var secret = false
    private var secretBeforeSuspend = false
    private var reader: (any DispatchSourceRead)?
    private var writer: (any DispatchSourceWrite)?
    private var outputBuffer = Data()
    private var signals: [any DispatchSourceSignal] = []
    var onSignal: ((Int32) -> Void)?
    var onData: ((Data) -> Void)?
    var onEOF: (() -> Void)?

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO, monitorSignals: Bool = true) throws {
        inputDescriptor = input; outputDescriptor = output
        guard isatty(input) == 1, isatty(output) == 1 else {
            throw TelegraphError.invalid("Telegraph needs an interactive terminal. Use --help for usage.")
        }
        guard tcgetattr(input, &original) == 0 else { throw TelegraphError.invalid("Could not read terminal settings") }
        originalFlags = fcntl(input, F_GETFL)
        for number in monitorSignals ? [SIGINT, SIGTERM, SIGHUP, SIGWINCH, SIGTSTP, SIGCONT] : [] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.onSignal?(number) }
            }
            source.resume(); signals.append(source)
        }
    }
    var size: (width: Int, height: Int) {
        var size = winsize()
        if ioctl(outputDescriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (80, 24)
    }
    func write(_ string: String) {
        outputBuffer.append(contentsOf: string.utf8)
        flushOutput()
    }
    private func flushOutput() {
        let flags = fcntl(outputDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(outputDescriptor, F_SETFL, flags | O_NONBLOCK) }
        defer { if flags >= 0 { _ = fcntl(outputDescriptor, F_SETFL, flags) } }
        while !outputBuffer.isEmpty {
            let count = outputBuffer.withUnsafeBytes { Darwin.write(outputDescriptor, $0.baseAddress!, $0.count) }
            if count > 0 { outputBuffer.removeFirst(count); continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: outputDescriptor, queue: .main)
                    source.setEventHandler { [weak self] in
                        Task { @MainActor in self?.flushOutput() }
                    }
                    source.resume(); writer = source
                }
                return
            }
            outputBuffer.removeAll(); break
        }
        writer?.cancel(); writer = nil
    }
    func drainOutput() async {
        let deadline = Date().addingTimeInterval(0.5)
        while !outputBuffer.isEmpty, Date() < deadline {
            if Task.isCancelled { break }
            flushOutput()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func readPrompt(_ label: String, hidden: Bool = false) async throws -> String {
        write(label)
        if hidden {
            var mode = original; mode.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(inputDescriptor, TCSANOW, &mode) == 0 else { throw TelegraphError.invalid("Could not hide password input") }
            secret = true
        }
        defer {
            if hidden { restorePrompt(); write("\n") }
        }
        await drainOutput()
        let line = await Task.detached { readLine(strippingNewline: true) }.value
        guard let line else { throw TelegraphError.cancelled }
        return line
    }
    private func restorePrompt() {
        if secret { tcsetattr(inputDescriptor, TCSANOW, &original); secret = false }
    }
    func start() throws {
        guard !raw else { return }
        restorePrompt()
        var mode = original; cfmakeraw(&mode)
        guard tcsetattr(inputDescriptor, TCSANOW, &mode) == 0 else { throw TelegraphError.invalid("Could not enter terminal mode") }
        tcflush(inputDescriptor, TCIFLUSH)
        raw = true
        _ = fcntl(inputDescriptor, F_SETFL, originalFlags | O_NONBLOCK)
        write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[2J\u{1b}[H")
        let source = DispatchSource.makeReadSource(fileDescriptor: inputDescriptor, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.raw else { return }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(self.inputDescriptor, &bytes, bytes.count)
                if count > 0 { self.onData?(Data(bytes.prefix(count))) }
                else if count == 0 { self.onEOF?() }
            }
        }
        source.resume(); reader = source
    }
    func restore() {
        restorePrompt()
        guard raw else { return }
        reader?.cancel(); reader = nil
        write("\u{1b}[0m\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h\u{1b}[?1049l")
        _ = fcntl(inputDescriptor, F_SETFL, originalFlags)
        tcsetattr(inputDescriptor, TCSANOW, &original)
        tcflush(inputDescriptor, TCIFLUSH)
        raw = false
    }
    func suspend() {
        secretBeforeSuspend = secret
        restore()
        kill(getpid(), SIGSTOP)
    }
    func resumePrompt() {
        if secretBeforeSuspend {
            var mode = original; mode.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(inputDescriptor, TCSANOW, &mode); secret = true
            secretBeforeSuspend = false
        }
    }
}
