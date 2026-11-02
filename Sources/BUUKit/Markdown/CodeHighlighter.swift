import Foundation

/// The kind of a highlighted code token.
public enum CodeTokenKind: Sendable, Equatable {
    case keyword
    case type
    case string
    case number
    case comment
    case function
    case punctuation
    case attribute
    case plain
}

/// A highlighted region of a code block.
public struct CodeToken: Sendable {
    public var range: Range<String.Index>
    public var kind: CodeTokenKind

    public init(range: Range<String.Index>, kind: CodeTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A deliberately small syntax highlighter: it tokenises the source so the UI
/// layer can colour the pieces. No regular expressions, no dependencies.
public enum CodeHighlighter {

    public static func tokenize(_ code: String, language: String?) -> [CodeToken] {
        let syntax = Syntax(language: language)
        var tokens: [CodeToken] = []
        let characters = Array(code)
        var index = 0
        var plainStart = 0

        func flushPlain(upTo end: Int) {
            if end > plainStart {
                let start = code.index(code.startIndex, offsetBy: plainStart)
                let stop = code.index(code.startIndex, offsetBy: end)
                tokens.append(CodeToken(range: start..<stop, kind: .plain))
            }
        }

        while index < characters.count {
            let character = characters[index]

            // Comments
            if syntax.lineCommentMarkers.contains(character),
               syntax.commentPrefix(for: character, characters: characters, index: index) != nil {
                flushPlain(upTo: index)
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                let start = code.index(code.startIndex, offsetBy: index)
                let stop = code.index(code.startIndex, offsetBy: end)
                tokens.append(CodeToken(range: start..<stop, kind: .comment))
                index = end
                plainStart = index
                continue
            }

            if syntax.hasBlockComments, character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                flushPlain(upTo: index)
                var end = index + 2
                while end + 1 < characters.count, !(characters[end] == "*" && characters[end + 1] == "/") { end += 1 }
                end = min(end + 2, characters.count)
                let start = code.index(code.startIndex, offsetBy: index)
                let stop = code.index(code.startIndex, offsetBy: end)
                tokens.append(CodeToken(range: start..<stop, kind: .comment))
                index = end
                plainStart = index
                continue
            }

            // Strings
            if syntax.stringDelimiters.contains(character) {
                flushPlain(upTo: index)
                var end = index + 1
                var escaped = false
                while end < characters.count {
                    let current = characters[end]
                    if escaped {
                        escaped = false
                    } else if current == "\\" {
                        escaped = true
                    } else if current == character {
                        end += 1
                        break
                    } else if current == "\n" {
                        break
                    }
                    end += 1
                }
                let start = code.index(code.startIndex, offsetBy: index)
                let stop = code.index(code.startIndex, offsetBy: end)
                tokens.append(CodeToken(range: start..<stop, kind: .string))
                index = end
                plainStart = index
                continue
            }

            // Numbers
            if character.isNumber {
                flushPlain(upTo: index)
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_" {
                    end += 1
                }
                let start = code.index(code.startIndex, offsetBy: index)
                let stop = code.index(code.startIndex, offsetBy: end)
                tokens.append(CodeToken(range: start..<stop, kind: .number))
                index = end
                plainStart = index
                continue
            }

            // Identifiers / keywords
            if character.isLetter || character == "_" || character == "@" || character == "#" && syntax.hashIsAttribute {
                if character == "@" || (character == "#" && syntax.hashIsAttribute) {
                    flushPlain(upTo: index)
                    var end = index + 1
                    while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                        end += 1
                    }
                    let start = code.index(code.startIndex, offsetBy: index)
                    let stop = code.index(code.startIndex, offsetBy: end)
                    tokens.append(CodeToken(range: start..<stop, kind: .attribute))
                    index = end
                    plainStart = index
                    continue
                }

                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
                let word = String(characters[index..<end])
                let kind: CodeTokenKind
                if syntax.keywords.contains(word) {
                    kind = .keyword
                } else if syntax.types.contains(word) {
                    kind = .type
                } else if syntax.constants.contains(word) {
                    kind = .number
                } else if looksLikeFunction(characters, index: index, end: end) {
                    kind = .function
                } else if word.first?.isUppercase == true {
                    kind = .type
                } else {
                    kind = .plain
                }
                if kind != .plain {
                    flushPlain(upTo: index)
                    let start = code.index(code.startIndex, offsetBy: index)
                    let stop = code.index(code.startIndex, offsetBy: end)
                    tokens.append(CodeToken(range: start..<stop, kind: kind))
                }
                index = end
                plainStart = index
                continue
            }

            // Punctuation
            if syntax.punctuation.contains(character) {
                flushPlain(upTo: index)
                let start = code.index(code.startIndex, offsetBy: index)
                let stop = code.index(code.startIndex, offsetBy: index + 1)
                tokens.append(CodeToken(range: start..<stop, kind: .punctuation))
                index += 1
                plainStart = index
                continue
            }

            index += 1
        }

