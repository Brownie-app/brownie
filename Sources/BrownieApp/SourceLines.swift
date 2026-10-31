import Foundation
import Domain
import LocalSources
import CloudSources
import TelegramSource
import Support

/// Reading a conversation back, so the night can check what it wrote about it.
///
/// Brownie has always been able to do this — it is what the evidence sheet does when the user taps a card's
/// source and the chat opens at the right line. Until now it only ever ran *after* the fact, to show someone
/// where a claim came from. This runs it before: the same read, on the same messages, so a claim that does not
/// match them never reaches the morning.
///
/// Nothing here is stored or sent. The lines are fetched, compared against, and dropped inside the one call —
/// which is also why this reads from the sources rather than from a cache of its own: a second copy of the
/// user's messages is exactly what Brownie does not keep.
enum SourceLines {

    /// How far either side of the day a promise was made to look. A loop is dated by the message that opened
    /// it, but the judge's day can be a day out when a chat runs past midnight or a summary covers a span.
    static let daysAround = 3.0
    /// Enough of a conversation to find the line in, not enough to be a transcript.
    static let lineCap = 400

    /// The apps worth asking, in the order a direct chat is most likely to be found.
    static func reader(_ app: String) -> (any ChatReader)? {
        switch app {
        case "whatsapp": return WhatsAppSource()
        case "imessage": return iMessageSource()
        case "telegram": return TelegramSource.isConfigured ? TelegramSource() : nil
        case "slack": return SlackAuth.isSignedIn ? SlackSource() : nil
        case "teams": return MicrosoftAuth.isSignedIn ? TeamsSource() : nil
        default: return nil
        }
    }

    /// The chat list per app, for one night.
    ///
    /// `chats()` enumerates every conversation the app has — for WhatsApp that is a walk of the whole message
    /// database. The gate asks about one person per loop, and a busy week has twenty, so without this the night
    /// would enumerate every chat twenty times over to answer twenty questions. Held for the run and dropped
    /// with it; it is a list of names, never messages.
    actor Directory {
        private var byApp: [String: [BucketInfo]] = [:]
        func chats(_ app: String, from reader: any ChatReader) async -> [BucketInfo] {
            if let had = byApp[app] { return had }
            let found = (try? await reader.chats()) ?? []
            byApp[app] = found
            return found
        }
    }
    static let directory = Directory()

    /// Every message with `person` around `around`, from whichever app the conversation is in.
    ///
    /// Returns nothing when the person cannot be found, when no source is set up, or when a read fails. Every
    /// caller reads that as "could not check", never as "nothing was said" — a chat Brownie cannot open must
    /// not be able to silence a true promise.
    static let lookup: SourceLineLookup = { person, around in
        let log = Log("proactive.judge")
        let from = around.addingTimeInterval(-daysAround * 86400)
        let to = around.addingTimeInterval(daysAround * 86400)
        for app in ["whatsapp", "imessage", "telegram", "slack", "teams"] {
            guard let reader = reader(app) else { continue }
            do {
                let chats = await directory.chats(app, from: reader)
                guard let chat = EvidenceResolver.chat(named: person, in: chats) else { continue }
                let messages = try await reader.messages(in: chat.id, from: from, to: to)
                guard !messages.isEmpty else { continue }
                return messages.suffix(lineCap).map { SourceLine(id: String($0.rowID), said: $0.date, text: $0.text) }
            } catch {
                log.warn("could not read \(app) back for \(person): \(error)")
            }
        }
        return []
    }
}
