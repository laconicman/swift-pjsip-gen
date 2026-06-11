import Foundation

func writeGenerated(_ content: String, to path: String) {
    do {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        fputs("  Written: \(path)\n", stderr)
    } catch {
        fputs("  Error writing '\(path)': \(error)\n", stderr)
    }
}
