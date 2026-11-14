import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Which version is installed, which ones are trusted, and whether one is waiting to prove itself.
/// Read and written by the daemon (on propose/rollback) and by intentguard (on verify/auto-rollback).
public struct UpdateState: Codable {
    public var current: String
    /// Versions that have started successfully, oldest first.
    public var knownGood: [String]
    /// A just-applied version that hasn't passed its health check yet.
    public var pending: String?
    /// The version to go back to if `pending` fails.
    public var previous: String?
    public var pendingSince: Double?

    public init(current: String, knownGood: [String], pending: String? = nil, previous: String? = nil, pendingSince: Double? = nil) {
        self.current = current; self.knownGood = knownGood; self.pending = pending
        self.previous = previous; self.pendingSince = pendingSince
    }

    public static func load(_ path: String = Paths.updateState) -> UpdateState? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(UpdateState.self, from: d)
    }

    public func save(_ path: String = Paths.updateState) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileUtil.writeAtomically(try enc.encode(self), to: path, mode: 0o644)
    }

    /// Atomically repoints base/current → versions/<version>.
    public static func pointCurrent(to version: String) throws {
        let tmp = Paths.base + "/current.tmp"
        try? FileManager.default.removeItem(atPath: tmp)
        try FileManager.default.createSymbolicLink(atPath: tmp, withDestinationPath: "versions/\(version)")
        guard rename(tmp, Paths.current) == 0 else {
            throw ConfigError("could not switch 'current' to \(version) (errno \(errno))")
        }
    }
}

/// manifest.json inside an update package. manifest.sig holds a base64 Ed25519 signature
/// over the exact bytes of manifest.json.
public struct PackageManifest: Codable {
    public var version: String
    public var changelog: String
    public var created: String
    /// relative path → lowercase hex SHA-256
    public var files: [String: String]
}

public enum PackageTool {
    /// Files every package must contain.
    public static let requiredFiles = [
        "bin/intentmoded",
        "bin/intentmode",
        "bin/intentguard",
        "IntentScreen.app/Contents/MacOS/IntentScreen",
        "IntentScreen.app/Contents/Info.plist",
        "Resources/config.default.json",
        "Resources/emergency-off.sh",
        "Resources/uninstall.sh",
    ]

    static let manifestName = "manifest.json"
    static let signatureName = "manifest.sig"

    /// All regular files under root (relative paths, sorted), excluding manifest + signature.
    /// Symlinks are rejected so a package cannot point outside itself.
    public static func listFiles(_ root: String) throws -> [String] {
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard let en = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else {
            throw ConfigError("cannot read package at \(root)")
        }
        var out: [String] = []
        for case let url as URL in en {
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let rel = String(full.dropFirst(prefix.count))
            if vals.isSymbolicLink == true { throw ConfigError("package contains a symlink: \(rel)") }
            if vals.isDirectory == true { continue }
            if vals.isRegularFile == true, rel != manifestName, rel != signatureName { out.append(rel) }
        }
        return out.sorted()
    }

    #if canImport(CryptoKit)
    public static func sha256(file: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func generateKeyPair() -> (privateKey: Data, publicKey: Data) {
        let k = Curve25519.Signing.PrivateKey()
        return (k.rawRepresentation, k.publicKey.rawRepresentation)
    }

    public static func publicKey(fromPrivate priv: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: priv).publicKey.rawRepresentation
    }

    /// Hashes every file and writes manifest.json + manifest.sig into the package folder.
    public static func sign(root: String, version: String, changelog: String, privateKey: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        var files: [String: String] = [:]
        for rel in try listFiles(root) { files[rel] = try sha256(file: root + "/" + rel) }
        for req in requiredFiles where files[req] == nil { throw ConfigError("package is missing \(req)") }
        let manifest = PackageManifest(version: version, changelog: changelog,
                                       created: ISO8601DateFormatter().string(from: Date()), files: files)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(manifest)
        let sig = try key.signature(for: data)
        try data.write(to: URL(fileURLWithPath: root + "/" + manifestName))
        try Data(sig.base64EncodedString().utf8).write(to: URL(fileURLWithPath: root + "/" + signatureName))
    }

    /// Checks the signature, every file hash, that no extra files exist, and that required files are present.
    public static func verify(root: String, publicKey: Data) throws -> PackageManifest {
        let mData = try Data(contentsOf: URL(fileURLWithPath: root + "/" + manifestName))
        let sigText = try String(contentsOfFile: root + "/" + signatureName, encoding: .utf8)
        guard let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ConfigError("manifest.sig is not valid base64")
        }
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard pub.isValidSignature(sig, for: mData) else {
            throw ConfigError("signature check FAILED: this package was not signed with your key")
        }
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: mData)
        guard VersionCompare.parse(manifest.version) != nil else { throw ConfigError("bad version '\(manifest.version)'") }
        let present = try listFiles(root)
        let expected = manifest.files.keys.sorted()
        if present != expected {
            let extra = Set(present).subtracting(expected).sorted()
            let missing = Set(expected).subtracting(present).sorted()
            throw ConfigError("package files differ from manifest. extra: \(extra) missing: \(missing)")
        }
        for (rel, hash) in manifest.files where try sha256(file: root + "/" + rel) != hash {
            throw ConfigError("file was modified after signing: \(rel)")
        }
        for req in requiredFiles where manifest.files[req] == nil { throw ConfigError("package is missing \(req)") }
        return manifest
    }
    #endif

    public static func loadKey(_ path: String) throws -> Data {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        guard let d = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 32 else {
            throw ConfigError("\(path) does not contain a valid key")
        }
        return d
    }
}
