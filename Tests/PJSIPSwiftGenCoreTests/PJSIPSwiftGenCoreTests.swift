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

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "pjsipgen-test-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }
}
