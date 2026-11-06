import Foundation

// Interpret the small VT subset emitted by Telegraph, with an emoji width that
// differs from its layout estimate to reproduce terminal-specific wrapping.
struct TestTerminalScreen {
    private var cells: [[String]]
    private let width: Int, height: Int, emojiWidth: Int
    private var x = 0, y = 0, wrapPending = false
    private(set) var autowrap = true
    private(set) var scrolls = 0

    init(width: Int, height: Int, emojiWidth: Int) {
        self.width = width; self.height = height; self.emojiWidth = emojiWidth
        cells = Array(repeating: Array(repeating: " ", count: width), count: height)
    }
    func cell(row: Int, column: Int) -> String { cells[row][column] }
    func line(_ row: Int, from column: Int = 0) -> String { cells[row].dropFirst(column).joined() }
    mutating func feed(_ output: String) {
        var remaining = output[...]
        while !remaining.isEmpty {
            if remaining.hasPrefix("\u{1b}[") {
                remaining = remaining.dropFirst(2)
                guard let end = remaining.firstIndex(where: { character in
                    character.unicodeScalars.count == 1 && (0x40...0x7e).contains(character.unicodeScalars.first!.value)
                }) else { return }
                control(String(remaining[..<end]), final: remaining[end])
                remaining = remaining[remaining.index(after: end)...]
                continue
            }
            let character = remaining.removeFirst()
            switch character {
            case "\r\n": x = 0; newline()
            case "\r": x = 0; wrapPending = false
            case "\n": newline()
            default:
                let size = character == "✌🏻" ? emojiWidth : 1
                if autowrap && (wrapPending || x + size > width) { x = 0; newline() }
                guard x + size <= width else { continue }
                cells[y][x] = String(character)
                for offset in 1..<size { cells[y][x + offset] = "" }
                wrapPending = x + size == width
                x = min(width - 1, x + size)
            }
        }
    }
    private mutating func newline() {
        wrapPending = false
        if y == height - 1 {
            cells.removeFirst(); cells.append(Array(repeating: " ", count: width)); scrolls += 1
        } else { y += 1 }
    }
    private mutating func control(_ parameters: String, final: Character) {
        let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        switch final {
        case "H":
            y = min(height - 1, max(0, (values.first ?? 1) - 1))
            x = min(width - 1, max(0, (values.count > 1 ? values[1] : 1) - 1))
            wrapPending = false
        case "J" where parameters == "2":
            cells = Array(repeating: Array(repeating: " ", count: width), count: height)
        case "K":
            let start = parameters == "2" ? 0 : x
            for column in start..<width { cells[y][column] = " " }
        case "h", "l":
            if parameters == "?7" { autowrap = final == "h"; wrapPending = false }
        default: break // SGR styles, mouse reporting, alternate screen, and cursor visibility.
        }
    }
}
