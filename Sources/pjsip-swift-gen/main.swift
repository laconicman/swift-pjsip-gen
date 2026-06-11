import Foundation
import PJSIPSwiftGenCore

// MARK: - CLI arguments

/// Subcommand the executable supports.
/// - `listOutputs`: print expected output filenames (one per line) and exit.
///   Used by build-tool plugins to declare outputs up-front.
/// - `generate`: full code generation; emits files into `--output-dir`.
enum Subcommand: String {
    case listOutputs = "list-outputs"
    case generate
}

func printUsage(to stream: UnsafeMutablePointer<FILE>) {
    fputs(
        """
        Usage:
          pjsip-swift-gen list-outputs <config.json>
          pjsip-swift-gen generate     <config.json> --output-dir DIR

        Subcommands:
          list-outputs   Print one expected output filename per line, then exit.
          generate       Parse PJSIP headers and write generated Swift files into DIR.

        """,
        stream
    )
}

var rawArgs = Array(CommandLine.arguments.dropFirst())
func nextArg() -> String? { rawArgs.isEmpty ? nil : rawArgs.removeFirst() }

guard let verbRaw = nextArg(),
      let subcommand = Subcommand(rawValue: verbRaw) else {
    printUsage(to: stderr)
    exit(1)
}

guard let configPath = nextArg() else {
    fputs("Error: missing <config.json> argument.\n\n", stderr)
    printUsage(to: stderr)
    exit(1)
}

var outputDir: String?
while let arg = nextArg() {
    if arg == "--output-dir" { outputDir = nextArg() }
}

// MARK: - Read configuration

let configURL = URL(fileURLWithPath: configPath)
let basePath = configURL.deletingLastPathComponent().path

guard let configData = try? Data(contentsOf: configURL) else {
    fputs("Error: cannot read '\(configPath)'.\n", stderr)
    exit(1)
}

let config: PJSIPSwiftGenConfig
do {
    config = try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: configData)
} catch {
    fputs("Error parsing config: \(error)\n", stderr)
    exit(1)
}

// MARK: - Discover types

let pjRoot = resolvePath(config.pjprojectRoot, relativeTo: basePath)
let result = discoverTypes(config: config, pjprojectRoot: pjRoot)
let manualSet = Set(config.manualTypes)

// MARK: - Dispatch

switch subcommand {

case .listOutputs:
    for name in expectedOutputFilenames(for: result, manualSet: manualSet) {
        print(name)
    }

case .generate:
    guard let outputDir else {
        fputs("Error: --output-dir is required for `generate`.\n", stderr)
        exit(1)
    }

    fputs(
        "Discovered \(result.enums.count) enums, \(result.structs.count) structs.\n",
        stderr
    )

    try FileManager.default.createDirectory(
        atPath: outputDir,
        withIntermediateDirectories: true
    )

    let imports = config.imports ?? []

    for enumType in result.enums where !manualSet.contains(enumType.name) {
        generateEnumConformances(
            enumName: enumType.name,
            headerPath: enumType.headerPath,
            outputDir: outputDir,
            imports: imports,
            ppCondition: enumType.ppCondition
        )
    }

    for structType in result.structs where !manualSet.contains(structType.name) {
        generateStructConformance(
            structName: structType.name,
            headerPath: structType.headerPath,
            outputDir: outputDir,
            imports: imports,
            ppCondition: structType.ppCondition
        )
    }

    fputs("Done. Generated files in \(outputDir).\n", stderr)
}
