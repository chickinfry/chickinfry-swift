#if canImport(Security)
import Foundation
import Security

/// Runs under the app's file lock before any Keychain state is restored.
struct DeviceInstallation {
    private struct Marker: Codable {
        var version = 1
        let app: String
        let installation: String
        var phase: String
    }
    private struct Header: Decodable { let version: Int }

    let app: String
    let files: DeviceFiles
    let calls: any DeviceKeychainCalls

    func prepare() throws -> String {
        do { return try complete() }
        catch {
            var failure = (error as? ClientError) ?? deviceError()
            failure.devicePreparation = true
            throw failure
        }
    }

    private func complete() throws -> String {
        let accessGroup = try calls.accessGroup()
        var marker: Marker
        if let data = try files.read("installation", limit: 1024) {
            guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
                throw deviceError("device_storage_corrupt")
            }
            guard header.version == 1 else { throw deviceError("device_storage_version_unsupported") }
            guard let decoded = try? JSONDecoder().decode(Marker.self, from: data), decoded.app == app,
                  UUID(uuidString: decoded.installation) != nil,
                  ["pending", "done"].contains(decoded.phase) else { throw deviceError("device_storage_corrupt") }
            marker = decoded
            try files.verifyBackupExclusion("installation")
        } else {
            marker = Marker(app: app, installation: UUID().uuidString, phase: "pending")
            try files.write("installation", data: JSONEncoder().encode(marker), excludeFromBackup: true)
        }
        if marker.phase == "done" { return marker.installation }
        let service = "com.chickinfry.device." + app
        let (status, accounts) = calls.accounts(service: service, accessGroup: accessGroup)
        guard status == errSecSuccess else { throw keychainError(status) }
        // Validate ownership of the entire set before deleting any item.
        for account in accounts {
            guard let data = try DeviceKeychain(service: service, account: account, accessGroup: accessGroup,
                                                calls: calls).loadIfPresent() else { continue }
            guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
                throw deviceError("device_storage_corrupt")
            }
            guard header.version == 1 else { throw deviceError("device_storage_version_unsupported") }
            guard let owner = try? JSONDecoder().decode(DeviceState.self, from: data) else {
                throw deviceError("device_storage_corrupt")
            }
            try owner.validatePayload()
            let parts = account.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, UUID(uuidString: parts[0]) != nil, owner.scope.app == app,
                  validDeviceComponent(owner.scope.project), validDeviceComponent(owner.scope.environment),
                  owner.scope.project == parts[1], owner.scope.environment == parts[2], owner.scope.origin == parts[3],
                  (try? HTTPTransport.validateOrigin(owner.scope.origin)) == owner.scope.origin,
                  owner.installation == nil || owner.installation == parts[0] else {
                throw deviceError("device_storage_corrupt")
            }
        }
        for account in accounts {
            let status = calls.delete(service: service, account: account, accessGroup: accessGroup)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
        }
        marker.phase = "done"
        try files.write("installation", data: JSONEncoder().encode(marker), excludeFromBackup: true)
        return marker.installation
    }

    private func keychainError(_ status: Int32) -> ClientError {
        deviceError(status == errSecDecode ? "device_storage_corrupt" : "device_storage_unavailable")
    }
}
#endif
