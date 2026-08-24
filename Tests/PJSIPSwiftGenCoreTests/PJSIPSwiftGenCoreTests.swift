import XCTest
@testable import PJSIPSwiftGenCore

final class PJSIPSwiftGenCoreTests: XCTestCase {
    func testConfigDecodes() throws {
        let json = """
        {
            "pjprojectRoot": "../headers",
            "searchRoots": ["pjsip/include"],
            "rootTypes": ["pjsua_acc_config"],
            "skipTypes": [],
            "manualTypes": [],
            "imports": ["PJSIP"]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: json)

        XCTAssertEqual(config.pjprojectRoot, "../headers")
        XCTAssertEqual(config.rootTypes, ["pjsua_acc_config"])
        XCTAssertEqual(config.imports, ["PJSIP"])
    }

    func testConfigDecodesWithoutImports() throws {
        let json = """
        {
            "pjprojectRoot": "../headers",
            "searchRoots": [],
            "rootTypes": [],
            "skipTypes": [],
            "manualTypes": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: json)
        XCTAssertNil(config.imports)
    }

    func testConfigDecodesWithoutPJProjectRoot() throws {
        // Plugin-driven workflows can omit `pjprojectRoot` because the plugin
        // supplies the headers directory via `--pjsip-headers-dir`.
        let json = """
        {
            "searchRoots": [""],
            "rootTypes": ["pjsua_acc_config"],
            "skipTypes": [],
            "manualTypes": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: json)
        XCTAssertNil(config.pjprojectRoot)
        XCTAssertEqual(config.searchRoots, [""])
    }

    func testExpectedOutputFilenamesIncludesBothEnumAndStructFiles() {
        let result = DiscoveryResult(
            enums: [
                DiscoveredType(name: "pjsip_hdr_e", kind: .enumType,
                               headerPath: "/x.h", ppCondition: nil)
            ],
            structs: [
                DiscoveredType(name: "pjsua_acc_config", kind: .structType,
                               headerPath: "/y.h", ppCondition: nil)
            ]
        )
        let names = expectedOutputFilenames(for: result, manualSet: [])
        XCTAssertEqual(Set(names), Set([
            "pjsip_hdr_e+CustomDebugStringConvertible.swift",
            "pjsip_hdr_e+CustomStringConvertible.swift",
            "pjsua_acc_config+CustomStringConvertible.swift",
        ]))
    }

    func testExpectedOutputFilenamesRespectsManualSet() {
        let result = DiscoveryResult(
            enums: [
                DiscoveredType(name: "pjsip_hdr_e", kind: .enumType,
                               headerPath: "/x.h", ppCondition: nil)
            ],
            structs: []
        )
        let names = expectedOutputFilenames(
            for: result,
            manualSet: ["pjsip_hdr_e"]
        )
        XCTAssertTrue(names.isEmpty)
    }

    // MARK: - Guarded members (G1)

    /// A C macro must never reach the generated Swift as an `#if` condition.
    /// Swift cannot see C macros, so an unknown identifier there is *false* and
    /// the member disappears with no diagnostic — the defect this guards.
    func testGuardedFieldNeverBecomesASwiftIfDirective() throws {
        let header = """
        typedef struct demo_struct {
            int always_here;
        #if DEMO_FEATURE_ON
            int guarded_field;
        #endif
            int also_here;
        } demo_struct;
        """
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let headerPath = "\(dir)/demo.h"
        try header.write(toFile: headerPath, atomically: true, encoding: .utf8)

        // No resolver: the guard is unresolvable, which must omit the member —
        // the compiling choice — and must NOT emit a Swift condition.
        generateStructConformance(
            structName: "demo_struct",
            headerPath: headerPath,
            outputDir: dir,
            macros: nil
        )

        let out = try String(
            contentsOfFile: "\(dir)/demo_struct+CustomStringConvertible.swift",
            encoding: .utf8
        )
        XCTAssertFalse(out.contains("#if"), "a C macro leaked into Swift as #if:\n\(out)")
        XCTAssertFalse(out.contains("DEMO_FEATURE_ON"))
        XCTAssertTrue(out.contains("always_here"))
        XCTAssertTrue(out.contains("also_here"))
        XCTAssertFalse(out.contains("guarded_field"), "unresolved guard must omit, not include")
    }

    /// The parser records the guard, so an unguarded member is unaffected by any
    /// of this — pins that the fix did not start dropping ordinary fields.
    func testUnguardedFieldsAreAlwaysEmitted() throws {
        let header = """
        typedef struct plain_struct {
            int a;
            int b;
        } plain_struct;
        """
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let headerPath = "\(dir)/plain.h"
        try header.write(toFile: headerPath, atomically: true, encoding: .utf8)

        generateStructConformance(
            structName: "plain_struct",
            headerPath: headerPath,
            outputDir: dir,
            macros: nil
        )

        let out = try String(
            contentsOfFile: "\(dir)/plain_struct+CustomStringConvertible.swift",
            encoding: .utf8
        )
        XCTAssertTrue(out.contains("a: "))
        XCTAssertTrue(out.contains("b: "))
        XCTAssertFalse(out.contains("#if"))
    }

    // MARK: - Guard direction (regressions caught in review of the G1 fix)

    /// Builds the minimal header tree `MacroResolver` preprocesses, with `pj/config.h`
    /// carrying the macros a test wants.
    private func makeHeaderRoot(defining defines: [String: String]) throws -> String {
        let root = try makeTempDir()
        let fm = FileManager.default
        for dir in ["pj", "pjlib-util", "pjnath", "pjmedia",
                    "pjmedia-audiodev", "pjmedia-videodev", "pjmedia-codec", "pjsip"] {
            try fm.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
        }
        let body = defines.map { "#define \($0.key) \($0.value)" }.joined(separator: "\n")
        try body.write(toFile: "\(root)/pj/config.h", atomically: true, encoding: .utf8)
        for path in ["pjlib-util/config.h", "pjnath/config.h", "pjmedia/config.h",
                     "pjmedia-audiodev/config.h", "pjmedia-videodev/config.h",
                     "pjmedia-codec/config.h", "pjsip/sip_config.h"] {
            try "".write(toFile: "\(root)/\(path)", atomically: true, encoding: .utf8)
        }
        return root
    }

    /// `#ifndef X` with X truthy means the member is NOT in the binary. Resolving on the
    /// macro's value alone got this backwards and emitted a member the C preprocessor
    /// removes — a hard compile error in the consumer, and strictly worse than the silent
    /// omission the fix was for.
    func testInvertedGuardOverTruthyMacroOmitsTheMember() throws {
        let root = try makeHeaderRoot(defining: ["DEMO_FEATURE": "1"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = MacroResolver(headersRoot: root)
        try XCTSkipUnless(resolver.isResolved, "no usable clang for the preprocessor probe")

        XCTAssertEqual(resolver.isEnabled("!defined(DEMO_FEATURE)"), false)
        XCTAssertEqual(resolver.isEnabled("defined(DEMO_FEATURE)"), true)
        XCTAssertEqual(resolver.isEnabled("DEMO_FEATURE"), true)
        XCTAssertEqual(resolver.isEnabled("!DEMO_FEATURE"), false)
        XCTAssertEqual(resolver.isEnabled("DEMO_FEATURE == 0"), false)
        XCTAssertEqual(resolver.isEnabled("DEMO_FEATURE < 2"), true)
    }

    /// A value clang can evaluate but `Int(_:)` cannot must not be treated as unknown.
    func testNonDecimalMacroValuesStillResolve() throws {
        let root = try makeHeaderRoot(defining: [
            "PARENTHESISED": "(1)", "HEXY": "0x10", "ALIASED": "PARENTHESISED", "OFFY": "(0)"
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = MacroResolver(headersRoot: root)
        try XCTSkipUnless(resolver.isResolved, "no usable clang for the preprocessor probe")

        XCTAssertEqual(resolver.isEnabled("PARENTHESISED"), true)
        XCTAssertEqual(resolver.isEnabled("HEXY"), true)
        XCTAssertEqual(resolver.isEnabled("ALIASED"), true)
        XCTAssertEqual(resolver.isEnabled("OFFY"), false)
    }

    /// The directive's meaning must survive parsing; recording only the macro name is what
    /// made the inverted cases above indistinguishable from the plain ones.
    func testNormalizedConditionPreservesTheDirectivesMeaning() {
        XCTAssertEqual(normalizedCondition(from: "#if PJ_FOO"), "PJ_FOO")
        XCTAssertEqual(normalizedCondition(from: "#ifdef PJ_FOO"), "defined(PJ_FOO)")
        XCTAssertEqual(normalizedCondition(from: "#ifndef PJ_FOO"), "!defined(PJ_FOO)")
        XCTAssertEqual(normalizedCondition(from: "#if !defined(PJ_FOO)"), "!defined(PJ_FOO)")
        XCTAssertEqual(normalizedCondition(from: "#if PJ_FOO == 0"), "PJ_FOO == 0")
    }

    /// A count+array pair carries two guards. Emitting on the count's alone can reference
    /// an array field that was compiled out.
    func testPairGuardsCombineSoEitherSideCanVeto() throws {
        let root = try makeHeaderRoot(defining: ["ON": "1", "OFF": "0"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = MacroResolver(headersRoot: root)
        try XCTSkipUnless(resolver.isResolved, "no usable clang for the preprocessor probe")

        if case .emit = resolveGuards(["ON", "ON"], with: resolver) {} else {
            XCTFail("both on should emit")
        }
        if case .omit = resolveGuards(["ON", "OFF"], with: resolver) {} else {
            XCTFail("array guard off must veto the pair")
        }
        if case .omit = resolveGuards(["OFF", "ON"], with: resolver) {} else {
            XCTFail("count guard off must veto the pair")
        }
        if case .omitUnresolved = resolveGuards(["ON", unresolvableCondition], with: resolver) {} else {
            XCTFail("an unresolvable side must be reported, not silently omitted")
        }
        // A DEFINITE omit dominates an unresolvable one: the member is absent either way, so
        // there is nothing to report — and, since an unresolved guard now fails the build,
        // reporting it here would fail a build over a member correctly left out.
        if case .omit = resolveGuards(["OFF", unresolvableCondition], with: resolver) {} else {
            XCTFail("a definite omit must win over an unresolvable guard")
        }
        if case .omit = resolveGuards([unresolvableCondition, "OFF"], with: resolver) {} else {
            XCTFail("order must not change the verdict")
        }
    }

    /// The `#else` arm holds exactly when the opening condition does not, so it must be
    /// recorded as that negation — not inherited (which would be backwards) and not simply
    /// dropped. `pj_math_stat` is the live case: `fmean_` under `#if PJ_HAS_FLOATING_POINT`,
    /// `mean_res_` under its `#else`, exactly one of which is in the binary.
    func testElseBranchMembersCarryTheNegatedCondition() throws {
        let header = """
        typedef struct branchy {
            int always;
        #if DEMO_FEATURE
            int when_on;
        #else
            int when_off;
        #endif
        } branchy;
        """
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let headerPath = "\(dir)/branchy.h"
        try header.write(toFile: headerPath, atomically: true, encoding: .utf8)

        let fields = parseStruct(named: "branchy", in: header)
        XCTAssertEqual(fields?.first(where: { $0.name == "when_on" })?.ppCondition, "DEMO_FEATURE")
        XCTAssertEqual(fields?.first(where: { $0.name == "when_off" })?.ppCondition,
                       "!(DEMO_FEATURE)")
        XCTAssertNil(fields?.first(where: { $0.name == "always" })?.ppCondition)
    }

    /// An `#elif` arm holds only when every earlier arm did not, which the single-condition
    /// model cannot express — so the rest of the chain must be refused, not guessed.
    func testElifChainIsRefusedRatherThanGuessed() throws {
        let header = """
        typedef struct chainy {
            int always;
        #if MODE_A
            int a;
        #elif MODE_B
            int b;
        #else
            int c;
        #endif
        } chainy;
        """
        let fields = parseStruct(named: "chainy", in: header)
        XCTAssertEqual(fields?.first(where: { $0.name == "a" })?.ppCondition, "MODE_A")
        XCTAssertEqual(fields?.first(where: { $0.name == "b" })?.ppCondition, unresolvableCondition)
        XCTAssertEqual(fields?.first(where: { $0.name == "c" })?.ppCondition, unresolvableCondition)
    }

    /// A guarded-out type must not clobber a hand-written conformance. When the guard is
    /// merely *unresolvable* the type may well exist, so replacing someone's real file with
    /// an empty stub would be a worse failure than the one this all fixes.
    func testStubDoesNotOverwriteAHandWrittenOverride() throws {
        let header = """
        typedef struct guarded_thing {
            int field;
        } guarded_thing;
        """
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try header.write(toFile: "\(dir)/g.h", atomically: true, encoding: .utf8)

        let outputPath = "\(dir)/guarded_thing+CustomStringConvertible.swift"
        let handWritten = "// mine, not generated\nextension guarded_thing {}\n"
        try handWritten.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // No resolver, so the type guard is unresolvable and the stub path is taken.
        generateStructConformance(
            structName: "guarded_thing",
            headerPath: "\(dir)/g.h",
            outputDir: dir,
            ppCondition: "SOME_FEATURE",
            macros: nil
        )

        XCTAssertEqual(try String(contentsOfFile: outputPath, encoding: .utf8), handWritten)
    }

    /// A type's guard must be normalised exactly like a member's — `scanHeaders` keeping the
    /// bare macro name inverted every `#ifndef`-guarded type.
    func testTypeLevelIfndefGuardIsNotInverted() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let header = """
        #ifndef MY_HEADER_H_
        #define MY_HEADER_H_
        #ifndef FEATURE_OFF
        typedef struct only_when_off { int a; } only_when_off;
        #endif
        #endif
        """
        try header.write(toFile: "\(root)/h.h", atomically: true, encoding: .utf8)

        let json = """
        {"searchRoots": [""], "rootTypes": ["only_when_off"],
         "skipTypes": [], "manualTypes": []}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: json)
        let found = discoverTypes(config: config, pjprojectRoot: root)

