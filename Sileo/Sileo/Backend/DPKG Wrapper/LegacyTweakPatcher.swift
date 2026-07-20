//
//  LegacyTweakPatcher.swift
//  Sileo
//
//  Makes legacy rootful (iphoneos-arm) packages usable on an iphoneos-arm64
//  jailbreak that exposes real writable /usr/lib and /Library/Frameworks.
//
//  Tweaks published before ~2017 carry a CodeDirectory v=20001 signature whose
//  hashes are SHA-1 only. iOS 15's AMFI cannot validate those, so the dylib is
//  installed correctly, reports success, and then silently never loads. Nothing
//  in the normal dpkg/apt path notices. Re-signing with a SHA-256 code
//  directory fixes it.
//
//  Only dylibs are touched. Executables are reported but left alone, because
//  re-signing would drop any entitlements they carry.
//

import Foundation

enum LegacyTweakPatcher {

    enum Outcome {
        case resigned
        case skippedExecutable
        case failed(String)
    }

    struct FileResult {
        let path: String
        let outcome: Outcome
    }

    /// Mach-O magic numbers, little- and big-endian, thin and fat.
    private static let machOMagics: Set<UInt32> = [
        0xfeed_face, 0xcefa_edfe,   // 32-bit
        0xfeed_facf, 0xcffa_edfe,   // 64-bit
        0xcafe_babe, 0xbeba_feca    // fat
    ]

    private static func isMachO(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 4)
        guard data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        return machOMagics.contains(magic) || machOMagics.contains(magic.byteSwapped)
    }

    /// Files dpkg recorded for a package. Paths are as recorded, which for
    /// bridged directories may be a symlink that resolves into the jbroot.
    private static func fileList(for package: String, architecture: String?) -> [String] {
        var identifier = package
        if let architecture, architecture != "all" {
            identifier += ":\(architecture)"
        }
        let (status, output, _) = spawn(command: CommandPath.dpkg, args: ["dpkg", "-L", identifier])
        guard status == 0 else { return [] }
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "/." }
    }

    /// Re-sign one Mach-O so it carries a SHA-256 code directory.
    private static func resign(_ path: String) -> Outcome {
        let (status, _, stderr) = spawnAsRoot(args: [CommandPath.ldid, "-Hsha256", "-S", path])
        if status == 0 {
            return .resigned
        }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "ldid exited \(status)" : detail)
    }

    /// Whether this package needs the legacy treatment at all.
    static func isLegacy(_ package: Package) -> Bool {
        DPKGArchitecture.Architecture(rawValue: package.architecture ?? "") == .rootful
    }

    private static let legacyTweakDirectory = "/Library/MobileSubstrate/DynamicLibraries"
    private static var tweakInjectDirectory: String { "\(CommandPath.prefix)/usr/lib/TweakInject" }

    /// Legacy packages ship their tweaks to /Library/MobileSubstrate/DynamicLibraries,
    /// which is a symlink into the directory ellekit actually scans. dpkg deletes
    /// that symlink when the last package owning the directory is removed, and
    /// the next install then silently creates a *real* directory - so tweaks land
    /// somewhere nothing ever looks at. Restore the link, moving across anything
    /// that ended up on the wrong side of it.
    static func repairTweakDirectoryBridge(log: (String) -> Void) {
        let fileManager = FileManager.default
        let target = tweakInjectDirectory
        guard fileManager.fileExists(atPath: target) else { return }

        let attributes = try? fileManager.attributesOfItem(atPath: legacyTweakDirectory)
        let fileType = attributes?[.type] as? FileAttributeType

        if fileType == .typeSymbolicLink {
            let destination = try? fileManager.destinationOfSymbolicLink(atPath: legacyTweakDirectory)
            if destination == target { return }
            spawnAsRoot(args: [CommandPath.rm, "-f", legacyTweakDirectory])
        } else if fileType == .typeDirectory {
            let contents = (try? fileManager.contentsOfDirectory(atPath: legacyTweakDirectory)) ?? []
            for item in contents {
                let source = (legacyTweakDirectory as NSString).appendingPathComponent(item)
                let destination = (target as NSString).appendingPathComponent(item)
                spawnAsRoot(args: [CommandPath.mv, "-f", source, destination])
                log("  moved \(item) into TweakInject\n")
            }
            // Only discard the directory once it is genuinely empty, so a failed
            // move can never destroy a tweak.
            let remaining = (try? fileManager.contentsOfDirectory(atPath: legacyTweakDirectory)) ?? []
            guard remaining.isEmpty else {
                log("  WARNING: \(legacyTweakDirectory) still has \(remaining.count) file(s), leaving it alone.\n")
                return
            }
            spawnAsRoot(args: [CommandPath.rm, "-rf", legacyTweakDirectory])
        } else if fileType != nil {
            return
        }

        spawnAsRoot(args: [CommandPath.mkdir, "-p", (legacyTweakDirectory as NSString).deletingLastPathComponent])
        spawnAsRoot(args: [CommandPath.ln, "-s", target, legacyTweakDirectory])
        log("Restored \(legacyTweakDirectory) -> TweakInject\n")
    }

    /// Patch every newly installed legacy package. Returns per-file results so
    /// the caller can surface them; also streams progress through `log`.
    @discardableResult
    static func patch(installed: [DownloadPackage], log: (String) -> Void) -> [FileResult] {
        let legacy = installed.map(\.package).filter(isLegacy)
        guard !legacy.isEmpty else { return [] }

        guard FileManager.default.isExecutableFile(atPath: CommandPath.ldid) else {
            log("Legacy tweak support: ldid not found at \(CommandPath.ldid), skipping.\n")
            log("Install the 'ldid' package, then reinstall these tweaks.\n")
            return []
        }

        // dpkg may have just destroyed the bridge, or unpacked into a real
        // directory in its place. Put it right before we go looking for files.
        repairTweakDirectoryBridge(log: log)

        var results: [FileResult] = []
        for package in legacy {
            log("Patching legacy (rootful) package \(package.package)\n")
            for path in fileList(for: package.package, architecture: package.architecture) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue,
                      isMachO(path) else { continue }

                // Leave executables alone: re-signing drops their entitlements.
                if !path.hasSuffix(".dylib") {
                    results.append(FileResult(path: path, outcome: .skippedExecutable))
                    log("  skipped (executable, entitlements preserved): \(path)\n")
                    continue
                }

                let outcome = resign(path)
                results.append(FileResult(path: path, outcome: outcome))
                switch outcome {
                case .resigned:
                    log("  re-signed for iOS 15 (SHA-256): \(path)\n")
                case .failed(let reason):
                    log("  FAILED to re-sign \(path): \(reason)\n")
                    log("  This tweak will install but will not load.\n")
                case .skippedExecutable:
                    break
                }
            }
        }

        let failures = results.filter { if case .failed = $0.outcome { return true } else { return false } }
        if failures.isEmpty {
            log("Legacy tweak patching complete. Respring to load.\n")
        } else {
            log("Legacy tweak patching finished with \(failures.count) failure(s).\n")
        }
        return results
    }
}
