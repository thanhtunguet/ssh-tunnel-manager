import Foundation
import Darwin

/// A per-user, process-lifetime lock shared by every copy of the application.
/// The kernel releases it on exit (including crashes and SIGKILL).
final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Returns nil only when another instance already owns the lock.
    /// Other failures must stop startup rather than allow an unprotected instance.
    static func acquire() throws -> SingleInstanceLock? {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Match ConfigStore's directory, not the executable/bundle location:
        // Spotlight can launch a different installed copy of the same app.
        let directory = appSupport.appendingPathComponent("SSHTunnelManager", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try acquire(at: directory.appendingPathComponent("instance.lock"))
    }

    static func acquire(at url: URL) throws -> SingleInstanceLock? {
        // SSH children must not inherit the descriptor and keep the lock alive.
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            if error == EWOULDBLOCK {
                return nil
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return SingleInstanceLock(fileDescriptor: descriptor)
    }

    deinit {
        Darwin.close(fileDescriptor)
        // Never unlink the lock file: another process could still hold its inode,
        // allowing a third process to acquire a different file at the same path.
    }
}
