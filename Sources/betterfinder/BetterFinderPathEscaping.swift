import Foundation

public extension String {
    func betterFinderAppNameEscaped(_ count: Int = 1) -> String {
        let escapeChar = String(repeating: "\\", count: count)
        return replacingOccurrences(of: " ", with: escapeChar + " ")
    }

    func betterFinderShellEscaped(_ count: Int = 1) -> String {
        let escapeChar = String(repeating: "\\", count: count)
        let specialCharacters: Set<Character> = [" ", "(", ")", "&", "|", ";", "\"", "'", "<", ">", "`"]
        var result = ""
        for character in self {
            if specialCharacters.contains(character) {
                result += escapeChar
            }
            result.append(character)
        }
        return result
    }
}

public extension URL {
    func betterFinderDirectoryURLForTerminal() -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return self
        }
        return isDirectory.boolValue ? self : deletingLastPathComponent()
    }
}
