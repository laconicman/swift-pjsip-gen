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
}
