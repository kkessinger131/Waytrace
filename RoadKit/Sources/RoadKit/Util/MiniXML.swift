import Foundation

/// A small XML reader, enough for OSM XML, GPX and KML (what road_to_kml.py reads with
/// xml.etree.ElementTree). Works the same on iOS and Linux, with no libxml2.
public final class MiniXMLNode {
    /// The tag as written, with any prefix ("gx:Track").
    public let name: String
    public var attributes: [String: String]
    public var children: [MiniXMLNode] = []
    /// All character data directly inside this element.
    public var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// The tag without its namespace prefix (road_tracks._local).
    public var local: String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    public func get(_ key: String) -> String? { attributes[key] }

    /// ElementTree findall(name): direct children with this tag.
    public func findAll(_ tag: String) -> [MiniXMLNode] { children.filter { $0.name == tag } }

    /// ElementTree iter(): this element and every descendant, in document order.
    public func iter() -> [MiniXMLNode] {
        var out: [MiniXMLNode] = []
        var stack: [MiniXMLNode] = [self]
        while let n = stack.popLast() {
            out.append(n)
            stack.append(contentsOf: n.children.reversed())
        }
        return out
    }
}

public struct XMLParseError: Error, CustomStringConvertible {
    public let description: String
}

public enum MiniXML {
    /// Parse a document and return its root element.
    public static func parse(_ data: Data) throws -> MiniXMLNode {
        var p = Parser(bytes: [UInt8](data))
        return try p.document()
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        }

        func position() -> String {
            var line = 1, col = 0
            for k in 0..<min(i, bytes.count) {
                if bytes[k] == 0x0A { line += 1; col = 0 } else { col += 1 }
            }
            return "line \(line), column \(col)"
        }

        func fail(_ what: String) -> XMLParseError { XMLParseError(description: "\(what): \(position())") }

        func starts(_ s: String) -> Bool {
            let u = Array(s.utf8)
            return i + u.count <= bytes.count && Array(bytes[i..<(i + u.count)]) == u
        }

        mutating func skip(past s: String) throws {
            let u = Array(s.utf8)
            while i + u.count <= bytes.count {
                if bytes[i] == u[0] && Array(bytes[i..<(i + u.count)]) == u { i += u.count; return }
                i += 1
            }
            throw fail("unclosed token")
        }

        static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        static func isNameChar(_ b: UInt8) -> Bool {
            !(isSpace(b) || b == UInt8(ascii: "/") || b == UInt8(ascii: ">") || b == UInt8(ascii: "=")
              || b == UInt8(ascii: "<") || b == UInt8(ascii: "\"") || b == UInt8(ascii: "'"))
        }

        mutating func skipSpace() { while i < bytes.count && Parser.isSpace(bytes[i]) { i += 1 } }

        mutating func name() throws -> String {
            let start = i
            while i < bytes.count && Parser.isNameChar(bytes[i]) { i += 1 }
            if i == start { throw fail("not well-formed (invalid token)") }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        static func decodeEntities(_ s: String) -> String {
            guard s.contains("&") else { return s }
            var out = ""
            var rest = Substring(s)
            while let amp = rest.firstIndex(of: "&") {
                out += rest[..<amp]
                guard let semi = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 12 else {
                    out += "&"
                    rest = rest[rest.index(after: amp)...]
                    continue
                }
                let ent = String(rest[rest.index(after: amp)..<semi])
                var rep: String?
                switch ent {
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "amp": rep = "&"
                case "quot": rep = "\""
                case "apos": rep = "'"
                default:
                    if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let v = UInt32(ent.dropFirst(2), radix: 16),
                       let u = Unicode.Scalar(v) {
                        rep = String(Character(u))
                    } else if ent.hasPrefix("#"), let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) {
                        rep = String(Character(u))
                    }
                }
                if let rep {
                    out += rep
                    rest = rest[rest.index(after: semi)...]
                } else {
                    out += "&"
                    rest = rest[rest.index(after: amp)...]
                }
            }
            out += rest
            return out
        }

        mutating func document() throws -> MiniXMLNode {
            var stack: [MiniXMLNode] = []
            var root: MiniXMLNode?
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "<") {
                    if starts("<?") { try skip(past: "?>"); continue }
                    if starts("<!--") { try skip(past: "-->"); continue }
                    if starts("<![CDATA[") {
                        i += 9
                        let start = i
                        try skip(past: "]]>")
                        if let top = stack.last { top.text += String(decoding: bytes[start..<(i - 3)], as: UTF8.self) }
                        continue
                    }
                    if starts("<!") {
                        // DOCTYPE (with an optional internal subset)
                        var depth = 0
                        while i < bytes.count {
                            let b = bytes[i]
                            i += 1
                            if b == UInt8(ascii: "[") { depth += 1 }
                            if b == UInt8(ascii: "]") { depth -= 1 }
                            if b == UInt8(ascii: ">") && depth <= 0 { break }
                        }
                        continue
                    }
                    if starts("</") {
                        i += 2
                        let n = try name()
                        skipSpace()
                        guard i < bytes.count, bytes[i] == UInt8(ascii: ">") else { throw fail("not well-formed (invalid token)") }
                        i += 1
                        guard let top = stack.popLast(), top.name == n else { throw fail("mismatched tag") }
                        if stack.isEmpty { root = top }
                        continue
                    }
                    i += 1
                    let n = try name()
                    var attrs: [String: String] = [:]
                    var selfClosing = false
                    while true {
                        skipSpace()
                        guard i < bytes.count else { throw fail("unclosed token") }
                        if bytes[i] == UInt8(ascii: ">") { i += 1; break }
                        if bytes[i] == UInt8(ascii: "/") {
                            i += 1
                            guard i < bytes.count, bytes[i] == UInt8(ascii: ">") else { throw fail("not well-formed (invalid token)") }
                            i += 1
                            selfClosing = true
                            break
                        }
                        let key = try name()
                        skipSpace()
                        guard i < bytes.count, bytes[i] == UInt8(ascii: "=") else { throw fail("not well-formed (invalid token)") }
                        i += 1
                        skipSpace()
                        guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") else {
                            throw fail("not well-formed (invalid token)")
                        }
                        let q = bytes[i]
                        i += 1
                        let start = i
                        while i < bytes.count && bytes[i] != q { i += 1 }
                        guard i < bytes.count else { throw fail("unclosed token") }
                        attrs[key] = Parser.decodeEntities(String(decoding: bytes[start..<i], as: UTF8.self))
                        i += 1
                    }
                    if root != nil && stack.isEmpty { throw fail("junk after document element") }
                    let node = MiniXMLNode(name: n, attributes: attrs)
                    stack.last?.children.append(node)
                    if selfClosing {
                        if stack.isEmpty { root = node }
                    } else {
                        stack.append(node)
                    }
                } else {
                    let start = i
                    while i < bytes.count && bytes[i] != UInt8(ascii: "<") { i += 1 }
                    if let top = stack.last {
                        top.text += Parser.decodeEntities(String(decoding: bytes[start..<i], as: UTF8.self))
                    } else if bytes[start..<i].contains(where: { !Parser.isSpace($0) }) {
                        i = start
                        throw fail(root == nil ? "syntax error" : "junk after document element")
                    }
                }
            }
            if !stack.isEmpty { throw fail("no element found") }
            guard let root else { throw fail("no element found") }
            return root
        }
    }
}
