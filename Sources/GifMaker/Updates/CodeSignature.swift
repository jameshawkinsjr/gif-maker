import Foundation
import Security

/// Questions about an app bundle's code signature.
enum CodeSignature {
    /// Checks that the bundle's signature is intact: every file is the one that
    /// was signed. This says nothing about who signed it; an ad-hoc signature
    /// passes too.
    static func verify(_ app: URL) throws {
        try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// Whether `candidate` satisfies the designated requirement of `reference`:
    /// the test macOS applies when it decides if an app is still the one that
    /// was given a privacy permission such as Screen Recording.
    ///
    /// Builds signed with the same certificate pass. An ad-hoc signature's
    /// requirement is the exact build, so every new ad-hoc build fails.
    static func satisfiesDesignatedRequirement(of reference: URL, candidate: URL) -> Bool {
        guard let referenceCode = staticCode(at: reference), let candidateCode = staticCode(at: candidate) else {
            return false
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(referenceCode, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecStaticCodeCheckValidity(candidateCode, [], requirement) == errSecSuccess
    }

    /// Whether the bundle is signed ad-hoc, i.e. without a certificate.
    static func isAdHoc(_ app: URL) -> Bool {
        guard let code = staticCode(at: app) else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let flags = (information as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32
        else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}

/// Runs command-line tools.
enum Shell {
    struct Failure: LocalizedError {
        let tool: String
        let status: Int32
        let output: String

        var errorDescription: String? {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            return output.isEmpty ? "\(name) failed (status \(status))" : "\(name): \(output)"
        }
    }

    /// Runs a tool to completion and returns what it printed. Throws if it
    /// can't be started or exits with an error.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting, so a chatty tool can't fill the pipe and stall.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(tool: tool, status: process.terminationStatus, output: output)
        }
        return output
    }
}
