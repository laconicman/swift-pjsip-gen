import Foundation
import PackagePlugin

/// Build-tool plugin that runs `pjsip-swift-gen generate` on every build of the
/// consuming target.
///
/// Output discovery uses a "list-outputs" subprocess in `createBuildCommands`,
/// so the plugin avoids duplicating header-parsing logic and still benefits
/// from SwiftPM's incremental build caching for the actual `generate` step.
///
/// When invoked from SwiftPM (`swift build`), the plugin auto-discovers the
/// `swift-pjsip` checkout and passes its xcframework Headers directory to the
/// executable via `--pjsip-headers-dir`. In Xcode build-tool contexts that
/// auto-discovery is not available, so consumers must set `pjprojectRoot` in
/// `pjsip-swift-gen.json`.
@main
struct PJSIPSwiftGenPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        guard let sourceTarget = target as? SourceModuleTarget else {
            return []
        }
        let configPath = sourceTarget.directory
            .appending("pjsip-swift-gen.json")
        let pjsipHeadersDir = locatePJSIPHeaders(in: context.package)
        return try makeBuildCommands(
            configPath: configPath,
            toolPath: try context.tool(named: "pjsip-swift-gen").path,
            outputDir: context.pluginWorkDirectory.appending("GeneratedSources"),
            pjsipHeadersDir: pjsipHeadersDir
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension PJSIPSwiftGenPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(
        context: XcodePluginContext,
        target: XcodeTarget
    ) throws -> [Command] {
        guard let configPath = target.inputFiles
            .first(where: {
                $0.path.lastComponent == "pjsip-swift-gen.json"
            })?.path
        else {
            Diagnostics.warning(
                "pjsip-swift-gen.json not found "
                + "in target '\(target.displayName)'"
            )
            return []
        }
        // XcodePluginContext has no view of SwiftPM dependencies, so we cannot
        // auto-discover `swift-pjsip` here. The consumer's config must set
        // `pjprojectRoot` to the xcframework's Headers directory.
        return try makeBuildCommands(
            configPath: configPath,
            toolPath: try context.tool(named: "pjsip-swift-gen").path,
            outputDir: context.pluginWorkDirectory.appending("GeneratedSources"),
            pjsipHeadersDir: nil
        )
    }
}
#endif

// MARK: - Shared command construction

extension PJSIPSwiftGenPlugin {
    fileprivate func makeBuildCommands(
        configPath: Path,
        toolPath: Path,
        outputDir: Path,
        pjsipHeadersDir: Path?
    ) throws -> [Command] {
        var commonArgs = [configPath.string]
        if let pjsipHeadersDir {
            commonArgs += ["--pjsip-headers-dir", pjsipHeadersDir.string]
        }

        let outputNames = try discoverExpectedOutputs(
            toolPath: toolPath,
            arguments: ["list-outputs"] + commonArgs
        )
        let outputFiles = outputNames.map { outputDir.appending($0) }

        return [
            .buildCommand(
                displayName: "Generate PJSIP Swift helpers",
                executable: toolPath,
                arguments:
                    ["generate"]
                    + commonArgs
                    + ["--output-dir", outputDir.string],
                inputFiles: [configPath],
                outputFiles: outputFiles
            ),
        ]
    }

    /// Invokes the generator executable in `list-outputs` mode and returns
    /// the expected filenames, one per stdout line.
    fileprivate func discoverExpectedOutputs(
        toolPath: Path,
        arguments: [String]
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath.string)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PJSIPSwiftGenPluginError.listOutputsFailed(
                exitCode: process.terminationStatus
            )
        }

        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

// MARK: - swift-pjsip discovery

extension PJSIPSwiftGenPlugin {
    /// Walks the consumer's transitive dependency tree for the `swift-pjsip`
    /// package (declared as `name: "PJSIP"` in its manifest) and returns the
    /// path to a Headers directory inside its xcframework, or `nil` if it
    /// cannot be located.
    fileprivate func locatePJSIPHeaders(in package: Package) -> Path? {
        guard let pjsipPackage = findDependency(
            displayName: pjsipPackageName,
            in: package,
            visited: []
        ) else {
            Diagnostics.remark(
                "swift-pjsip not found in dependency graph; "
                + "falling back to `pjprojectRoot` from the config."
            )
            return nil
        }

        let xcframework = pjsipPackage.directory
            .appending([xcframeworkSubpath, xcframeworkName])

        guard let slice = firstSlice(under: xcframework) else {
            Diagnostics.warning(
                "Could not find a platform slice with Headers/ inside "
                + xcframework.string
            )
            return nil
        }
        return xcframework.appending([slice, "Headers"])
    }

    private func findDependency(
        displayName name: String,
        in package: Package,
        visited: Set<Package.ID>
    ) -> Package? {
        if package.displayName == name { return package }
        var visited = visited
        visited.insert(package.id)
        for dep in package.dependencies {
            if visited.contains(dep.package.id) { continue }
            if let hit = findDependency(
                displayName: name,
                in: dep.package,
                visited: visited
            ) {
                return hit
            }
        }
        return nil
    }

    private func firstSlice(under xcframework: Path) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: xcframework.string)
        else { return nil }
        return entries
            .filter { $0 != "Info.plist" && !$0.hasPrefix(".") }
            .sorted()
            .first { entry in
                let headersDir = xcframework
                    .appending([entry, "Headers"])
                    .string
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: headersDir, isDirectory: &isDir)
                    && isDir.boolValue
            }
    }

    private var pjsipPackageName: String { "PJSIP" }
    private var xcframeworkSubpath: String { "Binaries" }
    private var xcframeworkName: String { "PJSIP.xcframework" }
}

enum PJSIPSwiftGenPluginError: Error, CustomStringConvertible {
    case listOutputsFailed(exitCode: Int32)

    var description: String {
        switch self {
        case .listOutputsFailed(let code):
            return "`pjsip-swift-gen list-outputs` failed with exit code \(code)."
        }
    }
}
