import Foundation
import Darwin

// Startup/process integration lane. Run from the repository root:
// swiftc SSHTunnelManager/SSHTunnelManager/Services/SingleInstanceLock.swift \
//   SSHTunnelManager/Tests/SingleInstanceLockTests.swift -o /tmp/ssh-instance-tests
// /tmp/ssh-instance-tests
@main
struct SingleInstanceLockTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--worker" {
            let lock = try SingleInstanceLock.acquire(at: URL(fileURLWithPath: CommandLine.arguments[2]))
            print(lock == nil ? "duplicate" : "owner")
            fflush(stdout)
            // Keep the lock alive until the parent releases or kills this process.
            withExtendedLifetime(lock) { _ = readLine() }
            return
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")

        // Catches missing/non-exclusive locking and accidental unlink on close.
        let owner = try Worker(url: url)
        defer { owner.stop() }
        try expect(owner.result() == "owner", "first process must own the lock")
        let duplicate = try Worker(url: url)
        try expect(duplicate.result() == "duplicate", "second process must be rejected")
        duplicate.stop()
        let third = try Worker(url: url)
        try expect(third.result() == "duplicate", "rejected process must not release the owner's lock")
        third.stop()
        owner.stop()
        let restarted = try Worker(url: url)
        try expect(restarted.result() == "owner", "normal exit must release the lock")
        // Catches stale PID/lock-file implementations that stay locked after a crash.
        kill(restarted.process.processIdentifier, SIGKILL)
        restarted.process.waitUntilExit()
        let recovered = try Worker(url: url)
        try expect(recovered.result() == "owner", "SIGKILL must release the lock")
        recovered.stop()
        print("PASS: duplicate rejection, normal restart, and crash recovery")

        // Start all contenders before reading results: a check-then-write lock
        // would allow several owners here instead of one atomic winner.
        let contenders = try (0..<8).map { _ in try Worker(url: url) }
        defer { contenders.forEach { $0.stop() } }
        let results = contenders.map { $0.result() }
        try expect(results.filter { $0 == "owner" }.count == 1, "concurrent launches must have exactly one owner: \(results)")
        try expect(results.filter { $0 == "duplicate" }.count == 7, "all other launches must be rejected")
        contenders.forEach { $0.stop() }
        print("PASS: eight concurrent launches elect one owner")

        // Catches silently continuing startup when the lock cannot be opened.
        do {
            _ = try SingleInstanceLock.acquire(at: directory.appendingPathComponent("missing/instance.lock"))
            throw Failure(description: "unavailable lock path must throw")
        } catch where (error as NSError).domain == NSPOSIXErrorDomain {
            print("PASS: unavailable lock path fails closed")
        }
        print("All single-instance checks passed.")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private final class Worker {
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()

        init(url: URL) throws {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--worker", url.path]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
        }

        func result() -> String {
            var bytes = Data()
            while let next = try? output.fileHandleForReading.read(upToCount: 1), !next.isEmpty {
                if next.first == 10 { break }
                bytes.append(next)
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        func stop() {
            if process.isRunning {
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
            }
        }

        deinit { stop() }
    }
}
