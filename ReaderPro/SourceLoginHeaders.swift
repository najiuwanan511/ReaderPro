import Foundation
import Security
import CryptoKit

// A login header belongs to one source, not to every source for the same host.
// Keychain is preferred; a protected sandbox file supports installations where
// the signer has no keychain entitlement (e.g. some sideloaded builds).
enum SourceLoginHeaders {
    private static let lock = NSLock()
    private static let service = "com.selfuse.readerpro.source-login-header"
    #if DEBUG || READERPRO_TESTING
    @TaskLocal static var testForceMissingEntitlement = false
    @TaskLocal static var testKeychainReadValue: String?
    #endif

    private static var missingEntitlementForTest: Bool {
        #if DEBUG || READERPRO_TESTING
        return testForceMissingEntitlement
        #else
        return false
        #endif
    }

    private static func account(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func query(_ source: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account(source)]
    }

    private static func fileURL(_ source: String, createDirectory: Bool, deleted: Bool = false) throws -> URL {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SourceFailure(stage: "登录头", message: "无法访问受保护的本地存储")
        }
        var folder = base.appendingPathComponent("SourceLoginHeaders", isDirectory: true)
        if createDirectory {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try manager.setAttributes([.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: folder.path)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try folder.setResourceValues(attributes)
        }
        let name = account(source) + (deleted ? ".deleted" : "")
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    private static func writeFile(_ data: Data, source: String, deleted: Bool = false) throws {
        do {
            let url = try fileURL(source, createDirectory: true, deleted: deleted)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SourceFailure(stage: "登录头", message: "无法保存受保护的本地登录信息")
        }
    }

    private static func removeFile(_ source: String, deleted: Bool = false) throws {
        let url = try fileURL(source, createDirectory: false, deleted: deleted)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw SourceFailure(stage: "登录头", message: "无法删除受保护的本地登录信息") }
    }

    #if DEBUG || READERPRO_TESTING
    static func testPurgeFallback(_ source: String) throws {
        lock.lock(); defer { lock.unlock() }
        try removeFile(source)
        try removeFile(source, deleted: true)
    }
    #endif

    static func get(_ source: String) -> String? {
        guard !source.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        // A deletion performed while Keychain is inaccessible must remain
        // authoritative even if an older keychain entry becomes visible later.
        if let marker = try? fileURL(source, createDirectory: false, deleted: true),
           FileManager.default.fileExists(atPath: marker.path) { return nil }
        // A fallback can be newer than an inaccessible keychain item, so
        // preserve it until a later successful keychain write removes it.
        if let url = try? fileURL(source, createDirectory: false), FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if missingEntitlementForTest { return nil }
        #if DEBUG || READERPRO_TESTING
        if let testKeychainReadValue { return testKeychainReadValue }
        #endif
        var params = query(source)
        params[kSecReturnData as String] = true
        params[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(params as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func put(_ value: String, source: String) throws {
        guard !source.isEmpty else { throw SourceFailure(stage: "登录头", message: "书源地址为空，无法保存登录信息") }
        lock.lock(); defer { lock.unlock() }
        let params = query(source)
        let data = Data(value.utf8)
        var status = missingEntitlementForTest ? errSecMissingEntitlement : SecItemUpdate(params as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = params
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement {
            try writeFile(data, source: source)
            try removeFile(source, deleted: true)
            return
        }
        guard status == errSecSuccess else { throw SourceFailure(stage: "登录头", message: "无法保存登录信息（Keychain \(status)）") }
        try removeFile(source)
        try removeFile(source, deleted: true)
    }

    static func remove(_ source: String) throws {
        guard !source.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let status = missingEntitlementForTest ? errSecMissingEntitlement : SecItemDelete(query(source) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw SourceFailure(stage: "登录头", message: "无法删除登录信息（Keychain \(status)）")
        }
        // Record deletion even after a successful/no-item result: a different
        // signer may make an older keychain access group visible in future.
        // Write the marker before removing fallback data so partial failure
        // cannot make stale credentials readable again.
        try writeFile(Data(), source: source, deleted: true)
        try removeFile(source)
    }

    static func map(_ source: String) -> [String: String]? {
        guard let raw = get(source), let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed),
              value is [String: Any] else { return nil }
        return SourceHTTP.headers(value)
    }

    // HTTP header names are case-insensitive; login values take precedence.
    static func merge(_ headers: [String: String], source: String) -> [String: String] {
        overlay(map(source) ?? [:], onto: headers)
    }

    static func overlay(_ additions: [String: String], onto headers: [String: String]) -> [String: String] {
        var result = headers
        for (name, value) in additions {
            for key in Array(result.keys) where key.caseInsensitiveCompare(name) == .orderedSame { result.removeValue(forKey: key) }
            result[name] = value
        }
        return result
    }
}
