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

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "pjsipgen-test-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
