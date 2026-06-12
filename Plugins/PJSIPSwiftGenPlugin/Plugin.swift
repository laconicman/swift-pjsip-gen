import Foundation
import PackagePlugin

/// Build-tool plugin that runs `pjsip-swift-gen generate` on every build of the
/// consuming target.
///
/// The plugin discovers the expected output filenames itself by parsing the
/// PJSIP headers in `createBuildCommands`. SwiftPM build-tool plugins cannot
/// import library targets, so the parser/discovery code is duplicated between
/// this directory and `Sources/PJSIPSwiftGenCore/`. `scripts/check-duplicate-sources.sh`
/// guards drift.
///
/// Subprocess-based discovery was tried and fails in Xcode build-tool
/// contexts: Xcode invokes `createBuildCommands` *before* building the
/// `pjsip-swift-gen` executable, so `context.tool(named:).path` resolves to
/// a deferred `${BUILD_DIR}/...` placeholder rather than a real binary.
///
/// When invoked from SwiftPM, the plugin auto-discovers the `swift-pjsip`
/// checkout via the consumer's transitive dependencies and reads headers
/// directly from the bundled xcframework. The Xcode plugin context exposes
/// no such API, so consumers building under Xcode must set `pjprojectRoot`
/// in `pjsip-swift-gen.json`.
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
        // XcodePluginContext exposes no view of SwiftPM dependencies, so we
        // walk up from the plugin's work directory (which lives inside the
        // project's DerivedData) to locate `SourcePackages/checkouts/swift-pjsip/`.
        let pjsipHeadersDir = locatePJSIPHeadersByWalkingUp(
            from: context.pluginWorkDirectory
        )
        return try makeBuildCommands(
            configPath: configPath,
            toolPath: try context.tool(named: "pjsip-swift-gen").path,
            outputDir: context.pluginWorkDirectory.appending("GeneratedSources"),
            pjsipHeadersDir: pjsipHeadersDir
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
        Diagnostics.remark("PJSIPSwiftGen: config=\(configPath.string)")
        let config = try loadConfig(at: configPath)

        // The headers root resolves from three possible sources because the plugin
        // runs in two host environments with different APIs (SwiftPM exposes
        // dependency graph traversal, Xcode does not) plus an explicit-path
        // escape hatch in the JSON config.
        let pjRootString: String
        if let pjsipHeadersDir {
            pjRootString = pjsipHeadersDir.string
            Diagnostics.remark("PJSIPSwiftGen: auto-discovered headers=\(pjRootString)")
        } else if let configured = config.pjprojectRoot {
            pjRootString = resolvePath(
                configured,
                relativeTo: configPath.removingLastComponent().string
            )
            Diagnostics.remark("PJSIPSwiftGen: config-supplied headers=\(pjRootString)")
        } else {
            throw PJSIPSwiftGenPluginError.headersDirUnspecified(
                configPath: configPath.string
            )
        }

        let result = discoverTypes(config: config, pjprojectRoot: pjRootString)
        let manualSet = Set(config.manualTypes)
        let outputFiles = expectedOutputFilenames(
            for: result,
            manualSet: manualSet
        ).map { outputDir.appending($0) }

        Diagnostics.remark(
            "PJSIPSwiftGen: discovered \(result.enums.count) enums, "
            + "\(result.structs.count) structs → \(outputFiles.count) outputs"
        )

        // Declare every PJSIP `.h` file the generator might read so that
        // bumping `swift-pjsip` (which replaces the xcframework Headers tree)
        // invalidates the cached output and forces regeneration.
        var inputFiles: [Path] = [configPath]
        inputFiles += headerFiles(under: Path(pjRootString))

        var generateArgs: [String] = [
            "generate",
            configPath.string,
            "--output-dir",
            outputDir.string,
        ]
        if pjsipHeadersDir != nil {
            generateArgs += ["--pjsip-headers-dir", pjRootString]
        }

        return [
            .buildCommand(
                displayName: "Generate PJSIP Swift helpers",
                executable: toolPath,
                arguments: generateArgs,
                inputFiles: inputFiles,
                outputFiles: outputFiles
            ),
        ]
    }

    fileprivate func loadConfig(at path: Path) throws -> PJSIPSwiftGenConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.string))
        return try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: data)
    }

    /// Recursively collects every `.h` file under `root`.
    fileprivate func headerFiles(under root: Path) -> [Path] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root.string)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var paths: [Path] = []
        for case let url as URL in enumerator
        where url.pathExtension == "h" {
            paths.append(Path(url.path))
        }
        return paths
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

    /// Walks parent directories of `start` looking for
    /// `SourcePackages/checkouts/swift-pjsip/Binaries/PJSIP.xcframework`.
    /// Used in Xcode build-tool contexts where the plugin runs from inside
    /// DerivedData but has no SPM API to enumerate package dependencies.
    fileprivate func locatePJSIPHeadersByWalkingUp(from start: Path) -> Path? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: start.string)
        let candidateRelative = "SourcePackages/checkouts/swift-pjsip/"
            + xcframeworkSubpath + "/" + xcframeworkName

        for _ in 0..<20 {
            let candidate = dir.appendingPathComponent(candidateRelative).path
            if fm.fileExists(atPath: candidate) {
                guard let slice = firstSlice(under: Path(candidate)) else {
                    return nil
                }
                return Path(candidate).appending([slice, "Headers"])
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        Diagnostics.remark(
            "swift-pjsip checkout not found by walking up from "
            + start.string
            + "; the plugin will require `pjprojectRoot` in the JSON config."
        )
        return nil
    }
}

enum PJSIPSwiftGenPluginError: Error, CustomStringConvertible {
    case headersDirUnspecified(configPath: String)

    var description: String {
        switch self {
        case .headersDirUnspecified(let path):
            return """
                PJSIP headers location is unspecified.
                Set `pjprojectRoot` in '\(path)' or ensure `swift-pjsip` is
                in the package dependency graph.
                """
        }
    }
}
