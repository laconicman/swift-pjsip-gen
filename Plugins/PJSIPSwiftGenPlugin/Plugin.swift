import Foundation
import PackagePlugin

/// Build-tool plugin that runs `pjsip-swift-gen generate` on every build of the
/// consuming target.
///
/// Output discovery uses a "list-outputs" subprocess in `createBuildCommands`,
/// so the plugin avoids duplicating header-parsing logic and still benefits
/// from SwiftPM's incremental build caching for the actual `generate` step.
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
        return try makeBuildCommands(
            configPath: configPath,
            toolPath: try context.tool(named: "pjsip-swift-gen").path,
            outputDir: context.pluginWorkDirectory.appending("GeneratedSources")
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
        return try makeBuildCommands(
            configPath: configPath,
            toolPath: try context.tool(named: "pjsip-swift-gen").path,
            outputDir: context.pluginWorkDirectory.appending("GeneratedSources")
        )
    }
}
#endif

// MARK: - Shared command construction

extension PJSIPSwiftGenPlugin {
    fileprivate func makeBuildCommands(
        configPath: Path,
        toolPath: Path,
        outputDir: Path
    ) throws -> [Command] {
        let outputNames = try discoverExpectedOutputs(
            toolPath: toolPath,
            configPath: configPath
        )
        let outputFiles = outputNames.map { outputDir.appending($0) }

        return [
            .buildCommand(
                displayName: "Generate PJSIP Swift helpers",
                executable: toolPath,
                arguments: [
                    "generate",
                    configPath.string,
                    "--output-dir",
                    outputDir.string,
                ],
                inputFiles: [configPath],
                outputFiles: outputFiles
            ),
        ]
    }

    /// Invokes the generator executable in `list-outputs` mode and returns
    /// the expected filenames, one per stdout line.
    fileprivate func discoverExpectedOutputs(
        toolPath: Path,
        configPath: Path
    ) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath.string)
        process.arguments = ["list-outputs", configPath.string]

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

enum PJSIPSwiftGenPluginError: Error, CustomStringConvertible {
    case listOutputsFailed(exitCode: Int32)

    var description: String {
        switch self {
        case .listOutputsFailed(let code):
            return "`pjsip-swift-gen list-outputs` failed with exit code \(code)."
        }
    }
}
