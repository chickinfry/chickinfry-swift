import ChickinfryServer
import FoundationEssentials

private struct Input: Decodable, Sendable { let mode: String; let value: String }
private struct Output: Encodable, Sendable { let value: String; let setupCount: Int }
private actor SetupState {
    static let shared = SetupState()
    var count = 0
    func prepare() { count += 1 }
}
@MainActor private func mainActorValue(_ value: String) -> String { value }

@_cdecl("probe_boot")
public func probeBoot() {
    WasmServer.start(Application(operations: [Operation("probe.run", input: Input.self) { input, _ in
        switch input.mode {
        case "legacy": try await Task.sleep(nanoseconds: 30_000_000)
        case "duration": try await Task.sleep(for: .milliseconds(30))
        case "main": _ = await mainActorValue(input.value)
        default: break
        }
        return Output(value: input.value, setupCount: await SetupState.shared.count)
    }]), setup: {
        await SetupState.shared.prepare()
        return ApplicationOptions()
    })
}

@_cdecl("probe_handle")
public func probeHandle(_ call: Int32, _ metadata: UnsafePointer<UInt8>, _ metadataCount: Int32,
                        _ body: UnsafePointer<UInt8>, _ bodyCount: Int32) {
    WasmServer.handle(call, metadata: metadata, metadataCount: metadataCount, body: body, bodyCount: bodyCount)
}

@main private enum ServerProbe { static func main() {} }