        // The include guard must not be mistaken for a feature guard, and the real guard
        // must keep its negation.
        XCTAssertEqual(found.structs.first(where: { $0.name == "only_when_off" })?.ppCondition,
                       "!defined(FEATURE_OFF)")
    }

    /// `#if NEVER_DEFINED_ANYWHERE` is false in C, but it is also what a probe that never
    /// saw the defining header produces. Since PJSIP's feature macros all live in the config
    /// headers, an undefined bare macro means the probe's scope is wrong more likely than
    /// the feature being off — so it must be refused, not silently dropped.
    func testBareUndefinedMacroIsRefusedRatherThanReadAsFalse() throws {
        let root = try makeHeaderRoot(defining: ["REAL_FEATURE": "0"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = MacroResolver(headersRoot: root)
        try XCTSkipUnless(resolver.isResolved, "no usable clang for the preprocessor probe")

        // Defined but zero: a real answer.
        XCTAssertEqual(resolver.isEnabled("REAL_FEATURE"), false)
        // Not defined at all: refuse.
        XCTAssertNil(resolver.isEnabled("MACRO_NOBODY_DEFINES"))
        // An explicit defined() test is the author being deliberate — answer it.
        XCTAssertEqual(resolver.isEnabled("defined(MACRO_NOBODY_DEFINES)"), false)
        XCTAssertEqual(resolver.isEnabled("!defined(MACRO_NOBODY_DEFINES)"), true)
    }

    /// scanHeaders pushes for every `#if` form. Requiring a trailing space meant a spaceless
    /// `#if(X)` pushed nothing while its `#endif` still popped, misaligning the stack for
    /// every later type in the file.
    func testSpacelessIfDoesNotMisalignTheTypeGuardStack() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let header = """
        #ifndef GUARD_H_
        #define GUARD_H_
        #if(SOMETHING)
        typedef struct inside_spaceless { int a; } inside_spaceless;
        #endif
        typedef struct after_it { int b; } after_it;
        #endif
        """
        try header.write(toFile: "\(root)/h.h", atomically: true, encoding: .utf8)

        let json = """
        {"searchRoots": [""], "rootTypes": ["after_it", "inside_spaceless"],
         "skipTypes": [], "manualTypes": []}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(PJSIPSwiftGenConfig.self, from: json)
        let found = discoverTypes(config: config, pjprojectRoot: root)

        // The type after the spaceless block must be UNGUARDED. Before the fix the stack
        // was popped once too often and this inherited a stale condition.
        XCTAssertNil(found.structs.first(where: { $0.name == "after_it" })?.ppCondition)
        XCTAssertEqual(found.structs.first(where: { $0.name == "inside_spaceless" })?.ppCondition,
                       "(SOMETHING)")
    }

    /// The refusal tally must belong to the CALL, not the process. It decides whether the
    /// run fails the build, so a static counter would carry one caller's refusals into the
    /// next call in the same process — which is every test in this suite, and any embedder
    /// of the library.
    func testGuardReportIsPerCallAndDoesNotAccumulate() throws {
        let header = """
        typedef struct tally_probe {
            int always;
        #if UNKNOWABLE_FEATURE
            int guarded;
        #endif
        } tally_probe;
        """
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try header.write(toFile: "\(dir)/t.h", atomically: true, encoding: .utf8)

        // macros: nil, so the guard is unresolvable and gets recorded.
        let first = generateStructConformance(
            structName: "tally_probe", headerPath: "\(dir)/t.h", outputDir: dir, macros: nil
        )
        let second = generateStructConformance(
            structName: "tally_probe", headerPath: "\(dir)/t.h", outputDir: dir, macros: nil
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1, "a second call must not inherit the first call's tally")
        XCTAssertEqual((first + second).count, 2, "callers aggregate explicitly")
        XCTAssertTrue(first.unresolved[0].contains("tally_probe.guarded"))
    }

    /// A run with nothing to refuse reports nothing — the build must not fail for a package
    /// that simply has no guarded members.
    func testGuardReportIsEmptyWhenNothingIsRefused() throws {
        let header = "typedef struct plain_thing { int a; } plain_thing;"
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try header.write(toFile: "\(dir)/p.h", atomically: true, encoding: .utf8)

        let report = generateStructConformance(
            structName: "plain_thing", headerPath: "\(dir)/p.h", outputDir: dir, macros: nil
        )
        XCTAssertTrue(report.isEmpty)
    }

    /// The undefined-macro refusal has to cover NEGATED conditions, not just a bare
    /// `SOME_MACRO`. An `#else` arm is recorded as `!(X)`, and there an undefined X reads as
    /// *true* — so the failure mode flips from omitting a member to EMITTING one the real
    /// preprocessor removed, which is a consumer compile error. `pj_math_stat` has exactly
    /// this shape: `fmean_` under `#if PJ_HAS_FLOATING_POINT`, `mean_res_` under its `#else`.
    func testNegatedUndefinedMacroIsAlsoRefused() throws {
        let root = try makeHeaderRoot(defining: ["REAL_FEATURE": "1"])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolver = MacroResolver(headersRoot: root)
        try XCTSkipUnless(resolver.isResolved, "no usable clang for the preprocessor probe")

        // Defined: both directions answerable.
        XCTAssertEqual(resolver.isEnabled("REAL_FEATURE"), true)
        XCTAssertEqual(resolver.isEnabled("!(REAL_FEATURE)"), false)

        // Undefined: refused in BOTH directions. Before the fix, `!(X)` returned true here.
        XCTAssertNil(resolver.isEnabled("NOBODY_DEFINES_THIS"))
        XCTAssertNil(resolver.isEnabled("!(NOBODY_DEFINES_THIS)"))
        XCTAssertNil(resolver.isEnabled("!NOBODY_DEFINES_THIS"))

        // A compound condition is refused if ANY evaluated macro is undefined.
        XCTAssertNil(resolver.isEnabled("REAL_FEATURE && NOBODY_DEFINES_THIS"))
        XCTAssertEqual(resolver.isEnabled("REAL_FEATURE && REAL_FEATURE"), true)

        // `defined(...)` is the author asking the question explicitly — still answered.
        XCTAssertEqual(resolver.isEnabled("defined(NOBODY_DEFINES_THIS)"), false)
        XCTAssertEqual(resolver.isEnabled("!defined(NOBODY_DEFINES_THIS)"), true)
        XCTAssertEqual(resolver.isEnabled("defined(REAL_FEATURE) && REAL_FEATURE"), true)
    }

    /// The identifier scan underneath that refusal.
    func testEvaluatedIdentifiersExcludesDefinedArgumentsAndLiterals() {
        func ids(_ c: String) -> [String] { MacroResolver.evaluatedIdentifiers(in: c) }
        XCTAssertEqual(ids("FOO"), ["FOO"])
        XCTAssertEqual(ids("!(FOO)"), ["FOO"])
        XCTAssertEqual(ids("FOO == 0"), ["FOO"])
        XCTAssertEqual(ids("FOO < 2 && BAR"), ["FOO", "BAR"])
        XCTAssertEqual(ids("defined(FOO)"), [])
        XCTAssertEqual(ids("!defined(FOO)"), [])
        XCTAssertEqual(ids("defined(FOO) && BAR"), ["BAR"])
        XCTAssertEqual(ids("1"), [])
        XCTAssertEqual(ids("0x10 && FOO"), ["FOO"])
    }

    /// Some PJSIP config macros are decided by the compilation target, not by config_site.h,
    /// so the probe has to compile as the slice or its macro universe differs from the real
    /// build's. Measured on 2.17: PJ_IPHONE_OS_HAS_MULTITASKING_SUPPORT, PJ_GETADDRINFO_USE_CFHOST
    /// and PJ_ACTIVESOCK_TCP_IPHONE_OS_BG exist under an iOS target and are absent on the host.
    func testTargetTripleIsInferredFromTheSliceDirectory() {
        func triple(_ p: String) -> String? { MacroResolver.targetTriple(forHeadersUnder: p) }

        XCTAssertEqual(triple("/x/PJSIP.xcframework/ios-arm64/Headers"), "arm64-apple-ios")
        XCTAssertEqual(triple("/x/PJSIP.xcframework/ios-arm64-simulator/Headers"),
                       "arm64-apple-ios-simulator")
        XCTAssertEqual(triple("/x/PJSIP.xcframework/macos-arm64/Headers"), "arm64-apple-macos")
        // Apple writes multi-arch slices with underscores; arm64 wins when present.
        XCTAssertEqual(triple("/x/PJSIP.xcframework/ios-arm64_x86_64-simulator/Headers"),
                       "arm64-apple-ios-simulator")
        XCTAssertEqual(triple("/x/PJSIP.xcframework/macos-x86_64/Headers"), "x86_64-apple-macos")
        XCTAssertEqual(triple("/x/PJSIP.xcframework/ios-arm64-maccatalyst/Headers"),
                       "arm64-apple-ios-macabi")
        // Arch names contain underscores of their own; splitting on "_" mangled them.
        XCTAssertEqual(MacroResolver.preferredArch(in: "x86_64"), "x86_64")
        XCTAssertEqual(MacroResolver.preferredArch(in: "arm64_x86_64"), "arm64")
        XCTAssertEqual(MacroResolver.preferredArch(in: "arm64_32"), "arm64_32")
        XCTAssertEqual(MacroResolver.preferredArch(in: "arm64e"), "arm64e")

        // A raw pjproject checkout is not a slice: no triple, and the probe falls back to the
        // host with the undefined-macro refusal as the backstop.
        XCTAssertNil(triple("/Users/me/pjproject/pjlib/include"))
        XCTAssertNil(triple("/tmp/some-headers"))
    }

    /// The end-to-end consequence: a target-gated macro must resolve the way the real build
    /// sees it, not the way the host does.
    func testTargetGatedMacroResolvesAsTheSliceNotTheHost() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }
        // Lay the fake headers out under a slice-shaped path so the triple is inferred.
        let root = "\(base)/PJSIP.xcframework/ios-arm64/Headers"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        for dir in ["pj", "pjlib-util", "pjnath", "pjmedia",
                    "pjmedia-audiodev", "pjmedia-videodev", "pjmedia-codec", "pjsip"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(dir)",
                                                    withIntermediateDirectories: true)
        }
        // Mirrors how pjproject gates iOS-only config: on TargetConditionals, not config_site.
        try """
        #include <TargetConditionals.h>
        #if TARGET_OS_IPHONE
        #  define ONLY_ON_IOS 1
        #endif
        """.write(toFile: "\(root)/pj/config.h", atomically: true, encoding: .utf8)
        for path in ["pjlib-util/config.h", "pjnath/config.h", "pjmedia/config.h",
                     "pjmedia-audiodev/config.h", "pjmedia-videodev/config.h",
                     "pjmedia-codec/config.h", "pjsip/sip_config.h"] {
            try "".write(toFile: "\(root)/\(path)", atomically: true, encoding: .utf8)
        }

        let resolver = MacroResolver(headersRoot: root)
        try XCTSkipUnless(resolver.isResolved, "no usable clang for the preprocessor probe")
        XCTAssertEqual(resolver.isEnabled("ONLY_ON_IOS"), true,
                       "an iOS-gated macro must read as the slice sees it, not the host")
    }

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "pjsipgen-test-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
