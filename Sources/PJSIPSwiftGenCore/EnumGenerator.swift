import Foundation

// MARK: - Enum conformance generation

public func generateEnumConformances(
    enumName: String,
    headerPath: String,
    outputDir: String,
    imports: [String] = [],
    ppCondition: String? = nil
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

    let autoGenMarker = "// Auto-generated"
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
        var currentCondition: String?
        for c in cases {
            if c.ppCondition != currentCondition {
                if currentCondition != nil {
                    out += "        #endif\n"
                }
                if let cond = c.ppCondition {
                    out += "        #if \(cond)\n"
                }
                currentCondition = c.ppCondition
            }
            out += "        case \(c.name): \"\(c.name)\"\n"
        }
        if currentCondition != nil {
            out += "        #endif\n"
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

    let wrappedDebug: String
    let wrappedString: String
    if let cond = ppCondition {
        wrappedDebug = "#if \(cond)\n" + debugBody + "#endif\n"
        wrappedString = "#if \(cond)\n" + stringBody + "#endif\n"
    } else {
        wrappedDebug = debugBody
        wrappedString = stringBody
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
