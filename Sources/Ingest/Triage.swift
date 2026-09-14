import Foundation
import Domain
import Support

/// Builds the reader's prompt for one item and parses its reply. Prompts are files, keyed by
/// `SourceKind`; the JSON contract is shared so `parse` is one function.
public struct Triage: Sendable {
    public static let jsonSchema = """
    {"type":"object","properties":{"summary":{"type":"string"},"title":{"type":"string"},"keep":{"type":"boolean"},"sensitive":{"type":"boolean"}},"required":["summary","title","keep"]}
    """

    private let templates: [SourceKind: String]
    private let dateFormatter: DateFormatter

    public init(bundle: Bundle? = nil) throws {
        let bundle = bundle ?? Bundle.module
        var t: [SourceKind: String] = [:]
        let files: [SourceKind: String] = [.document: "document", .directMessage: "direct-message", .groupChat: "group-chat", .mail: "mail", .event: "event", .ticket: "ticket"]
        for (kind, name) in files {
            guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Prompts") ?? bundle.url(forResource: name, withExtension: "md") else {
                throw TriageError.missingPrompt(name)
            }
            t[kind] = try String(contentsOf: url, encoding: .utf8)
        }
        templates = t
        dateFormatter = DateFormatter(); dateFormatter.dateStyle = .full; dateFormatter.timeStyle = .none
    }

    public enum TriageError: Error { case missingPrompt(String) }

    public func prompt(for a: Artifact, now: Date) -> String {
        let kind: SourceKind = (a.kind == .directMessage || a.kind == .groupChat) ? (a.isGroup ? .groupChat : .directMessage) : a.kind
        var s = templates[kind] ?? templates[.document]!
        let body: String
        if a.imageJPEG != nil { body = "The item is the attached image." }
        else if let text = a.text, !text.isEmpty { body = "Content (may be truncated):\n\"\"\"\n\(text)\n\"\"\"" }
        else { body = "(No readable text — judge from the name and dates.)" }
        s = s.replacingOccurrences(of: "{{today}}", with: dateFormatter.string(from: now))
        s = s.replacingOccurrences(of: "{{displayPath}}", with: a.metadata["displayPath"] ?? a.metadata["name"] ?? a.candidate.id)
        s = s.replacingOccurrences(of: "{{created}}", with: a.metadata["created"] ?? "unknown")
        s = s.replacingOccurrences(of: "{{body}}", with: body)
        s = s.replacingOccurrences(of: "{{conversation}}", with: a.text ?? "(empty conversation)")
        return s
    }

    /// Lenient, fail-closed. Isolates the outermost `{…}`, tries strict JSON, then recovers fields
    /// one by one from almost-JSON. No recoverable summary ⇒ nil ⇒ the item is dropped.
    public static func parse(_ text: String) -> Judgement? {
        let span: Substring
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e { span = text[s...e] } else { span = Substring(text) }
        if let data = span.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func flag(_ k: String) -> Bool? {
                if let b = obj[k] as? Bool { return b }
                if let n = obj[k] as? NSNumber { return n.boolValue }
                if let s = obj[k] as? String { return ["true", "yes", "1"].contains(s.lowercased()) ? true : (["false", "no", "0"].contains(s.lowercased()) ? false : nil) }
                return nil
            }
            guard let summary = obj["summary"] as? String else { return nil }
            return Judgement(summary: summary, title: (obj["title"] as? String) ?? "", keep: flag("keep") ?? false, sensitive: flag("sensitive") ?? false)
        }
        guard let summary = stringField("summary", in: String(span)) else { return nil }
        return Judgement(summary: summary, title: stringField("title", in: String(span)) ?? "", keep: boolField("keep", in: String(span)) ?? false,
                         sensitive: boolField("sensitive", in: String(span)) ?? false)
    }

    private static func stringField(_ key: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"") else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
    }

    private static func boolField(_ key: String, in s: String) -> Bool? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"?(true|false|yes|no|1|0)\"?", options: .caseInsensitive) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ["true", "yes", "1"].contains(ns.substring(with: m.range(at: 1)).lowercased())
    }
}
