import Foundation

struct Conversation: Sendable, Equatable, Identifiable {
    let id: Int64
    var title: String
    var unread: Int32 = 0
    var date: Int32 = 0
    var preview = ""
    var pinned = false
}

enum MediaKind: String, Sendable { case image = "Image", video = "Video", gif = "GIF" }
struct Media: Sendable, Equatable {
    let kind: MediaKind
    let id: Int64
    let dc: Int32
    let size: Int64
    let fileExtension: String
    let location: TLObject
    let peerID: Int64
    let messageID: Int32
    let restricted: Bool
    var key: String { "\(kind.rawValue.lowercased())-\(id)" }
    var label: String { "[\(kind.rawValue)]" }
}

struct ChatMessage: Sendable, Equatable, Identifiable {
    let id: Int32
    let peerID: Int64
    let date: Int32
    let outgoing: Bool
    let text: String
    let media: Media?
    let unsupported: String?

    static func from(_ object: TLObject) -> Self? {
        guard object.name == "message" || object.name == "messageService",
              let peer = object["peer_id"].object, peer.name == "peerUser" else { return nil }
        let peerID = peer["user_id"].long, messageID = object["id"].int
        let rawMedia = object["media"].object
        let media = rawMedia.flatMap { parseMedia($0, peer: peerID, message: messageID, restricted: object["noforwards"].bool) }
        let unsupported: String?
        if object.name == "messageService" { unsupported = "[Service message]" }
        else if let rawMedia, rawMedia.name != "messageMediaEmpty", rawMedia.name != "messageMediaWebPage", media == nil {
            unsupported = "[Unsupported attachment]"
        } else { unsupported = nil }
        return Self(id: messageID, peerID: peerID, date: object["date"].int,
                    outgoing: object["out"].bool, text: object["message"].string, media: media, unsupported: unsupported)
    }

    private static func parseMedia(_ raw: TLObject, peer: Int64, message: Int32, restricted: Bool) -> Media? {
        let restricted = restricted || raw.fields["ttl_seconds"] != nil
        if raw.name == "messageMediaPhoto", let photo = raw["photo"].object, photo.name == "photo" {
            let sizes = photo["sizes"].objects.compactMap { size -> (String, Int64, Int64)? in
                let length: Int64
                switch size.name {
                case "photoSize": length = size["size"].long
                case "photoSizeProgressive": length = size["sizes"].array.map(\.long).max() ?? 0
                case "photoCachedSize": length = Int64(size["bytes"].bytes.count)
                default: return nil
                }
                guard length > 0 else { return nil }
                return (size["type"].string, length, Int64(size["w"].int) * Int64(size["h"].int))
            }
            guard let best = sizes.max(by: { $0.2 < $1.2 }) else { return nil }
            return Media(kind: .image, id: photo["id"].long, dc: photo["dc_id"].int, size: best.1, fileExtension: "jpg",
                         location: TLObject("inputPhotoFileLocation", [
                            "id": photo["id"], "access_hash": photo["access_hash"], "file_reference": photo["file_reference"],
                            "thumb_size": .string(best.0)
                         ]), peerID: peer, messageID: message, restricted: restricted)
        }
        guard raw.name == "messageMediaDocument", let doc = raw["document"].object, doc.name == "document" else { return nil }
        let attrs = doc["attributes"].objects, mime = doc["mime_type"].string.lowercased()
        guard !attrs.contains(where: { ["documentAttributeSticker", "documentAttributeCustomEmoji"].contains($0.name) }) else { return nil }
        let kind: MediaKind
        if attrs.contains(where: { $0.name == "documentAttributeAnimated" }) || mime == "image/gif" { kind = .gif }
        else if mime.hasPrefix("image/") { kind = .image }
        else if mime.hasPrefix("video/") || attrs.contains(where: { $0.name == "documentAttributeVideo" }) { kind = .video }
        else { return nil }
        let extensions = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp",
                          "image/heic": "heic", "image/heif": "heif", "image/avif": "avif", "image/tiff": "tiff",
                          "image/bmp": "bmp", "video/mp4": "mp4", "video/quicktime": "mov", "video/webm": "webm"]
        // Never derive an executable extension or path from an untrusted filename.
        let ext = extensions[mime] ?? (kind == .image ? "jpg" : "mp4")
        return Media(kind: kind, id: doc["id"].long, dc: doc["dc_id"].int, size: doc["size"].long, fileExtension: ext,
                     location: TLObject("inputDocumentFileLocation", [
                        "id": doc["id"], "access_hash": doc["access_hash"], "file_reference": doc["file_reference"],
                        "thumb_size": .string("")
                     ]), peerID: peer, messageID: message, restricted: restricted)
    }
}

struct ClientSnapshot: Sendable {
    var conversations: [Conversation]
    var selectedID: Int64?
    var messages: [ChatMessage]
    var loading: Bool
    var hasOlder: Bool
}
enum ClientEvent: Sendable {
    case snapshot(ClientSnapshot), status(String)
}
