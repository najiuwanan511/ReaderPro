import Foundation

enum SourceScript {
    private struct Token {
        var text: String
        var range: Range<String.Index>
    }

    // Rhino accepts `function f(key) { let key = ...; }`. JSC rejects the
    // entire library, including unrelated search functions. Repair only a
    // simple, single binding at function-body scope that shadows a parameter.
    // Called only after JSC reports that exact syntax error; valid libraries
    // and nested block/loop scopes keep their original lexical semantics.
    static func repairingParameterRedeclarations(_ script: String) -> String {
        let tokens = tokenize(script)
        var replacements: [Range<String.Index>] = []
        for index in tokens.indices where tokens[index].text == "function" {
            var cursor = index + 1
            if cursor < tokens.count, tokens[cursor].text != "(" { cursor += 1 }
            guard cursor < tokens.count, tokens[cursor].text == "(" else { continue }
            cursor += 1
            var parameters = Set<String>(), simple = true, expectsName = true
            while cursor < tokens.count, tokens[cursor].text != ")" {
                let token = tokens[cursor].text
                if expectsName && identifier(token) { parameters.insert(token) }
                else if !expectsName && token == "," { }
                else { simple = false; break }
                expectsName.toggle(); cursor += 1
            }
            guard simple, !parameters.isEmpty, cursor + 1 < tokens.count,
                  tokens[cursor].text == ")", tokens[cursor + 1].text == "{" else { continue }
            cursor += 2
            var depth = 1
            while cursor < tokens.count, depth > 0 {
                let token = tokens[cursor].text
                if token == "{" { depth += 1 }
                else if token == "}" { depth -= 1 }
                else if depth == 1, token == "let", cursor + 2 < tokens.count,
                        ["{", ";"].contains(tokens[cursor - 1].text),
                        parameters.contains(tokens[cursor + 1].text), tokens[cursor + 2].text == "=" {
                    var end = cursor + 3, nesting = 0, single = true
                    while end < tokens.count {
                        let next = tokens[end].text
                        if nesting == 0 && [";", "}"].contains(next) { break }
                        if nesting == 0 && next == "," { single = false; break }
                        if ["(", "[", "{"].contains(next) { nesting += 1 }
                        if [")", "]", "}"].contains(next) { nesting -= 1 }
                        end += 1
                    }
                    if single, end < tokens.count, tokens[end].text == ";" { replacements.append(tokens[cursor].range) }
                }
                cursor += 1
            }
        }
        var output = script
        for range in Set(replacements).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            output.replaceSubrange(range, with: "var")
        }
        return output
    }

    private static func identifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" || first == "$" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }

    private static func tokenize(_ script: String) -> [Token] {
        var tokens: [Token] = [], cursor = script.startIndex
        func advance() { cursor = script.index(after: cursor) }
        while cursor < script.endIndex {
            let start = cursor, char = script[cursor]
            if char.isWhitespace { advance(); continue }
            let next = script.index(after: cursor)
            if char == "/", next < script.endIndex, script[next] == "/" {
                while cursor < script.endIndex, !script[cursor].isNewline { advance() }
                continue
            }
            if char == "/", next < script.endIndex, script[next] == "*" {
                cursor = script.index(after: next)
                while cursor < script.endIndex {
                    let after = script.index(after: cursor)
                    if script[cursor] == "*", after < script.endIndex, script[after] == "/" {
                        cursor = script.index(after: after); break
                    }
                    advance()
                }
                continue
            }
            if char == "\"" || char == "'" || char == "`" {
                advance()
                while cursor < script.endIndex {
                    let current = script[cursor]; advance()
                    if current == "\\", cursor < script.endIndex { advance() }
                    else if current == char { break }
                }
                tokens.append(Token(text: "<literal>", range: start..<cursor)); continue
            }
            let previous = tokens.last?.text ?? "="
            if char == "/", ["=", "(", "[", ",", ":", "!", "?", ";", "{", "return", "case", "=>"].contains(previous) {
                advance(); var inClass = false
                while cursor < script.endIndex {
                    let current = script[cursor]; advance()
                    if current == "\\", cursor < script.endIndex { advance(); continue }
                    if current == "[" { inClass = true }
                    if current == "]" { inClass = false }
                    if current == "/", !inClass { break }
                }
                while cursor < script.endIndex, script[cursor].isLetter { advance() }
                tokens.append(Token(text: "<literal>", range: start..<cursor)); continue
            }
            if char.isLetter || char.isNumber || char == "_" || char == "$" {
                advance()
                while cursor < script.endIndex, script[cursor].isLetter || script[cursor].isNumber || script[cursor] == "_" || script[cursor] == "$" { advance() }
            } else { advance() }
            tokens.append(Token(text: String(script[start..<cursor]), range: start..<cursor))
        }
        return tokens
    }
}
