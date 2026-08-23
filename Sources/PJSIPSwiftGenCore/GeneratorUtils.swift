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

/// What one generator call refused, and why.
///
/// Returned rather than accumulated in a global. The count decides whether the run fails
/// the build, so it has to mean "this run" — a `static var` would carry one caller's
/// refusals into the next call in the same process (the library is public, and the test
/// suite is a single process), and would be a mutable shared global the moment generation
/// is parallelised per type.
public struct GuardReport {
    /// One entry per member or type omitted because its guard could not be evaluated.
    public private(set) var unresolved: [String] = []

    public init() {}

    public var isEmpty: Bool { unresolved.isEmpty }
    public var count: Int { unresolved.count }

    public static func + (lhs: GuardReport, rhs: GuardReport) -> GuardReport {
        var merged = lhs
        merged.unresolved += rhs.unresolved
        return merged
    }

    /// Records a guard that could not be evaluated, and says so on stderr.
    ///
    /// Never a `#warning` in generated source — that would fire on every consumer build
    /// forever for something only this generator can fix.
    mutating func record(condition: String, member: String?, owner: String) {
        let what = member.map { "\(owner).\($0)" } ?? owner
        unresolved.append("\(what) (#if \(condition))")
        fputs("  Warning: guard '#if \(condition)' on \(what) could not be evaluated; "
              + "omitted (the compiling direction). If it should be present, check the "
              + "headers dir passed to MacroResolver.\n", stderr)
    }
}

