import Foundation

// MARK: - Struct conformance generation

public func generateStructConformance(
    structName: String,
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
    guard let fields = parseStruct(named: structName, in: source) else {
        fputs("  Error: struct '\(structName)' not found in '\(headerPath)'\n", stderr)
        return
    }

    let pairs = matchPairs(from: fields)
    let autoGenMarker = "// Auto-generated"
    let filename = URL(fileURLWithPath: headerPath).lastPathComponent

    var out = "\(autoGenMarker) from \(filename). DO NOT EDIT MANUALLY.\n"
    if !pairs.isEmpty {
        let pairDesc = pairs
            .map { "\($0.countField)/\($0.arrayField)" }
            .joined(separator: ", ")
        out += "// count+array pairs: \(pairDesc)\n"
        out += "// Requires tupleToArray(_:count:as:) in the consuming module.\n"
    }
    out += "\n"
    for module in imports {
        out += "import \(module)\n"
    }
    if !imports.isEmpty {
        out += "\n"
    }
    out += "extension \(structName): @retroactive CustomStringConvertible {\n"
    out += "    public var description: String {\n"

    for p in pairs {
        if let cond = p.ppCondition {
            out += "        #if \(cond)\n"
        }
        out += "        let \(p.arrayField)Slice = tupleToArray(\n"
        out += "            \(p.arrayField),\n"
        out += "            count: Int(\(p.countField)),\n"
        out += "            as: \(p.elementType).self\n"
        out += "        )\n"
        if p.ppCondition != nil {
            out += "        #endif\n"
        }
    }

    out += "        var parts: [String] = []\n"

    var currentCondition: String?

    for f in fields {
        let emitsCode: Bool
        var line = ""

        if let pair = pairs.first(where: { $0.arrayField == f.name }) {
            line = "        parts.append(\""
            line += "\(f.name): \\(String(describing: \(pair.arrayField)Slice))\")\n"
            emitsCode = true
        } else if pairs.contains(where: { $0.countField == f.name }) {
            emitsCode = false
        } else if f.arraySize != nil {
            emitsCode = false
        } else {
            line = "        parts.append(\""
            line += "\(f.name): \\(String(describing: \(f.name)))\")\n"
            emitsCode = true
        }

        if emitsCode {
            if f.ppCondition != currentCondition {
                if currentCondition != nil {
                    out += "        #endif\n"
                }
                if let cond = f.ppCondition {
                    out += "        #if \(cond)\n"
                }
                currentCondition = f.ppCondition
            }
            out += line
        }
    }

    if currentCondition != nil {
        out += "        #endif\n"
    }

    out += "        return \"\(structName)(\""
    out += " + parts.joined(separator: \", \")"
    out += " + \")\"\n"
    out += "    }\n"
    out += "}\n"

    if let cond = ppCondition {
        out = "#if \(cond)\n" + out + "#endif\n"
    }

    // ── Write ──

    let outputPath = "\(outputDir)/\(structName)+CustomStringConvertible.swift"

    if FileManager.default.fileExists(atPath: outputPath),
       let existing = try? String(
           contentsOfFile: outputPath, encoding: .utf8),
       !existing.hasPrefix(autoGenMarker) {
        fputs("  Skipped (overridden): \(outputPath)\n", stderr)
    } else {
        writeGenerated(out, to: outputPath)
    }
}
