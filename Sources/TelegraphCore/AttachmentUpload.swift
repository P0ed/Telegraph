import Foundation
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct OutgoingAttachment: Sendable, Equatable {
    static let partSize = 512 * 1024
    static let maxSize: Int64 = 4000 * Int64(partSize)
    let url: URL
    let size: Int64
    let modified: Date
    let mimeType: String
    let photo: Bool
    let attributes: [TLObject]
    var name: String { url.lastPathComponent }

    static func prepare(_ url: URL) async throws -> Self {
        guard url.isFileURL else { throw TelegraphError.invalid("Choose a local file") }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TelegraphError.invalid("Cannot read \(url.lastPathComponent); check the file path and permissions")
        }
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              let size = (info[.size] as? NSNumber)?.int64Value, size > 0,
              let modified = info[.modificationDate] as? Date else {
            throw TelegraphError.invalid("Choose a non-empty regular file")
        }
        guard size <= maxSize else { throw TelegraphError.invalid("Files are limited to 2 GB (4,000 upload parts)") }
        var mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var photo = false
        var attributes = [TLObject("documentAttributeFilename", ["file_name": .string(url.lastPathComponent)])]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) {
            mime = type.preferredMIMEType ?? mime
            photo = type == .jpeg || type == .png
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                attributes.append(TLObject("documentAttributeImageSize", ["w": .int(width.int32Value), "h": .int(height.int32Value)]))
            }
            if type == .gif || (["image/png", "image/webp"].contains(mime) && CGImageSourceGetCount(source) > 1) {
                photo = false
                attributes.append(TLObject("documentAttributeAnimated"))
            }
        } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw TelegraphError.invalid("The video has no video track") }
                let duration = try await asset.load(.duration).seconds
                let dimensions = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let bounds = CGRect(origin: .zero, size: dimensions).applying(transform)
                guard duration.isFinite, duration > 0, bounds.width > 0, bounds.height > 0,
                      bounds.width <= Double(Int32.max), bounds.height <= Double(Int32.max) else {
                    throw TelegraphError.invalid("Invalid video dimensions or duration")
                }
                attributes.append(TLObject("documentAttributeVideo", [
                    "duration": .double(duration), "w": .int(Int32(bounds.width.rounded())), "h": .int(Int32(bounds.height.rounded()))
                ]))
            } catch {
                // Containers and codecs macOS cannot inspect can still be sent as files.
                try Task.checkCancellation()
            }
        }
        return Self(url: url, size: size, modified: modified, mimeType: mime, photo: photo, attributes: attributes)
    }

    func validate() throws {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular,
              (info[.size] as? NSNumber)?.int64Value == size, info[.modificationDate] as? Date == modified else {
            throw TelegraphError.invalid("The attached file changed; attach it again before sending")
        }
    }

    func media(file: TLObject) -> TLObject {
        if photo { return TLObject("inputMediaUploadedPhoto", ["file": .object(file)]) }
        var fields: [String: TLValue] = ["file": .object(file), "mime_type": .string(mimeType),
                                       "attributes": .vector(attributes.map { .object($0) })]
        if attributes.contains(where: { $0.name == "documentAttributeVideo" }) { fields["nosound_video"] = .bool(true) }
        else if mimeType.hasPrefix("video/") { fields["force_file"] = .bool(true) }
        return TLObject("inputMediaUploadedDocument", fields)
    }
}

enum AttachmentPath {
    static func url(_ input: String) throws -> URL {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains("\0"), !input.contains("\n"), !input.contains("\r") else {
            throw TelegraphError.invalid("Enter one local file path")
        }
        if input.hasPrefix("file:"), let url = URL(string: input), url.isFileURL,
           url.host == nil || url.host == "" || url.host == "localhost" { return url }
        let literal = (input as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: literal) { return URL(fileURLWithPath: literal) }
        // Decode the quoting used when terminal applications paste or drag a path. Never invoke a shell.
        var path = "", quote: Character?, escaped = false, ended = false
        for character in input {
            if escaped { path.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { path.append(character) }
            } else if character == "'" || character == "\"" {
                guard !ended else { throw TelegraphError.invalid("Attach one file at a time") }
                quote = character
            } else if character.isWhitespace { ended = true }
            else {
                guard !ended else { throw TelegraphError.invalid("Attach one file at a time; quote paths containing spaces") }
                path.append(character)
            }
        }
        guard !escaped, quote == nil, !path.isEmpty else { throw TelegraphError.invalid("Incomplete file path quoting") }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

enum AttachmentUploader {
    typealias SavePart = @Sendable (TLObject) async throws -> Bool
    typealias Progress = @Sendable (Int64, Int64) async -> Void

    static func upload(_ attachment: OutgoingAttachment, save: SavePart, progress: Progress) async throws -> TLObject {
        try Task.checkCancellation()
        try attachment.validate()
        let handle = try FileHandle(forReadingFrom: attachment.url)
        defer { try? handle.close() }
        let id = try Crypto.randomID()
        let parts = Int32((attachment.size + Int64(OutgoingAttachment.partSize) - 1) / Int64(OutgoingAttachment.partSize))
        let big = attachment.size > 10 * 1024 * 1024
        var hash = Insecure.MD5(), offset: Int64 = 0
        await progress(0, attachment.size)
        for part in 0..<parts {
            try Task.checkCancellation()
            let count = Int(min(Int64(OutgoingAttachment.partSize), attachment.size - offset))
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else {
                throw TelegraphError.invalid("Could not read the complete attachment")
            }
            if !big { hash.update(data: bytes) }
            var fields: [String: TLValue] = ["file_id": .long(id), "file_part": .int(part), "bytes": .bytes(bytes)]
            if big { fields["file_total_parts"] = .int(parts) }
            guard try await save(TLObject(big ? "upload.saveBigFilePart" : "upload.saveFilePart", fields)) else {
                throw TelegraphError.invalid("Telegram did not accept file part \(part + 1); retry sending")
            }
            offset += Int64(bytes.count)
            await progress(offset, attachment.size)
        }
        try Task.checkCancellation()
        try attachment.validate()
        var fields: [String: TLValue] = ["id": .long(id), "parts": .int(parts), "name": .string(attachment.name)]
        if !big { fields["md5_checksum"] = .string(hash.finalize().map { String(format: "%02x", $0) }.joined()) }
        return TLObject(big ? "inputFileBig" : "inputFile", fields)
    }
}
