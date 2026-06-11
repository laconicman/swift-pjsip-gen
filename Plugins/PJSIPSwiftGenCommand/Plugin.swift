import Foundation
import PackagePlugin

/// Command plugin that runs `pjsip-swift-gen generate` on demand.
///
/// Invoked via `swift package plugin generate-pjsip-helpers [--target NAME]
/// [--output-dir PATH]`. Generated files are written under the target's
/// source directory by default, so they are version-controlled.
@main
struct PJSIPSwiftGenCommand: CommandPlugin {
    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        let parsed = try CommandArguments.parse(arguments)
        let toolPath = try context.tool(named: "pjsip-swift-gen").path

        // Pick the targets to generate for.
        let targets: [SourceModuleTarget]
        if let targetName = parsed.target {
            targets = context.package.targets
                .compactMap { $0 as? SourceModuleTarget }
                .filter { $0.name == targetName }
            if targets.isEmpty {
                throw PJSIPSwiftGenCommandError.targetNotFound(targetName)
            }
        } else {
            targets = context.package.targets
                .compactMap { $0 as? SourceModuleTarget }
        }

        for target in targets {
            try run(
                forTarget: target,
                toolPath: toolPath,
                outputOverride: parsed.outputDir
            )
        }
    }

    private func run(
        forTarget target: SourceModuleTarget,
        toolPath: Path,
        outputOverride: String?
    ) throws {
        let configPath = target.directory.appending("pjsip-swift-gen.json")
        guard FileManager.default.fileExists(atPath: configPath.string) else {
            Diagnostics.remark(
                "Skipping target '\(target.name)': no pjsip-swift-gen.json."
            )
            return
        }

        let outputDir: String = outputOverride
            ?? target.directory.appending("Generated").string

        try FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath.string)
        process.arguments = [
            "generate",
            configPath.string,
            "--output-dir",
            outputDir,
        ]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PJSIPSwiftGenCommandError.generationFailed(
                target: target.name,
                exitCode: process.terminationStatus
            )
        }
    }
}

// MARK: - Argument parsing

private struct CommandArguments {
    var target: String?
    var outputDir: String?

    static func parse(_ raw: [String]) throws -> CommandArguments {
        var iter = raw.makeIterator()
        var result = CommandArguments()
        while let arg = iter.next() {
            switch arg {
            case "--target":
                result.target = iter.next()
            case "--output-dir":
                result.outputDir = iter.next()
            case "--help", "-h":
                Diagnostics.remark(Self.usage)
            default:
                throw PJSIPSwiftGenCommandError.unknownArgument(arg)
            }
        }
        return result
    }

    static let usage = """
    Usage: swift package plugin generate-pjsip-helpers \
    [--target NAME] [--output-dir PATH]

      --target NAME       Generate for this target only.  Defaults to every
                          target that contains a `pjsip-swift-gen.json`.
      --output-dir PATH   Write generated files here.  Defaults to
                          `<target>/Generated`.
    """
}

// MARK: - Errors

enum PJSIPSwiftGenCommandError: Error, CustomStringConvertible {
    case targetNotFound(String)
    case generationFailed(target: String, exitCode: Int32)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .targetNotFound(let name):
            return "Target '\(name)' not found in the package."
        case .generationFailed(let target, let code):
            return "`pjsip-swift-gen generate` for '\(target)' failed with exit code \(code)."
        case .unknownArgument(let arg):
            return "Unknown argument '\(arg)'."
        }
    }
}
