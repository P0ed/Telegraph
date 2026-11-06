import Foundation
import Testing
import AVFoundation
@testable import TelegraphCore

let uploadGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!

private actor UploadParts {
    var requests: [TLObject] = []
    var progress: [Int64] = []
    func save(_ request: TLObject) -> Bool { requests.append(request); return true }
    func update(_ bytes: Int64) { progress.append(bytes) }
}

@Test(arguments: [524305, 10485760, 10485761])
func uploadsChunksAndSelectsSmallOrBigProtocol(size: Int) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID()).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    let bytes = Data(repeating: 97, count: size)
    try bytes.write(to: url)
    let attachment = try await OutgoingAttachment.prepare(url), recorder = UploadParts()
    let file = try await AttachmentUploader.upload(attachment, save: { await recorder.save($0) },
        progress: { uploaded, _ in await recorder.update(uploaded) })
    let requests = await recorder.requests
    let big = size > 10 * 1024 * 1024
    #expect(file.name == (big ? "inputFileBig" : "inputFile"))
    #expect(requests.count == (size + 512 * 1024 - 1) / (512 * 1024))
    #expect(requests.map { $0["file_part"].int } == Array(0..<Int32(requests.count)))
    #expect(requests.allSatisfy { $0.name == (big ? "upload.saveBigFilePart" : "upload.saveFilePart") })
    #expect(Set(requests.map { $0["file_id"].long }) == [file["id"].long])
    #expect(requests.dropLast().allSatisfy { $0["bytes"].bytes.count == 512 * 1024 })
    #expect(requests.reduce(into: Data()) { $0.append($1["bytes"].bytes) } == bytes)
    #expect(await recorder.progress.first == 0)
    #expect(await recorder.progress.last == Int64(size))
    if big {
        #expect(file.fields["md5_checksum"] == nil)
        #expect(requests.allSatisfy { $0["file_total_parts"].int == file["parts"].int })
    } else if size == 512 * 1024 + 17 {
        // Independently computed MD5 of 524,305 ASCII 'a' bytes.
        #expect(file["md5_checksum"].string == "ebe93c349702afc9cabd7e364a73f31f")
    }
}

@Test func uploadFailureChangedFileAndCancellation() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID()).bin")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 1, count: 600_000).write(to: url)
    let attachment = try await OutgoingAttachment.prepare(url), recorder = UploadParts()
    await #expect(throws: (any Error).self) {
        _ = try await AttachmentUploader.upload(attachment, save: { request in
            _ = await recorder.save(request); return false
        }, progress: { _, _ in })
    }
    #expect(await recorder.requests.count == 1)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AttachmentUploader.upload(attachment, save: { _ in Issue.record("Cancelled upload sent data"); return true },
            progress: { _, _ in })
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    try Data([2]).write(to: url)
    await #expect(throws: (any Error).self) {
        _ = try await AttachmentUploader.upload(attachment, save: { _ in Issue.record("Changed file uploaded"); return true },
            progress: { _, _ in })
    }
    try Data().write(to: url)
    await #expect(throws: (any Error).self) { _ = try await OutgoingAttachment.prepare(url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(OutgoingAttachment.maxSize + 1))
    try handle.close()
    await #expect(throws: (any Error).self) { _ = try await OutgoingAttachment.prepare(url) }
    await #expect(throws: (any Error).self) { _ = try await OutgoingAttachment.prepare(url.deletingLastPathComponent()) }
}

@Test func attachmentPathsAndMediaTypes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gifURL = root.appendingPathComponent("meme with spaces.gif")
    try uploadGIF.write(to: gifURL)
    for input in [gifURL.path, "'\(gifURL.path)'", "\"\(gifURL.path)\"", gifURL.path.replacingOccurrences(of: " ", with: "\\ "), gifURL.absoluteString] {
        #expect(try AttachmentPath.url(input).standardizedFileURL == gifURL.standardizedFileURL)
    }
    #expect(throws: (any Error).self) { _ = try AttachmentPath.url("'/tmp/unclosed") }
    #expect(throws: (any Error).self) { _ = try AttachmentPath.url("'/tmp/a.gif' '/tmp/b.gif'") }
    let gif = try await OutgoingAttachment.prepare(gifURL)
    #expect(gif.mimeType == "image/gif")
    #expect(!gif.photo)
    #expect(gif.attributes.contains { $0.name == "documentAttributeAnimated" })
    let pngURL = root.appendingPathComponent("photo.png")
    let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII="))
    try png.write(to: pngURL)
    let photo = try await OutgoingAttachment.prepare(pngURL)
    #expect(photo.photo)
    #expect(photo.mimeType == "image/png")
    let file = TLObject("inputFile", ["id": .long(1), "parts": .int(1), "name": .string("photo.png"), "md5_checksum": .string("")])
    let codec = try TLCodec()
    #expect(try codec.decode(codec.encode(photo.media(file: file))).object?.name == "inputMediaUploadedPhoto")
    #expect(try codec.decode(codec.encode(gif.media(file: file))).object?["attributes"].objects.contains { $0.name == "documentAttributeAnimated" } == true)
    let unrecognizedVideo = root.appendingPathComponent("unknown-codec.mp4")
    try Data([1, 2, 3]).write(to: unrecognizedVideo)
    let fallback = try await OutgoingAttachment.prepare(unrecognizedVideo)
    #expect(fallback.media(file: file)["force_file"].bool)
}

@Test func videoAttachmentMetadata() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 32
    ])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
    let pixel = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 0, CVPixelBufferGetDataSize(pixel)) }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: pixel), with: .zero)
    writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
    receiver.finish()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    let attachment = try await OutgoingAttachment.prepare(url)
    #expect(attachment.mimeType == "video/mp4")
    #expect(!attachment.photo)
    let attribute = try #require(attachment.attributes.first { $0.name == "documentAttributeVideo" })
    #expect(attribute["w"].int == 32 && attribute["h"].int == 16)
    if case .double(let seconds) = attribute["duration"] { #expect(seconds > 0) }
    else { Issue.record("Missing video duration") }
    #expect(attachment.media(file: TLObject("inputFileBig"))["nosound_video"].bool)
}
