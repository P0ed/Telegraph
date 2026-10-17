import Foundation
import Security
import Darwin

struct ClientProfile: Codable, Sendable {
    var apiID: Int32
    var apiHash: String
    var mainDC: Int32 = 2
    var userID: Int64?
    var keys: [Int32: DCAuth] = [:]
    var authorizedDCs: Set<Int32> = []
    var endpoints: [DCEndpoint] = []
}

struct ProfilePersistence: Sendable {
    let save: @Sendable (ClientProfile) throws -> Void
    let delete: @Sendable () throws -> Void
    static func live(test: Bool) -> Self {
        Self(save: { try ProfileStore.save($0, test: test) }, delete: { try ProfileStore.delete(test: test) })
    }
}

enum ProfileStore {
    private static func query(test: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.telegraph.cli",
         kSecAttrAccount as String: test ? "test" : "production",
         kSecAttrSynchronizable as String: false]
    }
    static func load(test: Bool) throws -> ClientProfile? {
        var q = query(test: test)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure(status) }
        return try JSONDecoder().decode(ClientProfile.self, from: data)
    }
    static func save(_ profile: ClientProfile, test: Bool) throws {
        let data = try JSONEncoder().encode(profile)
        let q = query(test: test)
        let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Telegraph \(test ? "test" : "Telegram") session"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw failure(status) }
        } else if result != errSecSuccess { throw failure(result) }
    }
    static func delete(test: Bool) throws {
        let status = SecItemDelete(query(test: test) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> TelegraphError {
        .invalid("Keychain: \((SecCopyErrorMessageString(status, nil) as String?) ?? String(status))")
    }
}

final class ClientLock {
    private let descriptor: Int32
    init(test: Bool) throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telegraph", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(test ? "test.lock" : "production.lock")
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TelegraphError.invalid("Could not open the session lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw TelegraphError.invalid("Another Telegraph process is using this account")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
