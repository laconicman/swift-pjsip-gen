import Foundation

/// Decides whether a member guarded by a C preprocessor condition exists in the binary
/// the parsed headers describe.
///
/// **Why this exists.** `CHeaderParser` records the `#if` a discovered enum case or struct
/// field sits under. The generators used to emit that text straight into a Swift `#if`.
/// That does not work and does not complain: Swift `#if` only knows conditions declared
/// via `-D` / `swiftSettings`, and an unknown identifier there evaluates to **false**.
/// Every guarded member was therefore dropped from the generated output on every
/// platform, silently, because the result still compiles. Live casualty in the shipped
/// headers: `pj_math_stat.fmean_`, i.e. the mean of every jitter and RTT statistic.
///
/// **Why it can be resolved at all.** Swift cannot see C macros, but it does not need to.
/// The generated code is compiled against exactly *one* prebuilt binary, whose
/// `config_site.h` ships inside the very `Headers/` directory being parsed. So the answer
/// is knowable while generating: ask the preprocessor, then include or omit. The generated
/// file needs no `#if` at all.
///
/// **Why it evaluates conditions rather than macro values.** An earlier version looked up
/// the macro *name* and tested its value for non-zero. That is wrong for every inverted or
/// comparing guard — `#ifndef X`, `#if !X`, `#if X == 0`, `#if X < 2` — where a truthy
/// macro means the member is *absent*. Getting that backwards emits a member the C
/// preprocessor removed, which is a hard compile error in the consumer, and is strictly
/// worse than the bug being fixed. So the whole condition is handed to clang verbatim and
/// clang decides. This also disposes of non-integer macro values (`(1)`, hex, aliases) for
/// free, since clang evaluates them the same way the real build does.
///
/// **When it cannot.** If clang is unavailable, the headers do not preprocess, or the
/// condition is one the parser could not attribute, `isEnabled` returns `nil` and callers
/// omit the member *and report it*. Omitting is the safe direction — a member absent from
/// the binary would be a consumer compile error — but it must never again be silent.
public final class MacroResolver {

    private let includeDirs: [String]
    private var cache: [String: Bool?] = [:]

    /// `false` when the headers could not be preprocessed at all; every lookup then
    /// returns `nil` and callers report rather than guess.
    public private(set) var isResolved: Bool = false

    /// Probes `headersRoot` once to confirm the config headers are reachable, then
    /// evaluates conditions lazily and memoises them.
    public init(headersRoot: String) {
        self.includeDirs = Self.includeDirs(under: headersRoot)
        // `defined(PJ_AUTOCONF)` is true by construction in the probe preamble, so this
        // succeeds exactly when the headers preprocess at all.
        self.isResolved = evaluateUncached("defined(PJ_AUTOCONF)") == true
    }

    /// Whether a member guarded by `condition` exists in the binary these headers
    /// describe. `nil` means unresolvable — the caller must report, not assume.
    public func isEnabled(_ condition: String) -> Bool? {
        if let hit = cache[condition] { return hit }
        let value = isResolved ? evaluateUncached(condition) : nil
        cache[condition] = value
        return value
    }

    // MARK: - Preprocessing

