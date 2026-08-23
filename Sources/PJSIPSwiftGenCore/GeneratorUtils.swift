import Foundation

func writeGenerated(_ content: String, to path: String) {
    do {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        fputs("  Written: \(path)\n", stderr)
    } catch {
        fputs("  Error writing '\(path)': \(error)\n", stderr)
    }
}

/// Writes a generated file unless the existing one is a hand-written override.
///
/// A file that does not start with the auto-gen marker was written by a human and is left
/// alone. This matters most for the guarded-out stubs: when a guard is merely
/// *unresolvable* the type may well exist, and clobbering someone's real conformance with
/// an empty stub would be a worse failure than the one being fixed.
func writeGeneratedUnlessOverridden(_ content: String, to path: String) {
    if FileManager.default.fileExists(atPath: path),
       let existing = try? String(contentsOfFile: path, encoding: .utf8),
       !existing.hasPrefix(autoGenMarker) {
        fputs("  Skipped (overridden): \(path)\n", stderr)
        return
    }
    writeGenerated(content, to: path)
}

// MARK: - Guarded members

/// Marker every generated file starts with. A file lacking it is treated as a
/// hand-written override and never overwritten.
let autoGenMarker = "// Auto-generated"

/// Body for a type that does not exist in the binary these headers describe.
///
/// The file is still written — the build-tool plugin declares its outputs at plan
/// time, so a file that simply vanishes breaks incremental builds. It declares
/// nothing, which is exactly what the old always-false Swift `#if` achieved by
/// accident; the difference is that it now says why.
func absentTypeStub(_ typeName: String, guardedBy condition: String?, resolved: Bool) -> String {
    let reason = resolved
        ? "`\(condition ?? "?")` is false for the config_site.h this binary was built "
          + "with, so the type is not in the headers."
        : "`\(condition ?? "?")` could not be evaluated, so this generator declined to "
          + "guess. If the type does exist, fix the probe — see MacroResolver — and "
          + "regenerate."
    return """
    \(autoGenMarker): nothing to generate for `\(typeName)`.
    // \(reason)
    // Deliberately empty rather than absent: outputs are declared at plan time.

    """
}

/// Tally of guards this run could not evaluate.
///
/// Exists because a warning in a build log is easy to miss, and the thing being warned
/// about is exactly the failure this generator was written to end. `main` turns a non-zero
/// count into a non-zero exit, so a build that could not resolve its guards fails loudly
/// instead of quietly shipping incomplete conformances.
public enum GuardDiagnostics {
    public static var unresolvedCount = 0
    public static func reset() { unresolvedCount = 0 }
}

/// Reports a guard the preprocessor probe could not resolve.
///
/// Always to stderr, never as a `#warning` in generated source — a `#warning`
/// would fire on every consumer build forever for a condition only this
/// generator can fix.
func reportUnresolvedGuard(condition: String, member: String?, owner: String) {
    GuardDiagnostics.unresolvedCount += 1
    let what = member.map { "\(owner).\($0)" } ?? owner
    fputs("  Warning: guard '#if \(condition)' on \(what) could not be evaluated; "
          + "omitted (the compiling direction). If it should be present, check the "
          + "headers dir passed to MacroResolver.\n", stderr)
}
