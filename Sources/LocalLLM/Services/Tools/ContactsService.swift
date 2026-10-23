import Contacts
import Foundation

/// Phase 5: contact lookup via the Contacts framework.
///
/// Search by name; returns the basic fields as stored (name, first
/// phone, first email, organization). These results are personal data:
/// they stay on this Mac unless the chat's model is a remote one, in
/// which case Phase 4's rule applies — the runtime redacts tool
/// results before they can enter a remote prompt, and tools are off
/// entirely for network backends under Local Only.
enum ContactsService {

    static func search(name rawName: String) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "No name was given to search for."
        }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        do {
            let matches = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: name),
                keysToFetch: keys)
            guard !matches.isEmpty else {
                return "No contacts matched “\(name)”."
            }
            let cap = 8
            var lines = ["Contacts matching “\(name)”:"]
            for contact in matches.prefix(cap) {
                lines.append("• \(contactLine(contact))")
            }
            if matches.count > cap {
                lines.append("… and \(matches.count - cap) more — a more specific name would narrow it.")
            }
            return lines.joined(separator: "\n")
        } catch {
            return "The contacts lookup failed — macOS refused the read."
        }
    }

    private static func contactLine(_ contact: CNContact) -> String {
        var name = CNContactFormatter.string(from: contact, style: .fullName)
            ?? [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
        if name.isEmpty { name = contact.organizationName }
        if name.isEmpty { name = "Unnamed contact" }
        var parts = [name]
        if let phone = contact.phoneNumbers.first?.value.stringValue {
            parts.append("phone: \(phone)")
        }
        if let email = contact.emailAddresses.first?.value {
            parts.append("email: \(email)")
        }
        if !contact.organizationName.isEmpty && contact.organizationName != name {
            parts.append("(\(contact.organizationName))")
        }
        return parts.joined(separator: " · ")
    }
}
