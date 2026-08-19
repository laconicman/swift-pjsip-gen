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
            case .omitUnresolved(let macro):
                reportUnresolvedGuard(macro: macro, member: c.name, owner: enumName)
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

    // Same rule for a type that is itself guarded — but the file must still be
    // written, because the build-tool plugin declares its outputs up front and a
    // missing file breaks that contract. So a type that does not exist in this
    // binary yields a file that explains itself and declares nothing.
    let wrappedDebug: String
    let wrappedString: String
    switch resolveGuard(ppCondition, with: macros) {
    case .emit:
        wrappedDebug = debugBody
        wrappedString = stringBody
    case .omit:
        wrappedDebug = absentTypeStub(enumName, guardedBy: ppCondition, resolved: true)
        wrappedString = wrappedDebug
    case .omitUnresolved(let macro):
        reportUnresolvedGuard(macro: macro, member: nil, owner: enumName)
        wrappedDebug = absentTypeStub(enumName, guardedBy: macro, resolved: false)
        wrappedString = wrappedDebug
    }

    // ── Write ──

    let debugPath = "\(outputDir)/\(enumName)+CustomDebugStringConvertible.swift"
    let stringPath = "\(outputDir)/\(enumName)+CustomStringConvertible.swift"

    writeGenerated(wrappedDebug, to: debugPath)

    if FileManager.default.fileExists(atPath: stringPath),
       let existing = try? String(
           contentsOfFile: stringPath, encoding: .utf8),
       !existing.hasPrefix(autoGenMarker) {
        fputs("  Skipped (overridden): \(stringPath)\n", stderr)
    } else {
        writeGenerated(wrappedString, to: stringPath)
    }
}