        flushPlain(upTo: characters.count)
        return tokens
    }

    private static func looksLikeFunction(_ characters: [Character], index: Int, end: Int) -> Bool {
        var probe = end
        while probe < characters.count, characters[probe] == " " { probe += 1 }
        return probe < characters.count && characters[probe] == "("
    }

    // MARK: - Language definitions

    struct Syntax {
        var keywords: Set<String> = []
        var types: Set<String> = []
        var constants: Set<String> = []
        var lineCommentMarkers: Set<Character> = ["/"]
        var hasBlockComments = true
        var stringDelimiters: Set<Character> = ["\"", "'"]
        var punctuation: Set<Character> = ["{", "}", "(", ")", "[", "]", ".", ",", ":", ";", "=", "+", "-", "*", "/", "%", "<", ">", "!", "?", "&", "|", "^", "~"]
        var hashIsAttribute = false

        init(language: String?) {
            let name = (language ?? "").lowercased()
            switch name {
            case "swift":
                keywords = ["func", "let", "var", "if", "else", "guard", "return", "for", "while", "repeat", "switch", "case", "default", "break", "continue", "import", "class", "struct", "enum", "protocol", "extension", "init", "deinit", "subscript", "typealias", "inout", "where", "throws", "rethrows", "async", "await", "try", "catch", "do", "as", "is", "nil", "true", "false", "self", "super", "some", "any", "final", "lazy", "weak", "unowned", "mutating", "nonmutating", "override", "convenience", "required", "private", "public", "internal", "fileprivate", "open", "static", "get", "set", "willSet", "didSet", "defer", "in", "repeat", "precedencegroup", "operator"]
                types = ["Int", "String", "Double", "Float", "Bool", "Array", "Dictionary", "Set", "Optional", "Result", "Void", "Any", "Character", "Data", "URL", "Date", "Error", "Task", "Actor", "Sendable"]
            case "python", "py":
                keywords = ["def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue", "pass", "import", "from", "as", "with", "try", "except", "finally", "raise", "assert", "lambda", "yield", "global", "nonlocal", "del", "is", "not", "and", "or", "in", "None", "True", "False", "async", "await", "match", "case"]
                types = ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type"]
                constants = ["True", "False", "None"]
                lineCommentMarkers = ["#"]
                hasBlockComments = false
                stringDelimiters = ["\"", "'"]
            case "javascript", "js", "jsx", "typescript", "ts", "tsx":
                keywords = ["function", "const", "let", "var", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "class", "extends", "super", "new", "this", "typeof", "instanceof", "in", "of", "delete", "void", "yield", "async", "await", "import", "export", "from", "as", "try", "catch", "finally", "throw", "interface", "type", "enum", "implements", "public", "private", "protected", "readonly", "static", "null", "undefined", "true", "false", "package", "require", "module"]
                types = ["string", "number", "boolean", "any", "unknown", "never", "object", "symbol", "bigint", "Array", "Promise", "Map", "Set"]
                constants = ["true", "false", "null", "undefined", "NaN", "Infinity"]
                lineCommentMarkers = ["/"]
            case "json":
                keywords = []
                types = []
                constants = ["true", "false", "null"]
                lineCommentMarkers = []
                hasBlockComments = false
                stringDelimiters = ["\""]
                punctuation = ["{", "}", "[", "]", ":", ",", "."]
            case "rust", "rs":
                keywords = ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "use", "mod", "pub", "crate", "super", "self", "Self", "where", "as", "in", "ref", "move", "unsafe", "async", "await", "dyn", "type", "true", "false", "Some", "None", "Ok", "Err"]
                types = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"]
                constants = ["true", "false"]
            case "go", "golang":
                keywords = ["package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "chan", "map", "struct", "interface", "type", "const", "var", "nil", "true", "false"]
                types = ["string", "int", "int64", "float64", "bool", "byte", "rune", "error"]
                constants = ["true", "false", "nil", "iota"]
            case "c", "cpp", "c++", "objc":
                keywords = ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "const", "static", "struct", "enum", "union", "typedef", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "class", "public", "private", "protected", "virtual", "new", "delete", "using", "namespace", "template", "typename", "auto", "nullptr", "true", "false", "self", "this"]
                types = ["size_t", "string", "vector", "map", "set", "bool"]
                constants = ["true", "false", "NULL"]
            case "java", "kotlin", "kt":
                keywords = ["class", "interface", "object", "fun", "val", "var", "val", "public", "private", "protected", "internal", "override", "fun", "return", "if", "else", "for", "while", "do", "when", "try", "catch", "finally", "throw", "import", "package", "suspend", "companion", "data", "sealed", "open", "abstract", "null", "true", "false", "this", "super"]
                types = ["Int", "String", "Boolean", "Double", "Float", "Long", "List", "Map", "Set", "Any"]
                constants = ["true", "false", "null"]
            case "bash", "sh", "shell", "zsh", "console":
                keywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "export", "local", "source", "echo", "cd", "set", "unset"]
                types = []
                constants = []
                lineCommentMarkers = ["#"]
                hasBlockComments = false
                stringDelimiters = ["\"", "'"]
            case "sql":
                keywords = ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DISTINCT", "UNION"]
                types = ["INT", "INTEGER", "TEXT", "VARCHAR", "REAL", "DOUBLE", "BLOB", "BOOLEAN", "DATE", "TIMESTAMP"]
                constants = ["NULL", "TRUE", "FALSE"]
                lineCommentMarkers = ["-"]
                hasBlockComments = false
            case "html", "xml":
                keywords = []
                types = []
                constants = []
                lineCommentMarkers = []
                hasBlockComments = true
                stringDelimiters = ["\""]
                punctuation = ["<", ">", "/", "=", " "]
            case "css", "scss":
                keywords = ["important", "media", "import", "keyframes", "supports"]
                types = []
                constants = []
                lineCommentMarkers = []
                hasBlockComments = true
                stringDelimiters = ["\"", "'"]
            case "yaml", "yml":
                keywords = ["true", "false", "null"]
                types = []
                constants = ["true", "false", "null"]
                lineCommentMarkers = ["#"]
                hasBlockComments = false
            default:
                lineCommentMarkers = ["/", "#"]
                hasBlockComments = true
            }
        }

        func commentPrefix(for character: Character, characters: [Character], index: Int) -> String? {
            switch character {
            case "/":
                guard index + 1 < characters.count, characters[index + 1] == "/" else { return nil }
                return "//"
            case "#":
                return "#"
            default:
                return nil
            }
        }
    }
}
