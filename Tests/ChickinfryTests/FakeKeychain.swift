import Foundation
@testable import Chickinfry
#if canImport(Security)
import Security
import Darwin

/// A file-backed protocol fake; it never calls the operating system's Keychain.
final class FakeKeychainCalls: DeviceKeychainCalls, @unchecked Sendable {
    let root: URL
    var defaultGroup = "TEAMID0000.com.example.host"
    var bundleIdentifier: String? = "com.example.host"
    var deniedGroup: String?
    var missingProbeAttributes = false
    private var confirmedGroup: String?
    private(set) var probeAdds = 0
    private(set) var probeDeletes = 0
    private(set) var authenticationGroups: Set<String> = []
    var failure: Int32?
    var updateFailure: Int32?
    var failReadsAfterUpdate = false
    var deleteFailure: Int32?
    var crashAfterDeletes: Int?
    private var deletions = 0
    init(root: URL) { self.root = root }

    func accessGroup() throws -> String {
        if let confirmedGroup { return confirmedGroup }
        let group = try DeviceKeychain.resolveAccessGroup(bundleIdentifier: bundleIdentifier, calls: self)
        confirmedGroup = group
        return group
    }

    private func isProbe(_ service: String) -> Bool { service.hasPrefix("com.chickinfry.device.access-group.") }

    private func files(_ query: [String: Any]) throws -> (DeviceFiles, String) {
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { throw deviceError() }
        func component(_ value: String) -> String {
            Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        }
        let group = query[kSecAttrAccessGroup as String] as? String ?? defaultGroup
        if !isProbe(service) { authenticationGroups.insert(group) }
        return (try DeviceFiles(path: root.appendingPathComponent("fake-keychain")
            .appendingPathComponent(component(group)).appendingPathComponent(component(service)).path), component(account))
    }

    func copy(_ query: [String: Any]) -> (Int32, Data?) {
        if let failure { return (failure, nil) }
        do {
            let (files, name) = try files(query)
            guard let data = try files.read(name) else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        } catch { return (errSecInteractionNotAllowed, nil) }
    }

    func add(_ query: [String: Any]) -> (Int32, String?) {
        let service = query[kSecAttrService as String] as? String ?? ""
        if isProbe(service) { probeAdds += 1 }
        if let failure { return (failure, nil) }
        let group = query[kSecAttrAccessGroup as String] as? String ?? defaultGroup
        if group == deniedGroup { return (errSecMissingEntitlement, nil) }
        do {
            let (files, name) = try files(query)
            guard try files.read(name) == nil else { return (errSecDuplicateItem, nil) }
            guard let data = query[kSecValueData as String] as? Data else { return (errSecParam, nil) }
            try files.write(name, data: data)
            return (errSecSuccess, isProbe(service) && missingProbeAttributes ? nil : group)
        } catch { return (errSecInteractionNotAllowed, nil) }
    }

    func update(_ query: [String: Any], data: Data) -> Int32 {
        if let updateFailure { return updateFailure }
        if let failure { return failure }
        do {
            let (files, name) = try files(query)
            guard try files.read(name) != nil else { return errSecItemNotFound }
            try files.write(name, data: data)
            if failReadsAfterUpdate { failure = errSecInteractionNotAllowed }
            return errSecSuccess
        } catch { return errSecInteractionNotAllowed }
    }

    func remove(service: String, account: String, accessGroup: String? = nil) throws {
        var query: [String: Any] = [kSecAttrService as String: service, kSecAttrAccount as String: account]
        query[kSecAttrAccessGroup as String] = accessGroup ?? defaultGroup
        let (files, name) = try files(query)
        try FileManager.default.removeItem(at: files.url.appendingPathComponent(name))
    }

    func accounts(service: String, accessGroup: String) -> (Int32, [String]) {
        if let failure { return (failure, []) }
        do {
            let (files, _) = try files([kSecAttrService as String: service, kSecAttrAccount as String: "unused",
                                       kSecAttrAccessGroup as String: accessGroup])
            let names = try FileManager.default.contentsOfDirectory(atPath: files.url.path)
            let accounts = names.filter { !$0.hasPrefix(".write-") }.compactMap { name -> String? in
                guard let bytes = Data(base64Encoded: name.replacingOccurrences(of: "_", with: "/")) else { return nil }
                return String(data: bytes, encoding: .utf8)
            }
            guard accounts.count == names.filter({ !$0.hasPrefix(".write-") }).count else { return (errSecDecode, []) }
            return (errSecSuccess, accounts)
        } catch { return (errSecInteractionNotAllowed, []) }
    }

    func delete(service: String, account: String, accessGroup: String?) -> Int32 {
        let probe = isProbe(service)
        if probe { probeDeletes += 1 }
        if let deleteFailure { return deleteFailure }
        if let failure { return failure }
        do {
            try remove(service: service, account: account, accessGroup: accessGroup)
            if !probe {
                deletions += 1
                if deletions == crashAfterDeletes { _exit(73) }
            }
            return errSecSuccess
        } catch let error as CocoaError where error.code == .fileNoSuchFile { return errSecItemNotFound }
        catch { return errSecInteractionNotAllowed }
    }
}
#endif

func deviceKeychainCalls(root: URL) -> (any DeviceKeychainCalls)? {
    #if canImport(Security)
    FakeKeychainCalls(root: root)
    #else
    nil
    #endif
}
