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
          pjsip-swift-gen list-outputs <config.json> [--pjsip-headers-dir DIR]
          pjsip-swift-gen generate     <config.json> --output-dir DIR [--pjsip-headers-dir DIR]

        Subcommands:
          list-outputs   Print one expected output filename per line, then exit.
          generate       Parse PJSIP headers and write generated Swift files into --output-dir.

        Options:
          --pjsip-headers-dir DIR  Override `pjprojectRoot` from the config.
                                   Required when the config omits `pjprojectRoot`.
          --output-dir DIR         Where `generate` should emit Swift files.

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
var pjsipHeadersDirOverride: String?
while let arg = nextArg() {
    switch arg {
    case "--output-dir":
        outputDir = nextArg()
    case "--pjsip-headers-dir":
        pjsipHeadersDirOverride = nextArg()
    default:
        fputs("Error: unknown argument '\(arg)'.\n\n", stderr)
        printUsage(to: stderr)
        exit(1)
    }
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

// CLI flag overrides the config field; at least one must be present.
let pjRoot: String
if let override = pjsipHeadersDirOverride {
    pjRoot = override
} else if let configured = config.pjprojectRoot {
    pjRoot = resolvePath(configured, relativeTo: basePath)
} else {
    fputs(
        """
        Error: PJSIP headers location is unspecified.
        Provide either `pjprojectRoot` in '\(configPath)'
        or pass `--pjsip-headers-dir DIR` on the command line.
        """,
        stderr
    )
    exit(1)
}

// MARK: - Discover types

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

    // Resolve the C macros that guard members ONCE, against the same headers we
    // just parsed — they ship with the config_site.h that built the binary, so
    // the answers are exact. Without this the guards became Swift `#if`s that are
    // always false, silently deleting members (G1).
    let macros = MacroResolver(headersRoot: pjRoot)
    if !macros.isResolved {
        fputs("  Warning: could not preprocess '\(pjRoot)' to resolve macro guards; "
              + "every guarded member will be omitted and reported.\n", stderr)
    }

    for enumType in result.enums where !manualSet.contains(enumType.name) {
        generateEnumConformances(
            enumName: enumType.name,
            headerPath: enumType.headerPath,
            outputDir: outputDir,
            imports: imports,
            ppCondition: enumType.ppCondition,
            macros: macros
        )
    }

    for structType in result.structs where !manualSet.contains(structType.name) {
        generateStructConformance(
            structName: structType.name,
            headerPath: structType.headerPath,
            outputDir: outputDir,
            imports: imports,
            ppCondition: structType.ppCondition,
            macros: macros
        )
    }

    fputs("Done. Generated files in \(outputDir).\n", stderr)

    // A guard we could not evaluate is NOT a warning to scroll past. Inside a SwiftPM
    // plugin sandbox the tool cannot tell "the macro is off" from "I was blocked from
    // asking" — SwiftPM's profile does allow process-exec and temp writes, but the Xcode
    // driver layers its own script sandboxing that upstream's own tests do not cover. Both
    // failure modes look identical from in here, and both produce silently incomplete
    // output, which is the exact defect this generator exists to prevent. So: fail the
    // build, and only when it actually bit (a run with no guarded members is unaffected).
    if GuardDiagnostics.unresolvedCount > 0 {
        fputs("""
        Error: \(GuardDiagnostics.unresolvedCount) preprocessor guard(s) could not be \
        evaluated, so the members behind them were omitted. Generated output would be \
        incomplete. If clang is unavailable or sandboxed, or the headers directory is not \
        a PJSIP headers root, fix that and re-run — do not ship this output.\n
        """, stderr)
        exit(1)
    }
}
