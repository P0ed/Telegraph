import Foundation
import Testing
@testable import TelegraphCore

private func mediaFixture(size: Int64, restricted: Bool = false) -> Media {
    Media(kind: .gif, id: 123, dc: 2, size: size, fileExtension: "mp4",
          location: TLObject("inputDocumentFileLocation", ["file_reference": .bytes(Data([1]))]),
          peerID: 10, messageID: 20, restricted: restricted)
}

private actor FileServer {
    let bytes: Data
    var requests = 0
    var refreshes = 0
    var expire = false
    var failAfterFirst = false
    init(bytes: Data, expire: Bool = false, fail: Bool = false) { self.bytes = bytes; self.expire = expire; failAfterFirst = fail }
    func fetch(_ media: Media, _ offset: Int64, _ limit: Int32) throws -> Data {
        requests += 1
        if expire && media.location["file_reference"].bytes == Data([1]) { throw TelegraphError.rpc(400, "FILE_REFERENCE_EXPIRED") }
        if failAfterFirst && offset > 0 { throw TelegraphError.connection("Simulated interruption") }
        return bytes.slice(Int(offset)..<min(bytes.count, Int(offset) + Int(limit)))
    }
    func refresh(_ media: Media) -> Media {
        refreshes += 1
        return Media(kind: media.kind, id: media.id, dc: media.dc, size: media.size, fileExtension: media.fileExtension,
                     location: TLObject("inputDocumentFileLocation", ["file_reference": .bytes(Data([2]))]),
                     peerID: media.peerID, messageID: media.messageID, restricted: media.restricted)
    }
}

@Test func downloadSingleFlightAtomicCompletionAndCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegraph-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(repeating: 42, count: 700_001), server = FileServer(bytes: bytes)
    let store = MediaStore(root: root), media = mediaFixture(size: Int64(bytes.count))
    let fetch: MediaStore.Fetch = { try await server.fetch($0, $1, $2) }
    let refresh: MediaStore.Refresh = { await server.refresh($0) }
    let progress: MediaStore.Progress = { done, _ in
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("gif-123.mp4").path))
        #expect(done <= Int64(bytes.count))
    }
    async let first = store.obtain(media, fetch: fetch, refresh: refresh, progress: progress)
    async let second = store.obtain(media, fetch: fetch, refresh: refresh, progress: progress)
    let (a, b) = try await (first, second)
    #expect(a == b)
    #expect(try Data(contentsOf: a) == bytes)
    #expect(await server.requests == 2)
    let cached = try await store.obtain(media, fetch: fetch, refresh: refresh, progress: { _, _ in })
    #expect(cached == a)
    #expect(await server.requests == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["gif-123.mp4"])
}

@Test func refreshesExpiredFileReferencesAndRemovesFailedPartials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("telegraph-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(repeating: 12, count: 600_000), media = mediaFixture(size: Int64(bytes.count))
    let store = MediaStore(root: root)
    let expired = FileServer(bytes: bytes, expire: true)
    let result = try await store.obtain(media, fetch: { try await expired.fetch($0, $1, $2) },
                                       refresh: { await expired.refresh($0) }, progress: { _, _ in })
    #expect(try Data(contentsOf: result) == bytes)
    #expect(await expired.refreshes == 1)
    try FileManager.default.removeItem(at: result)
    let broken = FileServer(bytes: bytes, fail: true)
    do {
        _ = try await store.obtain(media, fetch: { try await broken.fetch($0, $1, $2) },
                                   refresh: { await broken.refresh($0) }, progress: { _, _ in })
        Issue.record("An interrupted file was returned as complete")
    } catch {}
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    let protected = mediaFixture(size: 20, restricted: true)
    do {
        _ = try await store.obtain(protected, fetch: { _, _, _ in Issue.record("Protected media fetched"); return Data() },
                                   refresh: { $0 }, progress: { _, _ in })
        Issue.record("Protected media was downloaded")
    } catch {}
}

@Test func classifiesTelegramGIFsAndPhotoSizes() throws {
    let doc = TLObject("document", ["id": .long(5), "dc_id": .int(2), "size": .long(100),
        "mime_type": .string("video/mp4"), "file_reference": .bytes(Data()), "access_hash": .long(7),
        "attributes": .vector([.object(TLObject("documentAttributeAnimated")), .object(TLObject("documentAttributeVideo"))])])
    let message = TLObject("message", [
        "id": .int(1), "peer_id": .object(TLObject("peerUser", ["user_id": .long(2)])), "date": .int(1),
        "message": .string("caption"), "media": .object(TLObject("messageMediaDocument", ["document": .object(doc)]))
    ])
    let gif = try #require(ChatMessage.from(message)?.media)
    #expect(gif.kind == .gif && gif.fileExtension == "mp4")
    #expect(gif.label == "[GIF]")
    let photo = TLObject("photo", ["id": .long(5), "access_hash": .long(7), "file_reference": .bytes(Data()), "dc_id": .int(2),
        "sizes": .vector([
            .object(TLObject("photoSize", ["type": .string("s"), "w": .int(100), "h": .int(100), "size": .int(30)])),
            .object(TLObject("photoSizeProgressive", ["type": .string("y"), "w": .int(1000), "h": .int(1000), "sizes": .vector([.int(50), .int(100)])]))
        ])])
    var imageMessage = message
    imageMessage.fields["media"] = .object(TLObject("messageMediaPhoto", ["photo": .object(photo)]))
    imageMessage.fields["noforwards"] = .bool(true)
    let image = try #require(ChatMessage.from(imageMessage)?.media)
    #expect(image.kind == .image && image.size == 100 && image.location["thumb_size"].string == "y")
    #expect(image.restricted)
}
