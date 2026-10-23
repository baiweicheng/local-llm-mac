import Foundation

/// Small shared date formatting for tool results and cards, pinned to
/// a fixed locale so the strings are stable and testable. Dates shown
/// to the user in the transcript come from the views' own formatters;
/// these are for model-facing tool text and compact log rows.
enum DateDisplay {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let dayAndTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let weekdayDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter
    }()

    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func dayAndTime(_ date: Date) -> String { dayAndTimeFormatter.string(from: date) }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    static func weekdayDay(_ date: Date) -> String { weekdayDayFormatter.string(from: date) }

    /// The current-time tool's full answer, from an injected clock so
    /// it's testable: weekday, date, time, and the time zone spelled
    /// out.
    static func fullDescription(of date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let zoneName = timeZone.localizedName(for: .standard, locale: Locale(identifier: "en_US"))
            ?? timeZone.identifier
        return "It's \(formatter.string(from: date)) (\(zoneName))."
    }
}
