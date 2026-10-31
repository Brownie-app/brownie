import Foundation

/// Turning what an IMAP server hands back into something the reader can judge.
///
/// All of it is pure: bytes in, text out, no connection anywhere near it. Mail is the one format Brownie reads
/// that was standardised in 1982 and amended ever since, so the awkward parts — a header folded over three
/// lines, a subject encoded word by word, a body in quoted-printable — are the normal case rather than the
/// edge case, and each one has its own test.
public enum MailParsing {

    // MARK: - Headers

    /// The headers of one message, lower-cased by name, unfolded, and decoded out of RFC 2047.
    ///
    /// A header may run over several lines, each continuation beginning with a space or a tab (RFC 5322 §2.2.3).
    /// Unfolding has to happen before anything else or a long subject arrives in pieces.
    public static func headers(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var name = "", value = ""
        func flush() {
            guard !name.isEmpty else { return }
            let decoded = decodeWords(value.trimmingCharacters(in: .whitespaces))
            // A repeated header keeps the first: Received: appears many times and only the newest matters.
            if out[name] == nil { out[name] = decoded }
            name = ""; value = ""
        }
        // CR-LF is one Character in Swift, not two, so splitting on "\n" alone silently matches nothing and
        // the whole block arrives as a single line. Normalise the line endings before looking for them.
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { break }                                   // the blank line ends the header block
            if line.hasPrefix(" ") || line.hasPrefix("\t") { value += " " + line.trimmingCharacters(in: .whitespaces); continue }
            flush()
            guard let colon = line.firstIndex(of: ":") else { continue }
            name = line[line.startIndex..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        flush()
        return out
    }

    /// RFC 2047 encoded words — `=?UTF-8?B?…?=` and `=?…?Q?…?=` — as they appear in a Subject or a From.
    ///
    /// Adjacent encoded words separated only by whitespace are one run and the whitespace between them is not
    /// part of the text (RFC 2047 §6.2), which is why a name in two words does not come back with a double space.
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let rx = #/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/#
        var out = "", last = s.startIndex, previousWasWord = false
        for m in s.matches(of: rx) {
            let between = String(s[last..<m.range.lowerBound])
            if !(previousWasWord && between.trimmingCharacters(in: .whitespaces).isEmpty) { out += between }
            let charset = String(m.1), encoding = String(m.2).uppercased(), payload = String(m.3)
            let data = encoding == "B" ? Data(base64Encoded: pad(payload)) : decodeQ(payload)
            out += data.flatMap { string($0, charset: charset) } ?? String(s[m.range])
            last = m.range.upperBound; previousWasWord = true
        }
        out += String(s[last...])
        return out
    }

