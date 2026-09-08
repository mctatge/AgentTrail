import Foundation
import Darwin

public final class WriterLease {
    private let descriptor: Int32

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(root.appendingPathComponent("recorder.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TrailError.message("Could not open the recording library lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw TrailError.message("Another AgentTrail process is writing this library. Use the existing app or choose another --root.")
        }
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
