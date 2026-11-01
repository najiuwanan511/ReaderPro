import Foundation
import Security
import CryptoKit

// A login header belongs to one source, not to every source for the same host.
// Keychain avoids placing authentication tokens in source exports or defaults.
enum SourceLoginHeaders {
    private static let lock = NSLock()
    private static let service = "com.selfuse.readerpro.source-login-header"

    private static func query(_ source: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }

    static func get(_ source: String) -> String? {
        guard !source.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
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
        var status = SecItemUpdate(params as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = params
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SourceFailure(stage: "登录头", message: "无法保存登录信息（Keychain \(status)）") }
    }

    static func remove(_ source: String) throws {
        guard !source.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(query(source) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SourceFailure(stage: "登录头", message: "无法删除登录信息（Keychain \(status)）")
        }
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
