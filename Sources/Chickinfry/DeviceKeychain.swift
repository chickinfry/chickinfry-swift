import Foundation

protocol DeviceKeychainCalls: Sendable {
    func accessGroup() throws -> String
    func copy(_ query: [String: Any]) -> (Int32, Data?)
    func add(_ query: [String: Any]) -> (Int32, String?)
    func update(_ query: [String: Any], data: Data) -> Int32
    func accounts(service: String, accessGroup: String) -> (Int32, [String])
    func delete(service: String, account: String, accessGroup: String?) -> Int32
}

#if canImport(Security)
import Security
import LocalAuthentication

struct SystemDeviceKeychainCalls: DeviceKeychainCalls {
    private static let groupLock = NSLock()
    nonisolated(unsafe) private static var confirmedGroup: String?

    func accessGroup() throws -> String {
        try Self.groupLock.withLock {
            if let group = Self.confirmedGroup { return group }
            let group = try DeviceKeychain.resolveAccessGroup(bundleIdentifier: Bundle.main.bundleIdentifier, calls: self)
            Self.confirmedGroup = group
            return group
        }
    }
    func copy(_ query: [String: Any]) -> (Int32, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func add(_ query: [String: Any]) -> (Int32, String?) {
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        let attributes = result as? [String: Any]
        return (status, attributes?[kSecAttrAccessGroup as String] as? String)
    }
    func update(_ query: [String: Any], data: Data) -> Int32 {
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func accounts(service: String, accessGroup: String) -> (Int32, [String]) {
        var query = DeviceKeychain.query(service: service, account: "", accessGroup: accessGroup)
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return (errSecSuccess, []) }
        guard status == errSecSuccess else { return (status, []) }
        guard let items = result as? [[String: Any]] else { return (errSecDecode, []) }
        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        guard accounts.count == items.count else { return (errSecDecode, []) }
        return (errSecSuccess, accounts)
    }

    func delete(service: String, account: String, accessGroup: String?) -> Int32 {
        let query = DeviceKeychain.query(service: service, account: account, accessGroup: accessGroup)
        return SecItemDelete(query as CFDictionary)
    }
}

struct DeviceKeychain {
    let service: String
    let account: String
    var accessGroup: String?
    var beforeUpdate: (() throws -> Void)?
    let calls: any DeviceKeychainCalls

    init(service: String, account: String, accessGroup: String? = nil, calls: (any DeviceKeychainCalls)? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.calls = calls ?? SystemDeviceKeychainCalls()
    }

    fileprivate var query: [String: Any] {
        get throws {
            let group = try accessGroup ?? calls.accessGroup()
            return Self.query(service: service, account: account, accessGroup: group)
        }
    }

    fileprivate static func query(service: String, account: String, accessGroup: String?) -> [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service, kSecAttrAccount as String: account,
                                     kSecAttrSynchronizable as String: false,
                                     kSecUseDataProtectionKeychain as String: true,
                                     kSecUseAuthenticationContext as String: authentication]
        if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
        return result
    }

    static func resolveAccessGroup(bundleIdentifier: String?, calls: any DeviceKeychainCalls) throws -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }),
              bundleIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { throw deviceError() }
        func probe(_ group: String?) throws -> String {
            let service = "com.chickinfry.device.access-group." + UUID().uuidString
            let account = "probe"
            var item = query(service: service, account: account, accessGroup: group)
            item[kSecValueData as String] = Data()
            item[kSecReturnAttributes as String] = true
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let (status, actual) = calls.add(item)
            // Even an incomplete attribute response must not leave the unique, secret-free probe behind.
            let removed = calls.delete(service: service, account: account, accessGroup: actual ?? group)
            guard status == errSecSuccess, removed == errSecSuccess || removed == errSecItemNotFound,
                  let actual else { throw deviceError() }
            return actual
        }
        // The first-listed group may be shared; only its signing prefix is reusable.
        let defaultGroup = try probe(nil)
        guard let prefix = defaultGroup.split(separator: ".", omittingEmptySubsequences: false).first,
              prefix.utf8.count == 10,
              prefix.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw deviceError() }
        let group = String(prefix) + "." + bundleIdentifier
        guard try probe(group) == group else { throw deviceError() }
        return group
    }

    func load() throws -> Data {
        guard let data = try loadIfPresent() else { throw deviceError("device_storage_corrupt") }
        return data
    }

    func loadIfPresent() throws -> Data? {
        var lookup = try query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, value) = calls.copy(lookup)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = value else { throw deviceError("device_storage_corrupt") }
        guard data.count <= DeviceLimits.bundleBytes else { throw deviceError("device_storage_full") }
        return data
    }

    func create(_ data: Data) throws {
        var item = try query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let (status, _) = calls.add(item)
        guard status == errSecSuccess else { throw failure(status) }
    }

    func replace(_ data: Data) throws {
        try beforeUpdate?()
        let status = calls.update(try query, data: data)
        guard status == errSecSuccess else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> ClientError {
        deviceError(status == errSecItemNotFound || status == errSecDecode
                    ? "device_storage_corrupt" : "device_storage_unavailable")
    }
}
#endif
