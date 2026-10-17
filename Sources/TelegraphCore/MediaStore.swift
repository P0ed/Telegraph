import Foundation
import Darwin

actor MediaStore {
    typealias Fetch = @Sendable (Media, Int64, Int32) async throws -> Data
    typealias Refresh = @Sendable (Media) async throws -> Media
    typealias Progress = @Sendable (Int64, Int64) async -> Void
    private let root: URL
    private var active: [String: Task<URL, any Error>] = [:]
    private var tail: Task<Void, Never>?
    init(root: URL) { self.root = root }

    func obtain(_ media: Media, fetch: @escaping Fetch, refresh: @escaping Refresh,
                progress: @escaping Progress) async throws -> URL {
        guard !media.restricted else { throw TelegraphError.invalid("Telegram restricts saving this attachment") }
        guard media.size > 0, media.size <= 8 * 1024 * 1024 * 1024,
              ["jpg", "png", "gif", "webp", "heic", "heif", "avif", "tiff", "bmp", "mp4", "mov", "webm"].contains(media.fileExtension) else {
            throw TelegraphError.invalid("Invalid attachment metadata")
        }
        if let task = active[media.key] { return try await task.value }
        let previous = tail
        let root = root
        let task = Task<URL, any Error> {
            await previous?.value
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let final = root.appendingPathComponent("\(media.key).\(media.fileExtension)")
            if let info = try? FileManager.default.attributesOfItem(atPath: final.path),
               info[.type] as? FileAttributeType == .typeRegular, (info[.size] as? NSNumber)?.int64Value == media.size {
                await progress(media.size, media.size); return final
            }
            let temporary = root.appendingPathComponent(".\(media.key)-\(UUID().uuidString).part")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw TelegraphError.invalid("Could not create the download file")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
            var current = media, offset: Int64 = 0, refreshed = false
            while offset < media.size {
                try Task.checkCancellation()
                let chunk: Data
                do { chunk = try await fetch(current, offset, 512 * 1024) }
                catch let error as TelegraphError where ["FILE_REFERENCE_EXPIRED", "FILE_REFERENCE_INVALID"].contains(error.rpcMessage ?? "") && !refreshed {
                    current = try await refresh(current)
                    guard current.id == media.id, current.size == media.size, !current.restricted else {
                        throw TelegraphError.invalid("The attachment changed during download")
                    }
                    refreshed = true; continue
                }
                guard !chunk.isEmpty, chunk.count <= 512 * 1024, offset + Int64(chunk.count) <= media.size else {
                    throw TelegraphError.invalid("Telegram returned an incomplete or oversized file")
                }
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                await progress(offset, media.size)
                if offset < media.size, !offset.isMultiple(of: 4096) {
                    throw TelegraphError.invalid("Unexpected short file chunk")
                }
            }
            try handle.synchronize()
            try handle.close()
            // No incomplete file is ever passed to Quick Look.
            guard Darwin.rename(temporary.path, final.path) == 0 else {
                throw TelegraphError.invalid("Could not finalize download: \(String(cString: strerror(errno)))")
            }
            return final
        }
        active[media.key] = task
        tail = Task { _ = try? await task.value }
        do { let url = try await task.value; active.removeValue(forKey: media.key); return url }
        catch { active.removeValue(forKey: media.key); throw error }
    }
    func cancelAll() async {
        let pending = Array(active.values)
        for task in pending { task.cancel() }
        tail?.cancel()
        for task in pending { _ = try? await task.value }
    }
}

@MainActor
final class MediaOpener {
    private var processes: [Process] = []
    func open(_ url: URL) throws {
        guard url.isFileURL else { throw TelegraphError.invalid("Quick Look requires a local file") }
        processes.removeAll { !$0.isRunning }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
    }
    func close() {
        for process in processes where process.isRunning { process.terminate() }
        processes.removeAll()
    }
}
