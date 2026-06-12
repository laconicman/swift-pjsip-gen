import Foundation

/// Generator configuration loaded from a JSON file (typically `pjsip-swift-gen.json`).
public struct PJSIPSwiftGenConfig: Codable {
    /// Path to the PJSIP source tree or xcframework Headers directory, resolved
    /// relative to the config file's directory.
    ///
    /// Optional: if omitted, callers (such as the build-tool plugin) must
    /// supply a headers directory via the `--pjsip-headers-dir` CLI flag.
    public let pjprojectRoot: String?

    /// Subdirectories under the resolved headers root to scan for `.h` files.
    /// Use `[""]` (or a single empty entry) to scan the entire headers tree —
    /// appropriate when pointing at a curated xcframework Headers directory.
    public let searchRoots: [String]

    /// Root C types whose transitive struct fields are walked for further discovery.
    public let rootTypes: [String]

    /// C types to skip during discovery and code generation.
    public let skipTypes: [String]

    /// C types for which generated output should be suppressed (the user maintains a manual extension).
    public let manualTypes: [String]

    /// Swift modules to import at the top of every generated file.
    /// For example `["PJSIP"]` when consuming the `swift-pjsip` SPM module.
    public let imports: [String]?

    public init(
        pjprojectRoot: String?,
        searchRoots: [String],
        rootTypes: [String],
        skipTypes: [String],
        manualTypes: [String],
        imports: [String]?
    ) {
        self.pjprojectRoot = pjprojectRoot
        self.searchRoots = searchRoots
        self.rootTypes = rootTypes
        self.skipTypes = skipTypes
        self.manualTypes = manualTypes
        self.imports = imports
    }
}
