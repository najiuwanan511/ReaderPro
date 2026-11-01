import Foundation

enum SourceScript {
    private struct Token {
        var text: String
        var range: Range<String.Index>
    }

    static func loadsOwnContent(_ rule: String) -> Bool {
        let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isJavaScriptRule(rule) {
            guard rule.hasPrefix("<js>"), let close = rule.range(of: "</js>", options: .backwards) else { return false }
            let tail = rule[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard tail.isEmpty || tail.hasPrefix("##") else { return false }
        }
        let tokens = tokenize(rule)
        guard tokens.count >= 4 else { return false }
        return (0..<(tokens.count - 3)).contains { index in
            tokens[index].text == "java" && tokens[index + 1].text == "."
                && ["ajax", "ajaxAll", "get", "post", "connect", "webView"].contains(tokens[index + 2].text)
                && tokens[index + 3].text == "("
        }
    }

    static func adaptingJavaCalls(_ script: String) -> String {
        guard script.contains("length") || script.contains("\u{200b}") || script.contains("=>") else { return script }
        // Most large source libraries contain ordinary `.length` properties,
        // arrows, and strings but no Java length() calls or Rhino array-arrow
        // parameters. Avoid allocating a token for every part of those scripts.
        guard needsJavaCallTokenization(script) else { return script }
        let tokens = tokenize(script)
        var edits: [(Range<String.Index>, String)] = []
        for index in tokens.indices {
            // Rhino accepts map([title,url]=>...), while JSC requires the
            // destructured parameter list to be parenthesized. Only repair
            // simple binding lists, never literals or existing valid arrows.
            if tokens[index].text == "]", index + 2 < tokens.count,
               tokens[index + 1].text == "=", tokens[index + 2].text == ">" {
                var start = index - 1
                while start >= 0, tokens[start].text != "[",
                      tokens[start].text == "," || identifier(tokens[start].text) { start -= 1 }
                if start >= 0, tokens[start].text == "[" {
                    let bindings = Array(tokens[(start + 1)..<index])
                    let simple = bindings.enumerated().allSatisfy { offset, token in
                        offset % 2 == 0 ? identifier(token.text) : token.text == ","
                    }
                    if !bindings.isEmpty, bindings.count % 2 == 1, simple {
                        let range = tokens[start].range.lowerBound..<tokens[index].range.upperBound
                        edits.append((range, "(" + String(script[range]) + ")"))
                    }
                }
            }
            if tokens[index].text == "\u{200b}", index > 0, index + 1 < tokens.count,
               tokens[index - 1].text == "getSource", tokens[index + 1].text == "(" {
                edits.append((tokens[index].range, ""))
            }
            guard index >= 2, index + 2 < tokens.count,
                  tokens[index].text == "length", tokens[index - 1].text == ".",
                  tokens[index + 1].text == "(", tokens[index + 2].text == ")",
                  identifier(tokens[index - 2].text) else { continue }
            var start = index - 2
            while start >= 2, tokens[start - 1].text == ".", identifier(tokens[start - 2].text) { start -= 2 }
            let receiver = String(script[tokens[start].range.lowerBound..<tokens[index - 1].range.lowerBound])
            edits.append((tokens[start].range.lowerBound..<tokens[index + 2].range.upperBound, "_javaLength(" + receiver + ")"))
        }
        var output = script
        for (range, value) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { output.replaceSubrange(range, with: value) }
        return output
    }

    // A conservative byte-level preflight: it may request the full tokenizer
    // for text inside strings, regexes or comments, but must never suppress an
    // edit that tokenizer would make. All non-ASCII bytes are treated as
    // possible whitespace between tokens; the full tokenizer decides whether
    // they actually are. No source text is changed here.
    static func needsJavaCallTokenization(_ script: String) -> Bool {
        if script.contains("\u{200b}") { return true }
        guard script.contains("length") || script.contains("=>") else { return false }

        func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            let count = bytes.count
            // Limit speculative scanning: unusually long whitespace/comments
            // fall back to the existing tokenizer rather than risking repeated
            // overlapping scans or suppressing a valid token sequence.
            func skipTrivia(_ start: Int) -> Int? {
                var index = start
                while index < count {
                    if index - start > 4096 { return nil }
                    let value = bytes[index]
                    if value <= 0x20 || value >= 0x80 { index += 1; continue }
                    guard value == 0x2f, index + 1 < count else { return index }
                    if bytes[index + 1] == 0x2a { // /* ... */
                        index += 2
                        while index + 1 < count, !(bytes[index] == 0x2a && bytes[index + 1] == 0x2f) {
                            if index - start > 4096 { return nil }
                            index += 1
                        }
                        guard index + 1 < count else { return nil }
                        index += 2
                    } else if bytes[index + 1] == 0x2f { // // ... newline
                        index += 2
                        while index < count {
                            if index - start > 4096 { return nil }
                            let c = bytes[index]
                            if c == 0x0a || c == 0x0b || c == 0x0c || c == 0x0d { break }
                            // Character.isNewline also recognizes NEL, LS, PS.
                            if c == 0xc2, index + 1 < count, bytes[index + 1] == 0x85 { break }
                            if c == 0xe2, index + 2 < count, bytes[index + 1] == 0x80,
                               bytes[index + 2] == 0xa8 || bytes[index + 2] == 0xa9 { break }
                            // An unusual ASCII control in a comment is rare;
                            // defer its exact newline semantics to tokenizer.
                            if c < 0x20, c != 0x09 { return nil }
                            index += 1
                        }
                    } else { return index }
                }
                return index
            }

            for index in 0..<count {
                if bytes[index] == 0x2e { // . length ( )
                    guard let word = skipTrivia(index + 1) else { return true }
                    if word + 6 <= count,
                       bytes[word] == 0x6c, bytes[word + 1] == 0x65, bytes[word + 2] == 0x6e,
                       bytes[word + 3] == 0x67, bytes[word + 4] == 0x74, bytes[word + 5] == 0x68 {
                        guard let opening = skipTrivia(word + 6) else { return true }
                        if opening < count, bytes[opening] == 0x28 {
                            guard let closing = skipTrivia(opening + 1) else { return true }
                            if closing < count, bytes[closing] == 0x29 { return true }
                        }
                    }
                } else if bytes[index] == 0x5d { // ] = >
                    guard let equals = skipTrivia(index + 1) else { return true }
                    if equals < count, bytes[equals] == 0x3d {
                        guard let greater = skipTrivia(equals + 1) else { return true }
                        if greater < count, bytes[greater] == 0x3e { return true }
                    }
                }
            }
            return false
        }

        return script.utf8.withContiguousStorageIfAvailable { scan($0) }
            ?? Array(script.utf8).withUnsafeBufferPointer { scan($0) }
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
