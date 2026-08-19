import Foundation

/// Resolves the C preprocessor macros that guard members in the PJSIP headers.
///
/// **Why this exists.** `CHeaderParser` records the `#if` a discovered enum case or
/// struct field sits under, as a C macro *name*. The generators used to emit that
/// name straight into a Swift `#if`. That does not work and does not complain:
/// Swift `#if` only knows conditions declared via `-D` / `swiftSettings`, and an
/// unknown identifier there evaluates to **false**. Every guarded member was
/// therefore dropped from the generated output on every platform — silently,
/// because the result still compiles. Live casualty in the shipped headers:
/// `pj_math_stat.fmean_`, i.e. the mean of every jitter and RTT statistic.
///
/// **Why it can be resolved at all.** Swift cannot see C macros, but it does not
/// need to. The generated code is compiled against exactly *one* prebuilt binary,
/// whose `config_site.h` is fixed and ships inside the very `Headers/` directory
/// being parsed. So the value is knowable while generating: ask the preprocessor
/// once, then include or omit the member. The generated file needs no `#if` at all.
///
/// **When it cannot.** If clang is unavailable or the probe fails, `value(of:)`
/// returns `nil` and callers omit the member *and say so* on stderr. Omitting is
/// the safe direction — a member that does not exist in the binary would be a
/// compile error in the consumer — but it must never again be silent.
public struct MacroResolver {

    private let values: [String: String]

    /// `false` when the preprocessor probe could not run; every lookup then
    /// returns `nil` and callers report rather than guess.
    public let isResolved: Bool

    /// Probes `headersRoot` once and caches every macro the PJSIP config headers
    /// define. One clang invocation, ~5000 macros, regardless of lookup count.
    public init(headersRoot: String) {
        let parsed = Self.probe(headersRoot: headersRoot)
        self.values = parsed ?? [:]
        self.isResolved = parsed != nil
    }

    /// `nil` when the probe could not run at all (no clang, unreadable headers).
    private static func probe(headersRoot: String) -> [String: String]? {
        // The config headers alone carry every macro that guards a member, and —
        // unlike <pjsua.h> — they preprocess without an SDK sysroot or target
        // triple, so one probe works for any slice from any host.
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
        """

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pjsip-swift-gen-macro-probe-\(UUID().uuidString).c")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? source.write(to: tmp, atomically: true, encoding: .utf8)) != nil,
              let out = runClang(["-E", "-dM", "-I", headersRoot, tmp.path])
        else { return nil }

        // `-dM` prints one `#define NAME [value]` per macro.
        var parsed: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard line.hasPrefix("#define ") else { continue }
            let body = line.dropFirst("#define ".count)
            guard let sep = body.firstIndex(where: { $0 == " " || $0 == "(" }) else {
                parsed[String(body)] = ""      // bare `#define NAME`
                continue
            }
            // Function-like macros ("NAME(x) ...") are never member guards; skipping
            // them keeps `nil` meaning "genuinely unknown".
            guard body[sep] == " " else { continue }
            parsed[String(body[..<sep])] =
                String(body[body.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
        }
        return parsed.isEmpty ? nil : parsed
    }

    /// Whether a member guarded by `macro` exists in the binary these headers describe.
    /// `nil` means unresolvable — the caller must report, not assume.
    public func isEnabled(_ macro: String) -> Bool? {
        guard isResolved, let raw = values[macro] else { return nil }
        // A bare `#define NAME` with no value is "defined", which `#if NAME` treats
        // as 0 — but as `#ifdef NAME` treats as true. The parser does not record
        // which form it saw, so this stays unknown rather than guessing wrong.
        if raw.isEmpty { return nil }
        guard let n = Int(raw) else { return nil }   // e.g. an alias to another macro
        return n != 0
    }

    private static func runClang(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["clang"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()          // discard; a failed probe is reported by the caller
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
    /// Unresolvable. Omit (the compiling choice) but tell the operator.
    case omitUnresolved(macro: String)
}

/// Resolves one recorded `ppCondition` into an emit/omit decision.
public func resolveGuard(_ ppCondition: String?, with resolver: MacroResolver?) -> GuardOutcome {
    guard let macro = ppCondition else { return .emit }
    switch resolver?.isEnabled(macro) {
    case .some(true):  return .emit
    case .some(false): return .omit
    case .none:        return .omitUnresolved(macro: macro)
    }
}
