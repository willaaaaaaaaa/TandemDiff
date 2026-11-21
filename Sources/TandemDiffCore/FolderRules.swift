import Foundation

public struct NameRules: Codable, Equatable, Sendable {
    public var includeFiles = ""
    public var excludeFiles = ""
    public var includeDirectories = ""
    public var excludeDirectories = ""
    public init() {}
}

public extension NameRules {
    /// Semicolons separate globs, a leading minus excludes, and a trailing slash selects folders.
    var quickExpression: String {
        var tokens: [String] = []
        for (list, excluded, directory) in [(includeFiles, false, false), (excludeFiles, true, false), (includeDirectories, false, true), (excludeDirectories, true, true)] {
            for line in list.split(whereSeparator: \.isNewline) {
                var pattern = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                if !directory && pattern.hasSuffix("/") { pattern = String(pattern.dropLast()) + "\\/" }
                if directory && !pattern.hasSuffix("/") { pattern += "/" }
                if excluded { pattern = "-" + pattern }
                else if pattern.hasPrefix("-") || pattern.hasPrefix("+") { pattern = "+" + pattern }
                tokens.append(pattern)
            }
        }
        return tokens.joined(separator: ";")
    }

    init(quickExpression: String) {
        self.init()
        var token = ""
        var escaped = false
        var directory = false
        func appendToken() {
            let excluded = token.hasPrefix("-")
            if excluded || token.hasPrefix("+") { token.removeFirst() }
            if !token.isEmpty {
                let key: WritableKeyPath<Self, String> = directory
                    ? (excluded ? \.excludeDirectories : \.includeDirectories)
                    : (excluded ? \.excludeFiles : \.includeFiles)
                if !self[keyPath: key].isEmpty { self[keyPath: key] += "\n" }
                self[keyPath: key] += token
            }
            token = ""
            directory = false
        }
        for character in quickExpression {
            if !escaped && (character == ";" || character.isNewline) { appendToken(); continue }
            if !escaped && character == "\\" { escaped = true; continue }
            directory = !escaped && character == "/"
            escaped = false
            token.append(character)
        }
        if escaped { token.append("\\"); directory = false }
        appendToken()
    }
}

struct FolderRules {
    private struct Pattern {
        let regex: NSRegularExpression
        let hasSlash: Bool
        let directoriesOnly: Bool

        init(_ input: Substring) {
            var text = String(input)
            directoriesOnly = text.hasSuffix("/")
            while text.hasSuffix("/") { text.removeLast() }
            hasSlash = text.contains("/")
            let scalars = Array(text.unicodeScalars)
            var regexText = "\\A"
            var i = 0
            while i < scalars.count {
                switch scalars[i] {
                case "*":
                    if i + 1 < scalars.count, scalars[i + 1] == "*" {
                        let atStart = i == 0 || scalars[i - 1] == "/"
                        i += 1
                        if atStart, i + 1 < scalars.count, scalars[i + 1] == "/" {
                            regexText += "(?:[^/]+/)*"
                            i += 1
                        } else { regexText += "[\\s\\S]*" }
                    } else { regexText += "[^/]*" }
                case "?": regexText += "[^/]"
                default: regexText += NSRegularExpression.escapedPattern(for: String(scalars[i]))
                }
                i += 1
            }
            // All user literals are escaped; only these fixed wildcard fragments add syntax.
            regex = try! NSRegularExpression(pattern: regexText + "\\z")
        }

        func matches(_ path: String, name: String, directory: Bool) -> Bool {
            if directoriesOnly && !directory { return false }
            let input = hasSlash ? path : name
            let range = NSRange(input.startIndex..., in: input)
            return regex.firstMatch(in: input, range: range) != nil
        }
    }

    private let includeFiles: [Pattern]
    private let excludeFiles: [Pattern]
    private let includeDirectories: [Pattern]
    private let excludeDirectories: [Pattern]
    var admitsRoot: Bool { includeDirectories.isEmpty }

    init(_ rules: NameRules) {
        func compile(_ text: String) -> [Pattern] {
            text.split(whereSeparator: \.isNewline).map(Pattern.init)
        }
        includeFiles = compile(rules.includeFiles)
        excludeFiles = compile(rules.excludeFiles)
        includeDirectories = compile(rules.includeDirectories)
        excludeDirectories = compile(rules.excludeDirectories)
    }

    func excludesDirectory(_ path: String, name: String) -> Bool {
        excludeDirectories.contains { $0.matches(path, name: name, directory: true) }
    }

    func admitsDirectory(_ path: String, name: String) -> Bool {
        includeDirectories.contains { $0.matches(path, name: name, directory: true) }
    }

    func admitsFile(_ path: String, name: String) -> Bool {
        !excludeFiles.contains { $0.matches(path, name: name, directory: false) } &&
            (includeFiles.isEmpty || includeFiles.contains { $0.matches(path, name: name, directory: false) })
    }
}

public extension NameRules {
    func admitsTextPath(_ path: String) -> Bool {
        let rules = FolderRules(self)
        let components = path.split(separator: "/")
        guard let file = components.last else { return false }
        var admitted = rules.admitsRoot
        var ancestors: [Substring] = []
        for component in components.dropLast() {
            ancestors.append(component)
            let prefix = ancestors.joined(separator: "/")
            let name = String(component)
            if rules.excludesDirectory(prefix, name: name) { return false }
            admitted = admitted || rules.admitsDirectory(prefix, name: name)
        }
        return admitted && rules.admitsFile(path, name: String(file))
    }
}
