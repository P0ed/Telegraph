import Foundation
import Darwin
import Testing
@testable import TelegraphCore

@Test func fragmentedKeysMouseAndPaste() {
    var decoder = InputDecoder()
    #expect(decoder.feed(Data([27, 91])) == [])
    #expect(decoder.feed(Data("A".utf8)) == [.up])
    #expect(decoder.feed(Data("\u{1b}[<0;31;7M".utf8)) == [.mouse(x: 30, y: 6, button: 0, release: false)])
    #expect(decoder.feed(Data("\u{1b}[<0;31;7m".utf8)) == [.mouse(x: 30, y: 6, button: 0, release: true)])
    #expect(decoder.feed(Data([27, 91, 77, 32, 63, 39])) == [.mouse(x: 30, y: 6, button: 0, release: false)])
    #expect(decoder.feed(Data("\u{1b}[200~hello\n".utf8)) == [])
    #expect(decoder.feed(Data("world\u{1b}[20".utf8)) == [])
    #expect(decoder.feed(Data("1~".utf8)) == [.paste("hello\nworld")])
    #expect(decoder.feed(Data([27])) == [])
    #expect(decoder.flushEscape() == [.escape])
    let emoji = Array("🌍".utf8)
    #expect(decoder.feed(Data(emoji.prefix(2))) == [])
    #expect(decoder.feed(Data(emoji.dropFirst(2))) == [.text("🌍")])
    #expect(decoder.feed(Data([13, 10, 3])) == [.enter, .text("\n"), .quit])
}

@Test func unicodeLayoutAndEscapeSanitizing() {
    #expect(TerminalText.width("界") == 2)
    #expect(TerminalText.width("e\u{301}") == 1)
    #expect(TerminalText.width("👩‍💻") == 2)
    #expect(TerminalText.width("🇩🇪") == 2)
    #expect(TerminalText.fit("界界x", width: 5) == "界界x")
    #expect(TerminalText.wrap("a界b\nc", width: 3) == ["a界", "b", "c"])
    #expect(!TerminalText.clean("\u{1b}[2J\u{07}Hello").contains("\u{1b}"))
    #expect(!TerminalText.clean("\u{9b}31m").unicodeScalars.contains("\u{9b}"))
    let media = Media(kind: .image, id: 1, dc: 2, size: 1, fileExtension: "jpg",
                      location: TLObject("inputPhotoFileLocation"), peerID: 1, messageID: 1, restricted: false)
    let msg = ChatMessage(id: 1, peerID: 1, date: 0, outgoing: false, text: "界👩‍💻 hello", media: media, unsupported: nil)
    for width in [10, 20, 60] {
        let lines = HistoryLayout.lines([msg], width: width)
        #expect(lines.allSatisfy { TerminalText.width($0.text) <= max(width, 20) })
        #expect(lines.filter { $0.media != nil }.count == 1)
        let hit = MediaHit(x: 25, y: lines.firstIndex(where: { $0.media != nil })!, width: 7, media: media)
        #expect(hit.contains(x: 25, y: hit.y))
        #expect(!hit.contains(x: 24, y: hit.y))
        #expect(!hit.contains(x: 32, y: hit.y))
    }
}

@Test @MainActor func terminalRestoresSettingsInPTY() throws {
    var master: Int32 = -1, slave: Int32 = -1
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw TelegraphError.invalid("openpty failed") }
    defer { Darwin.close(master); Darwin.close(slave) }
    var before = termios(), during = termios(), after = termios()
    #expect(tcgetattr(slave, &before) == 0)
    let flags = fcntl(slave, F_GETFL)
    let io = try TerminalIO(input: slave, output: slave, monitorSignals: false)
    #expect(io.size.width == 80 && io.size.height == 24)
    try io.start()
    #expect(tcgetattr(slave, &during) == 0)
    #expect(during.c_lflag & tcflag_t(ICANON | ECHO) == 0)
    io.restore()
    #expect(tcgetattr(slave, &after) == 0)
    #expect(after.c_lflag == before.c_lflag)
    #expect(after.c_iflag == before.c_iflag)
    #expect(after.c_oflag == before.c_oflag)
    let restoredFlags = fcntl(slave, F_GETFL)
    #expect(restoredFlags & (O_NONBLOCK | O_APPEND | O_ASYNC | O_ACCMODE) == flags & (O_NONBLOCK | O_APPEND | O_ASYNC | O_ACCMODE))
}
