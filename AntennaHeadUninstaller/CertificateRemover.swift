import Foundation

/// Removes the self-signed TLS certificate AntennaHead creates, and any user trust
/// settings attached to it, from the login keychain.
struct CertificateRemover {
    private let security = "/usr/bin/security"

    func certificateCount() -> Int {
        guard let out = run(["find-certificate", "-a", "-c", AppIDs.certificateName, "-Z"]).output else { return 0 }
        return out.split(separator: "\n").filter { $0.hasPrefix("SHA-1 hash:") }.count
    }

    /// Deletes every matching certificate; returns how many were removed.
    @discardableResult
    func removeAll() throws -> Int {
        var removed = 0
        while certificateCount() > 0 && removed < 50 {
            let r = run(["delete-certificate", "-c", AppIDs.certificateName, "-t"])
            guard r.status == 0 else {
                throw TrashError.failed("The keychain refused to delete the certificate (\(r.output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(r.status)")).")
            }
            removed += 1
        }
        return removed
    }

    private func run(_ args: [String]) -> (status: Int32, output: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: security)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8))
    }
}
