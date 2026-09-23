import Foundation
import Contacts
import Domain

/// The Mac's Contacts as the registry reads them: one `ContactCard` per person with a phone or an email, so two chats
/// whose handles fall on one card are one person. Read on this Mac only, and only once the user has allowed it —
/// nothing here ever raises the system prompt; Settings asks through `requestAccess`.
extension ContactLookup {
    public static var isAuthorized: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    /// Raises the macOS prompt once (a later call answers from the grant). Settings → Sources calls this; nothing else does.
    public static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    /// Every card with at least one phone or email, as `card` spells it. Empty when Contacts is not yet allowed — the
    /// prompt is never raised from here — or when the store cannot be read.
    public static func cards() -> [ContactCard] {
        guard isAuthorized else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys)
        var out: [ContactCard] = []
        try? CNContactStore().enumerateContacts(with: req) { c, _ in
            if let card = card(givenName: c.givenName, familyName: c.familyName, organization: c.organizationName, nickname: c.nickname,
                               phones: c.phoneNumbers.map(\.value.stringValue), emails: c.emailAddresses.map { String($0.value) }) { out.append(card) }
        }
        return out
    }

    /// One card from its raw fields: the name is given + family, or the organisation when both are empty; the nickname
    /// rides along when set; phones and emails are handed to `ContactCard` raw, which spells them. Nil for a card with no
    /// name at all, or one that proves nothing (no phone and no email that spells).
    public static func card(givenName: String, familyName: String, organization: String, nickname: String, phones: [String], emails: [String]) -> ContactCard? {
        let person = [givenName, familyName].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let name = person.isEmpty ? organization.trimmingCharacters(in: .whitespaces) : person
        guard !name.isEmpty else { return nil }
        let nick = nickname.trimmingCharacters(in: .whitespaces)
        let card = ContactCard(name: name, nickname: nick.isEmpty ? nil : nick, phones: phones, emails: emails)
        return card.proofs.isEmpty ? nil : card
    }
}
