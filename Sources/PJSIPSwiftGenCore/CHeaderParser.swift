import Foundation

// MARK: - Comment stripping

func stripBlockComments(_ s: String) -> String {
    guard let re = try? NSRegularExpression(
        pattern: #"/\*.*?\*/"#,
        options: .dotMatchesLineSeparators
    ) else { return s }
    return re.stringByReplacingMatches(
        in: s,
        range: NSRange(s.startIndex..., in: s),
        withTemplate: " "
    )
}

func stripLineComment(_ line: String) -> String {
    guard let r = line.range(of: "//") else { return line }
    return String(line[..<r.lowerBound])
}

// MARK: - Preprocessor

func extractMacroName(from directive: String) -> String? {
    let pattern = #"[A-Z][A-Z0-9_]{2,}"#
    if let range = directive.range(of: pattern, options: .regularExpression) {
        return String(directive[range])
    }
    return nil
}

// MARK: - Struct field parsing

struct CField {
    let type: String
    let name: String
    let arraySize: String?
    let ppCondition: String?
}

func parseStruct(named name: String, in source: String) -> [CField]? {
    let lines = source.components(separatedBy: .newlines)
    var inStruct = false, depth = 0
    var fields = [CField]()

    let startPattern = #"(?:typedef\s+)?struct\s+"#
        + NSRegularExpression.escapedPattern(for: name) + #"\b"#

    var ppDepth = 0
    var ppCondition: String?

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if inStruct && depth >= 1 {
            if trimmed.hasPrefix("#if") {
                ppDepth += 1
                if ppDepth == 1 {
                    ppCondition = extractMacroName(from: trimmed)
                }
                continue
            }
            if trimmed.hasPrefix("#endif") {
                ppDepth -= 1
                if ppDepth == 0 { ppCondition = nil }
                continue
            }
            if trimmed.hasPrefix("#else")
                || trimmed.hasPrefix("#elif") { continue }
        }

        let code = stripLineComment(line)
            .trimmingCharacters(in: .whitespaces)

        if !inStruct {
            if code.range(of: startPattern,
                          options: .regularExpression) != nil {
                inStruct = true
            }
        }
        guard inStruct else { continue }

        let activeCondition = ppDepth > 0 ? ppCondition : nil

        let prevDepth = depth
        depth += code.filter { $0 == "{" }.count
        depth -= code.filter { $0 == "}" }.count

        guard prevDepth == 1
                || (prevDepth == 0 && depth > 0) else {
            if depth == 0 && !fields.isEmpty { break }
            continue
        }
        guard depth == 1 else { continue }

        var fieldLine = code
        if let semi = fieldLine.lastIndex(of: ";") {
            fieldLine = String(fieldLine[..<semi])
                .trimmingCharacters(in: .whitespaces)
        } else { continue }

        // Function pointer: type (*name)(params)
        if let openParen = fieldLine.firstIndex(of: "("),
           fieldLine.index(after: openParen) < fieldLine.endIndex,
           fieldLine[fieldLine.index(after: openParen)] == "*" {
            let afterStar = fieldLine.index(openParen, offsetBy: 2)
            if let closeParen = fieldLine[afterStar...]
                .firstIndex(of: ")") {
                let fnName = String(fieldLine[afterStar..<closeParen])
                    .trimmingCharacters(in: .whitespaces)
                if !fnName.isEmpty {
                    fields.append(CField(
                        type: "void",
                        name: fnName,
                        arraySize: nil,
                        ppCondition: activeCondition
                    ))
                }
            }
            continue
        }

        // Array field: type name[SIZE]
        if fieldLine.hasSuffix("]"),
           let bracketOpen = fieldLine.lastIndex(of: "[") {
            let sizeStr = String(
                fieldLine[fieldLine.index(after: bracketOpen)...]
                    .dropLast(1)
            ).trimmingCharacters(in: .whitespaces)
            let beforeBracket = String(fieldLine[..<bracketOpen])
                .trimmingCharacters(in: .whitespaces)
            let tokens = beforeBracket
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard var fieldName = tokens.last,
                  tokens.count >= 2 else { continue }
            while fieldName.hasPrefix("*") {
                fieldName = String(fieldName.dropFirst())
            }
            let typeName = tokens.dropLast().joined(separator: " ")
            fields.append(CField(
                type: typeName,
                name: fieldName,
                arraySize: sizeStr,
                ppCondition: activeCondition
            ))
        } else {
            // Plain scalar field
            let tokens = fieldLine
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard var fieldName = tokens.last,
                  tokens.count >= 2 else { continue }
            while fieldName.hasPrefix("*") {
                fieldName = String(fieldName.dropFirst())
            }
            let typeName = tokens.dropLast().joined(separator: " ")
            fields.append(CField(
                type: typeName,
                name: fieldName,
                arraySize: nil,
                ppCondition: activeCondition
            ))
        }
    }
    return fields.isEmpty ? nil : fields
}