    /// The include search path. `headersRoot` alone covers the xcframework's flat
    /// `Headers/` layout; a raw `pjproject` checkout — still a documented way to point the
    /// generator at sources — keeps them under `<subproject>/include`, so those are added
    /// when present. Without them the probe would fail on a raw tree and every guarded
    /// member would be omitted.
    private static func includeDirs(under root: String) -> [String] {
        var dirs = [root]
        let fm = FileManager.default
        for sub in ["pjlib", "pjlib-util", "pjnath", "pjmedia", "pjsip"] {
            let candidate = root + "/" + sub + "/include"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                dirs.append(candidate)
            }
        }
        return dirs
    }

    /// Asks clang to evaluate one condition, exactly as the real build would.
    ///
    /// The config headers alone carry every macro that can guard a member and — unlike
    /// `<pjsua.h>` — preprocess without an SDK sysroot or target triple, so one form works
    /// for any slice from any host.
    ///
    /// Every include is **mandatory on purpose**. Wrapping them in `__has_include` would
    /// let the probe succeed with, say, `pjmedia/config.h` missing — and then every
    /// `PJMEDIA_*` condition would quietly evaluate to 0, because C reads an undefined
    /// identifier in `#if` as 0. That is a confident wrong answer. Failing the whole probe
    /// instead costs the guarded members (they are omitted) but says so, once, out loud.
    private func evaluateUncached(_ condition: String) -> Bool? {
        let source = """
        #define PJ_AUTOCONF 1
        #include <pj/config.h>
        #include <pjlib-util/config.h>
        #include <pjnath/config.h>
        #include <pjmedia/config.h>
        #include <pjmedia-audiodev/config.h>
        #include <pjmedia-videodev/config.h>
        #include <pjmedia-codec/config.h>
        #include <pjsip/sip_config.h>
        #if \(condition)
        __PJGEN_CONDITION_IS_TRUE__
        #else
        __PJGEN_CONDITION_IS_FALSE__
        #endif
        """

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pjsip-swift-gen-probe-\(UUID().uuidString).c")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? source.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }

        var args = ["-E", "-P"]
        for dir in includeDirs { args += ["-I", dir] }
        args.append(tmp.path)
        guard let out = Self.runClang(args) else { return nil }

        // A malformed condition makes clang fail, which runClang already turned into nil.
        // Both markers present would mean the probe text leaked; treat as unresolvable.
        let isTrue = out.contains("__PJGEN_CONDITION_IS_TRUE__")
        let isFalse = out.contains("__PJGEN_CONDITION_IS_FALSE__")
        guard isTrue != isFalse else { return nil }
        return isTrue
    }

    private static func runClang(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang"] + args
        let out = Pipe()
        p.standardOutput = out
        // nullDevice, NOT a Pipe: an unread pipe deadlocks the moment clang emits more
        // diagnostics than its buffer holds — it blocks writing stderr, never closes
        // stdout, and the read below waits forever. A failed probe is reported by the
        // caller, so the diagnostics themselves are not needed.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Decision for one guarded member or type.
public enum GuardOutcome {
    /// No guard, or the guard resolved true — emit it.
    case emit
    /// The guard resolved false — the member does not exist in the binary.
    case omit
    /// Unresolvable. Omit (the compiling direction) but tell the operator.
    case omitUnresolved(condition: String)
}

/// Resolves one recorded `ppCondition` into an emit/omit decision.
public func resolveGuard(_ ppCondition: String?, with resolver: MacroResolver?) -> GuardOutcome {
    guard let condition = ppCondition else { return .emit }
    // Checked BEFORE the preprocessor: C treats an undefined identifier in `#if` as 0, so
    // handing the sentinel to clang would come back a perfectly confident "false" and the
    // member would be dropped silently — the exact failure mode this whole file exists to
    // end. It has to be refused explicitly.
    guard condition != unresolvableCondition else {
        return .omitUnresolved(condition: condition)
    }
    guard let resolver, let value = resolver.isEnabled(condition) else {
        return .omitUnresolved(condition: condition)
    }
    return value ? .emit : .omit
}

/// Combines the guards that must *all* hold before something may be emitted — a
/// count+array pair, where the two fields can carry different conditions. Any non-`emit`
/// wins, and an unresolved one is preferred as the outcome so it gets reported.
public func resolveGuards(_ conditions: [String?], with resolver: MacroResolver?) -> GuardOutcome {
    var outcome = GuardOutcome.emit
    for condition in conditions {
        switch resolveGuard(condition, with: resolver) {
        case .emit: continue
        case .omitUnresolved(let c): return .omitUnresolved(condition: c)
        case .omit: outcome = .omit
        }
    }
    return outcome
}
