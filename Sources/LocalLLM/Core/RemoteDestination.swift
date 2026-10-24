import Foundation

/// The privacy firewall's destination test, in one pure place.
///
/// The chat engine, compare mode, and any future send path must all
/// agree on the same question — "does this selection send text off
/// this Mac?" — because each of them scrubs with `Redactor` when
/// the answer is yes. Before this type existed the test lived inline
/// in `ChatEngine` only, and compare mode (which never passed
/// through the engine) sent its prompt unscrubbed (audit S-01).
///
/// The test FAILS CLOSED: a server selection whose configuration
/// can't be found counts as remote (audit S-08). Today the factory
/// resolves a missing server to the on-device backend before this
/// could matter, but a privacy test must never depend on that
/// ordering staying true.
enum RemoteDestination {

    /// True when a send to `selection` leaves this Mac: either cloud
    /// backend, or a saved server whose address is not local.
    static func isRemote(selection: ModelSelection,
                         endpoints: [EndpointConfig]) -> Bool {
        switch selection {
        case .privateCloudCompute, .openRouter:
            return true
        case .endpoint(let id):
            guard let config = endpoints.first(where: { $0.id == id })
            else { return true } // missing config: fail closed
            return !config.isLocalhost
        case .auto, .onDevice, .mlx:
            return false
        }
    }

    /// The copy of `text` that may be sent to `selection`: scrubbed
    /// by `Redactor` for a remote destination, exactly as written
    /// for a local one (a local result reports zero replacements).
    static func scrubbed(_ text: String,
                         selection: ModelSelection,
                         endpoints: [EndpointConfig],
                         customTerms: [String]) -> RedactionResult {
        guard isRemote(selection: selection, endpoints: endpoints)
        else {
            return RedactionResult(text: text, replacementCount: 0)
        }
        return Redactor.redact(text, customTerms: customTerms)
    }

    /// The one-line notice shown after a remote send (audit S-09:
    /// shown for EVERY remote send, not only when something was
    /// hidden — a send that matched no pattern still left the Mac,
    /// and the user should be told it did).
    ///
    /// With replacements, this is the engine's established wording;
    /// without, it states plainly that the prompt was sent and the
    /// privacy check ran first.
    static func noticeText(redactions: Int,
                           backendDisplayName: String,
                           selection: ModelSelection) -> String {
        let whereabouts = selection.isCloud
            ? "because \(backendDisplayName) runs in the cloud, "
                + "not on this Mac"
            : "because that server isn't on this Mac"
        if redactions > 0 {
            let noun = redactions == 1 ? "item" : "items"
            return "Privacy check: \(redactions) \(noun) that looked "
                + "like secrets or personal details were hidden "
                + "before this was sent to \(backendDisplayName), "
                + "\(whereabouts). Your saved chat is unchanged — "
                + "only the copy that was sent was edited."
        }
        let destination = selection.isCloud
            ? "\(backendDisplayName), which runs in the cloud, not "
                + "on this Mac"
            : "\(backendDisplayName), which isn't on this Mac"
        return "Sent to \(destination). The privacy check ran "
            + "first and didn't hide anything this time."
    }

    /// Audit S-03: image attachments never ride along to a remote
    /// destination. The privacy check covers text only — it cannot
    /// scrub a screenshot — so a remote send drops the images and
    /// says so (see `imageStripNoticeText`).
    static func shouldStripImages(isRemote: Bool,
                                  imageCount: Int) -> Bool {
        isRemote && imageCount > 0
    }

    /// The plain-English notice for a send whose images were held
    /// back under the rule above.
    static func imageStripNoticeText(
        backendDisplayName: String,
        selection: ModelSelection) -> String {
        let destination = selection.isCloud
            ? "this chat's model runs in the cloud, not on this Mac"
            : "this chat's model isn't on this Mac"
        return "Images weren't sent: \(destination), and the "
            + "privacy check only covers text, so attached images "
            + "were left out of what was sent to "
            + "\(backendDisplayName). Your message and its images "
            + "are still saved in the chat."
    }
}
