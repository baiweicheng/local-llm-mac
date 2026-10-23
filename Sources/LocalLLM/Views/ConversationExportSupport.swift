import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Phase 10: the view-layer half of conversation export — turning
/// a SwiftData `Conversation` into the pure `ConversationExport`
/// values, and the two destinations (a Markdown file via the save
/// panel, and the clipboard). Shared by the sidebar's context menu
/// and the chat header's export menu so both produce identical
/// documents.
enum ConversationExporter {

    static func markdown(for conversation: Conversation,
                         includeTelemetry: Bool = true) -> String {
        let inputs = conversation.sortedMessages.map { message in
            ConversationExport.MessageInput(
                role: message.messageRole,
                createdAt: message.createdAt,
                text: message.text,
                attachmentCount: message.attachments.count,
                telemetry: message.telemetry)
        }
        return ConversationExport.markdown(
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            exportedAt: Date(),
            messages: inputs,
            includeTelemetry: includeTelemetry)
    }

    /// The standard save panel, pre-named "<title>.md".
    static func exportToFile(_ conversation: Conversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            ConversationExport.suggestedFileName(forTitle: conversation.title)
        panel.allowedContentTypes =
            [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Save this chat as a Markdown file."
        if panel.runModal() == .OK, let url = panel.url {
            try? markdown(for: conversation)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func copyToPasteboard(_ conversation: Conversation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown(for: conversation), forType: .string)
    }
}
