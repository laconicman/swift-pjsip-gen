import Foundation

// MARK: - Struct conformance generation

public func generateStructConformance(
    structName: String,
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
    guard let fields = parseStruct(named: structName, in: source) else {
        fputs("  Error: struct '\(structName)' not found in '\(headerPath)'\n", stderr)
        return
    }

    let pairs = matchPairs(from: fields)
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

    // Guarded members are resolved against the binary's own config_site.h rather
    // than emitted as Swift `#if`, which cannot see C macros and silently reads
    // them as false. See MacroResolver.
    var omittedFields = Set<String>()
    for p in pairs {
        switch resolveGuard(p.ppCondition, with: macros) {
        case .omit:
            omittedFields.insert(p.arrayField)
            continue
        case .omitUnresolved(let macro):
            reportUnresolvedGuard(macro: macro, member: p.arrayField, owner: structName)
            omittedFields.insert(p.arrayField)
            continue
        case .emit:
            break
        }
        out += "        let \(p.arrayField)Slice = tupleToArray(\n"
        out += "            \(p.arrayField),\n"
        out += "            count: Int(\(p.countField)),\n"
        out += "            as: \(p.elementType).self\n"
        out += "        )\n"
    }

    out += "        var parts: [String] = []\n"

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

        guard emitsCode, !omittedFields.contains(f.name) else { continue }

        switch resolveGuard(f.ppCondition, with: macros) {
        case .emit:
            out += line
        case .omit:
            continue
        case .omitUnresolved(let macro):
            reportUnresolvedGuard(macro: macro, member: f.name, owner: structName)
        }
    }

    out += "        return \"\(structName)(\""
    out += " + parts.joined(separator: \", \")"
    out += " + \")\"\n"
    out += "    }\n"
    out += "}\n"

    // A type that does not exist in this binary still gets its file written: the
    // build-tool plugin declares outputs up front, so a missing file breaks that
    // contract. The file explains itself and declares nothing.
    switch resolveGuard(ppCondition, with: macros) {
    case .emit:
        break
    case .omit:
        out = absentTypeStub(structName, guardedBy: ppCondition, resolved: true)
    case .omitUnresolved(let macro):
        reportUnresolvedGuard(macro: macro, member: nil, owner: structName)
        out = absentTypeStub(structName, guardedBy: macro, resolved: false)
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