    /// The display name out of a From or To, falling back to the address when there is no name.
    /// `"Lalita Pathak" <l@x.test>` → `Lalita Pathak`; `l@x.test` → `l`.
    public static func displayName(_ addr: String) -> String {
        let a = addr.trimmingCharacters(in: .whitespaces)
        if let lt = a.firstIndex(of: "<") {
            let name = String(a[a.startIndex..<lt]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty { return name }
            let inner = String(a[a.index(after: lt)...].prefix(while: { $0 != ">" }))
            return String(inner.prefix(while: { $0 != "@" }))
        }
        if a.contains("@") { return String(a.prefix(while: { $0 != "@" })) }
        return a
    }

    /// The bare address out of a From or To, lower-cased. Nil when there is not one.
    public static func address(_ addr: String) -> String? {
        let a = addr.trimmingCharacters(in: .whitespaces)
        let inner = a.firstIndex(of: "<").map { String(a[a.index(after: $0)...].prefix(while: { $0 != ">" })) } ?? a
        let t = inner.trimmingCharacters(in: .whitespaces).lowercased()
        return t.contains("@") && !t.hasPrefix("@") && !t.hasSuffix("@") ? t : nil
    }

    // MARK: - Bodies

    /// The readable text of a message body, given its headers.
    ///
    /// Decodes the transfer encoding, picks the plain-text part of a multipart message when there is one, and
    /// falls back to stripping tags out of the HTML when there is not. Everything else — attachments, inline
    /// images, calendar parts — is dropped: the reader judges what was said, not what was attached.
    public static func body(_ rawIn: String, headers h: [String: String]) -> String {
        // CR-LF is a single Character in Swift. Every length- or offset-based move over it is a trap, so the
        // line endings are normalised once here and nothing below has to think about them again.
        let raw = rawIn.replacingOccurrences(of: "\r\n", with: "\n")
        let type = h["content-type"] ?? "text/plain"
        if let boundary = parameter("boundary", in: type) {
            let parts = split(raw, boundary: boundary)
            let decoded = parts.map { part -> (type: String, text: String) in
                let ph = headers(part)
                let inner = part.range(of: "\n\n").map { String(part[$0.upperBound...]) } ?? part
                return ((ph["content-type"] ?? "text/plain").lowercased(), body(inner, headers: ph))
            }
            if let plain = decoded.first(where: { $0.type.hasPrefix("text/plain") }) { return plain.text }
            if let html = decoded.first(where: { $0.type.hasPrefix("text/html") }) { return html.text }
            return decoded.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = decodeTransfer(raw, encoding: (h["content-transfer-encoding"] ?? "").lowercased(), charset: parameter("charset", in: type))
        // Trimmed, because a part always ends with the newline that precedes its boundary and that is
        // punctuation of the envelope, not something anybody wrote.
        return (type.lowercased().hasPrefix("text/html") ? stripTags(text) : text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text/plain; charset="UTF-8"` → the value of one parameter, quotes removed.
    public static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].lowercased() == name else { continue }
            return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    static func decodeTransfer(_ s: String, encoding: String, charset: String?) -> String {
        switch encoding {
        case "base64":
            let joined = s.filter { !$0.isWhitespace }
            guard let d = Data(base64Encoded: pad(joined)) else { return s }
            return string(d, charset: charset) ?? s
        case "quoted-printable":
            guard let d = decodeQP(s) else { return s }
            return string(d, charset: charset) ?? s
        default:
            // 7bit, 8bit, binary, or absent: already text, but perhaps not in UTF-8.
            guard let cs = charset, cs.lowercased() != "utf-8", let d = s.data(using: .utf8), let reread = string(d, charset: cs) else { return s }
            return reread
        }
    }

    /// Quoted-printable (RFC 2045 §6.7): `=XX` is a byte, `=` at end of line is a soft break that disappears.
    static func decodeQP(_ s: String) -> Data? {
        var out = Data()
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            var l = Substring(line)
            let soft = l.hasSuffix("=")
            if soft { l = l.dropLast() }
            var it = l.startIndex
            while it < l.endIndex {
                if l[it] == "=", let a = l.index(it, offsetBy: 1, limitedBy: l.endIndex), let b = l.index(it, offsetBy: 2, limitedBy: l.endIndex), b < l.endIndex || a < l.endIndex,
                   let byte = UInt8(String(l[a...l.index(after: a)]), radix: 16) {
                    out.append(byte); it = l.index(it, offsetBy: 3)
                } else {
                    out.append(contentsOf: Array(String(l[it]).utf8)); it = l.index(after: it)
                }
            }
            if !soft && i < lines.count - 1 { out.append(contentsOf: Array("\n".utf8)) }
        }
        return out
    }

    /// The Q encoding of RFC 2047: quoted-printable, but `_` is a space and `=` is always hex.
    static func decodeQ(_ s: String) -> Data? { decodeQP(s.replacingOccurrences(of: "_", with: " ")) }

    /// The parts between the boundary markers. Expects line endings already normalised to LF.
    static func split(_ raw: String, boundary: String) -> [String] {
        raw.components(separatedBy: "--" + boundary).dropFirst().dropLast()
            .map { $0.hasPrefix("\n") ? String($0.dropFirst()) : $0 }
    }

    public static func stripTags(_ html: String) -> String {
        var s = html
        for block in ["script", "style"] { s = s.replacingOccurrences(of: "<\(block)[^>]*>[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive]) }
        s = s.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (e, c) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] { s = s.replacingOccurrences(of: e, with: c) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dates

    /// An RFC 5322 Date header. Several spellings are in the wild, including a two-digit year and a named zone.
    public static func date(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    /// IMAP's own INTERNALDATE, which is not the RFC 5322 spelling: ` 1-Sep-2026 10:00:00 +0000`.
    public static func internalDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: s.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
    }

    /// The day as IMAP's SEARCH wants it: `1-Sep-2026`, always in English.
    public static func searchDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d-MMM-yyyy"; f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }

    // MARK: - Small helpers

    static func pad(_ b64: String) -> String { b64 + String(repeating: "=", count: (4 - b64.count % 4) % 4) }

    static func string(_ d: Data, charset: String?) -> String? {
        let name = (charset ?? "utf-8").lowercased()
        if name == "utf-8" || name == "utf8" || name == "us-ascii" || name == "ascii" { return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) }
        let enc = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(name as CFString))
        if enc != kCFStringEncodingInvalidId, let s = String(data: d, encoding: String.Encoding(rawValue: enc)) { return s }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }
}
