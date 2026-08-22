import Foundation

// MARK: - Enum conformance generation

public func generateEnumConformances(
    enumName: String,
    headerPath: String,
    outputDir: String,
    imports: [String] = [],
    ppCondition: String? = nil,
    macros: MacroResolver? = nil
) {
    guard let rawSource = try? String(
        contentsOfFile: headerPath, encoding: .utf8
    ) else {
        fputs("  Error: cannot read '\(headerPath)'\n", stderr)
        return
    }

    let source = stripBlockComments(rawSource)
    guard let cases = parseEnum(named: enumName, in: source) else {
        fputs("  Error: enum '\(enumName)' not found in '\(headerPath)'\n", stderr)
        return
    }

    let filename = URL(fileURLWithPath: headerPath).lastPathComponent

    // Resolve the TYPE's own guard first — see StructGenerator for why.
    let debugPathEarly = "\(outputDir)/\(enumName)+CustomDebugStringConvertible.swift"
    let stringPathEarly = "\(outputDir)/\(enumName)+CustomStringConvertible.swift"
    switch resolveGuard(ppCondition, with: macros) {
    case .emit:
        break
    case .omit:
        let stub = absentTypeStub(enumName, guardedBy: ppCondition, resolved: true)
        writeGenerated(stub, to: debugPathEarly)
        writeGeneratedUnlessOverridden(stub, to: stringPathEarly)
        return
    case .omitUnresolved(let condition):
        reportUnresolvedGuard(condition: condition, member: nil, owner: enumName)
        let stub = absentTypeStub(enumName, guardedBy: condition, resolved: false)
        writeGenerated(stub, to: debugPathEarly)
        writeGeneratedUnlessOverridden(stub, to: stringPathEarly)
        return
    }
    let importBlock = imports.isEmpty
        ? ""
        : imports.map { "import \($0)" }.joined(separator: "\n") + "\n\n"

    // ── CustomDebugStringConvertible ──

    let debugBody: String = {
        var out = """
        \(autoGenMarker) from \(filename). DO NOT EDIT MANUALLY.

        \(importBlock)extension \(enumName): @retroactive CustomDebugStringConvertible {
            public var debugDescription: String {
                switch self {

        """
        // A case guarded by a C macro is emitted only when that macro is really
        // on in the binary these headers describe. It must NOT become a Swift
        // `#if`: Swift cannot see C macros and reads the unknown identifier as
        // false, which silently deleted the case. See MacroResolver.
        for c in cases {
            switch resolveGuard(c.ppCondition, with: macros) {
            case .emit:
                out += "        case \(c.name): \"\(c.name)\"\n"
            case .omit:
                continue
            case .omitUnresolved(let condition):
                reportUnresolvedGuard(condition: condition, member: c.name, owner: enumName)
            }
        }
        out += """
                default: "\\(rawValue)"
                }
            }
        }

        """
        return out
    }()

    // ── CustomStringConvertible ──

    let stringBody = """
    \(autoGenMarker) from \(filename).
    // Delegates to debugDescription. Replace this file with your own implementation —
    // the generator will not overwrite a file lacking the "\(autoGenMarker)" marker.

    \(importBlock)extension \(enumName): @retroactive CustomStringConvertible {
        public var description: String {
            debugDescription
        }
    }

    """

    // ── Conditional compilation wrapping ──

    let wrappedDebug = debugBody
    let wrappedString = stringBody

    // ── Write ──

    let debugPath = "\(outputDir)/\(enumName)+CustomDebugStringConvertible.swift"
    let stringPath = "\(outputDir)/\(enumName)+CustomStringConvertible.swift"

    writeGenerated(wrappedDebug, to: debugPath)

    writeGeneratedUnlessOverridden(wrappedString, to: stringPath)
}
