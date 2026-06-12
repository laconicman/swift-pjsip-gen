import Foundation

// MARK: - Type discovery

public enum TypeKind: String {
    case enumType
    case structType
}

public struct DiscoveredType {
    public let name: String
    public let kind: TypeKind
    public let headerPath: String
    public let ppCondition: String?

    public init(name: String, kind: TypeKind, headerPath: String, ppCondition: String?) {
        self.name = name
        self.kind = kind
        self.headerPath = headerPath
        self.ppCondition = ppCondition
    }
}

public struct DiscoveryResult {
    public let enums: [DiscoveredType]
    public let structs: [DiscoveredType]

    public init(enums: [DiscoveredType], structs: [DiscoveredType]) {
        self.enums = enums
        self.structs = structs
    }
}

public func discoverTypes(
    config: PJSIPSwiftGenConfig,
    pjprojectRoot pjRoot: String
) -> DiscoveryResult {
    var typeMap: [String: (kind: TypeKind, headerPath: String, ppCondition: String?)] = [:]
    for searchRoot in config.searchRoots {
        let rootPath = URL(fileURLWithPath: pjRoot)
            .appendingPathComponent(searchRoot).path
        scanHeaders(in: rootPath, into: &typeMap)
    }

    let skipSet = Set(config.skipTypes)
    var discoveredEnums: [DiscoveredType] = []
    var discoveredStructs: [DiscoveredType] = []
    var visited = Set<String>()

    func discover(_ typeName: String) {
        guard let cleanName = cleanTypeName(typeName),
              !visited.contains(cleanName),
              !skipSet.contains(cleanName)
        else { return }
        visited.insert(cleanName)

        guard let entry = typeMap[cleanName] else { return }

        switch entry.kind {
        case .enumType:
            discoveredEnums.append(DiscoveredType(
                name: cleanName,
                kind: .enumType,
                headerPath: entry.headerPath,
                ppCondition: entry.ppCondition
            ))

        case .structType:
            guard let source = try? String(
                contentsOfFile: entry.headerPath, encoding: .utf8
            ) else { return }
            let cleaned = stripBlockComments(source)
            if let fields = parseStruct(named: cleanName, in: cleaned) {
                for field in fields {
                    discover(field.type)
                }
            }
            // Topological order (leaves first) after recursion
            discoveredStructs.append(DiscoveredType(
                name: cleanName,
                kind: .structType,
                headerPath: entry.headerPath,
                ppCondition: entry.ppCondition
            ))
        }
    }

    for rootType in config.rootTypes {
        discover(rootType)
    }

    return DiscoveryResult(
        enums: discoveredEnums,
        structs: discoveredStructs
    )
}

// MARK: - Header scanning

private func scanHeaders(
    in directory: String,
    into typeMap: inout [String: (kind: TypeKind, headerPath: String, ppCondition: String?)]
) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: directory) else { return }

    while let file = enumerator.nextObject() as? String {
        guard file.hasSuffix(".h") else { continue }
        let fullPath = URL(fileURLWithPath: directory)
            .appendingPathComponent(file).path
        guard let content = try? String(
            contentsOfFile: fullPath, encoding: .utf8
        ) else { continue }

        let lines = content.components(separatedBy: .newlines)
        var ppStack: [String?] = []

        for i in 0..<lines.count {
            let trimmed = lines[i]
                .trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#if ") || trimmed.hasPrefix("#ifdef") {
                ppStack.append(extractMacroName(from: trimmed))
                continue
            }
            if trimmed.hasPrefix("#ifndef") {
                let macro = extractMacroName(from: trimmed)
                let isIncludeGuard = macro != nil
                    && i + 1 < lines.count
                    && lines[i + 1].trimmingCharacters(in: .whitespaces)
                        .hasPrefix("#define")
                    && lines[i + 1].contains(macro!)
                ppStack.append(isIncludeGuard ? nil : macro)
                continue
            }
            if trimmed.hasPrefix("#endif") {
                if !ppStack.isEmpty { ppStack.removeLast() }
                continue
            }

            let condition = ppStack.compactMap { $0 }.last

            if trimmed.hasPrefix("typedef"),
               trimmed.contains("enum"),
               let name = extractTypedefName(
                   trimmed, keyword: "enum"
               ) {
                typeMap[name] = typeMap[name]
                    ?? (.enumType, fullPath, condition)
            }

            let structPattern = #"(?:typedef\s+)?struct\s+(\w+)"#
            if let range = trimmed.range(
                of: structPattern, options: .regularExpression
            ) {
                let matched = String(trimmed[range])
                if let name = matched.split(separator: " ").last
                    .map(String.init) {
                    let hasBody = trimmed.contains("{")
                        || (i + 1 < lines.count
                            && lines[i + 1]
                            .trimmingCharacters(in: .whitespaces)
                            .hasPrefix("{"))
                    if hasBody {
                        typeMap[name] = typeMap[name]
                            ?? (.structType, fullPath, condition)
                    }
                }
            }
        }
    }
}

private func extractTypedefName(
    _ line: String, keyword: String
) -> String? {
    let pattern = #"typedef\s+"# + keyword + #"\s+(\w+)"#
    guard let range = line.range(
        of: pattern, options: .regularExpression
    ) else { return nil }
    let matched = String(line[range])
    return matched.split(separator: " ").last.map(String.init)
}

// MARK: - Helpers

func cleanTypeName(_ rawType: String) -> String? {
    let name = rawType
        .replacingOccurrences(of: "const ", with: "")
        .replacingOccurrences(of: "unsigned ", with: "")
        .replacingOccurrences(of: "signed ", with: "")
        .replacingOccurrences(of: "struct ", with: "")
        .replacingOccurrences(of: "enum ", with: "")
        .replacingOccurrences(of: "*", with: "")
        .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

public func resolvePath(_ path: String, relativeTo base: String) -> String {
    if path.hasPrefix("/") { return path }
    return URL(fileURLWithPath: base)
        .appendingPathComponent(path)
        .standardized.path
}

// MARK: - Output filename planning

/// Compute the list of Swift files that `generateEnumConformances` /
/// `generateStructConformance` would produce for a given discovery result.
///
/// Used by build-tool plugins to declare outputs up-front before invoking the
/// generator executable.
public func expectedOutputFilenames(
    for result: DiscoveryResult,
    manualSet: Set<String>
) -> [String] {
    var names: [String] = []
    for e in result.enums where !manualSet.contains(e.name) {
        names.append("\(e.name)+CustomDebugStringConvertible.swift")
        names.append("\(e.name)+CustomStringConvertible.swift")
    }
    for s in result.structs where !manualSet.contains(s.name) {
        names.append("\(s.name)+CustomStringConvertible.swift")
    }
    return names
}
