import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class Output: @unchecked Sendable {
    private let lock = NSLock()
    func write(_ value: JSON) throws {
        let bytes = try JSONEncoder().encode(value) + Data([10])
        guard bytes.count <= 16 * 1024 * 1024 else { throw ProtocolFailure.violation }
        try lock.withLock { try FileHandle.standardOutput.write(contentsOf: bytes) }
    }
}

@main struct Main {
    static func main() async {
        let driver: Driver
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 4, args[0] == "--plain-sdk", args[2] == "--auth-sdk",
                  args[1].hasPrefix("/"), args[3].hasPrefix("/") else { throw ProtocolFailure.violation }
            let credentials = try loadCredentials(descriptor: 3)
            let output = Output()
            driver = Driver(credentials: credentials, output: { try output.write($0) })
        } catch { exit(1) }
        do {
            let input = AsyncThrowingStream<Data, any Error> { continuation in
                DispatchQueue.global().async {
                    var framer = Framer(limit: 16 * 1024 * 1024)
                    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                    do {
                        while true {
                            let count = read(STDIN_FILENO, &buffer, buffer.count)
                            if count < 0, errno == EINTR { continue }
                            guard count >= 0 else { throw ProtocolFailure.violation }
                            if count == 0 { break }
                            for line in try framer.append(Data(buffer.prefix(count))) { continuation.yield(line) }
                        }
                        try framer.end()
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
            for try await line in input {
                var parser = try JSONParser(line)
                try await driver.receive(parser.parse())
            }
            await driver.shutdown()
        } catch {
            await driver.shutdown()
            exit(1)
        }
    }
}