// MARK: - Enum parsing

struct CCase {
    let name: String
    let ppCondition: String?
}

func isIdentifier(_ s: String) -> Bool {
    guard let first = s.first else { return false }
    return (first.isLetter || first == "_")
        && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

func parseEnum(named enumName: String, in source: String) -> [CCase]? {
    let lines = source.components(separatedBy: .newlines)
    var inEnum = false, depth = 0
    var cases = [CCase]()

    var ppDepth = 0
    var ppCondition: String?

    for line in lines {
        let raw = line.trimmingCharacters(in: .whitespaces)

        if inEnum && depth >= 1 {
            if raw.hasPrefix("#if") {
                ppDepth += 1
                if ppDepth == 1 {
                    ppCondition = extractMacroName(from: raw)
                }
                continue
            }
            if raw.hasPrefix("#endif") {
                ppDepth -= 1
                if ppDepth == 0 { ppCondition = nil }
                continue
            }
            if raw.hasPrefix("#else") || raw.hasPrefix("#elif") {
                continue
            }
        }

        let trimmed = stripLineComment(line)
            .trimmingCharacters(in: .whitespaces)

        if !inEnum {
            let pattern = #"(?:typedef\s+)?enum\s+"#
                + NSRegularExpression.escapedPattern(for: enumName)
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                inEnum = true
            }
        }
        guard inEnum else { continue }

        let activeCondition = ppDepth > 0 ? ppCondition : nil

        let prevDepth = depth
        depth += trimmed.filter { $0 == "{" }.count
        depth -= trimmed.filter { $0 == "}" }.count

        guard prevDepth > 0 || depth > 0 else {
            if depth == 0 && !cases.isEmpty { break }
            continue
        }

        var content = trimmed
        if prevDepth == 0, let idx = content.lastIndex(of: "{") {
            content = String(content[content.index(after: idx)...])
        }
        if depth == 0, let idx = content.firstIndex(of: "}") {
            content = String(content[..<idx])
        }

        for token in content.components(separatedBy: ",") {
            let t = token.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: "=").first!
                .trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, isIdentifier(t), t != enumName else { continue }
            cases.append(CCase(name: t, ppCondition: activeCondition))
        }
        if depth == 0 { break }
    }
    return cases.isEmpty ? nil : cases
}

// MARK: - Count+array pair discovery

struct CountArrayPair {
    let countField: String
    let arrayField: String
    let elementType: String
    let ppCondition: String?
}

func matchPairs(from fields: [CField]) -> [CountArrayPair] {
    let countSuffixes = ["_count", "_cnt", "_num"]
    let countFields = fields.filter { f in
        f.arraySize == nil
            && (f.type.contains("unsigned") || f.type == "int"
                || f.type == "pj_size_t"
                || f.type == "pj_uint32_t")
            && countSuffixes.contains(where: { f.name.hasSuffix($0) })
    }
    let arrayFields = fields.filter { $0.arraySize != nil }

    var pairs = [CountArrayPair]()
    for cf in countFields {
        let base: String = {
            for s in countSuffixes where cf.name.hasSuffix(s) {
                return String(cf.name.dropLast(s.count))
            }
            return cf.name
        }()

        if let af = arrayFields.first(where: {
            $0.name == base || $0.name == base + "s"
                || $0.name.hasPrefix(base + "_")
        }) {
            pairs.append(CountArrayPair(
                countField: cf.name,
                arrayField: af.name,
                elementType: af.type,
                ppCondition: cf.ppCondition ?? af.ppCondition
            ))
        }
    }
    return pairs
}
