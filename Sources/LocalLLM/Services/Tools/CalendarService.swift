import EventKit
import Foundation

/// Phase 5: calendar events and reminders via EventKit.
///
/// Read-only: this phase never creates, edits, or completes anything.
/// Each call uses a fresh `EKEventStore` (cheap, and avoids holding
/// one across threads). Results are formatted for the model as plain
/// lines and capped — the runtime clamps further for the context
/// budget.
enum CalendarService {

    static func upcomingEvents(days: Int) -> String {
        let store = EKEventStore()
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else {
            return "No events in the next \(days) day\(days == 1 ? "" : "s")."
        }
        let cap = 20
        var lines = ["Events in the next \(days) day\(days == 1 ? "" : "s"):"]
        for event in events.prefix(cap) {
            lines.append("• \(eventLine(event))")
        }
        if events.count > cap {
            lines.append("… and \(events.count - cap) more.")
        }
        return lines.joined(separator: "\n")
    }

    static func incompleteReminders(limit: Int) async -> String {
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders = await fetchReminders(store: store, predicate: predicate)
        guard !reminders.isEmpty else {
            return "No unfinished reminders."
        }
        let sorted = reminders.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (lhs.title ?? "") < (rhs.title ?? "")
            }
        }
        var lines = ["Unfinished reminders:"]
        for reminder in sorted.prefix(limit) {
            var line = "• \(reminder.title ?? "Untitled reminder")"
            if let due = reminder.dueDate {
                line += " — due \(DateDisplay.dayAndTime(due))"
            }
            if let listName = reminder.calendarTitle {
                line += " (\(listName))"
            }
            lines.append(line)
        }
        if sorted.count > limit {
            lines.append("… and \(sorted.count - limit) more.")
        }
        return lines.joined(separator: "\n")
    }

    private static func eventLine(_ event: EKEvent) -> String {
        let title = event.title ?? "Untitled event"
        let when: String
        if event.isAllDay {
            when = "\(DateDisplay.weekdayDay(event.startDate)), all day"
        } else {
            when = "\(DateDisplay.weekdayDay(event.startDate)), "
                + "\(DateDisplay.time(event.startDate)) – \(DateDisplay.time(event.endDate))"
        }
        var line = "\(when) — \(title)"
        if let calendarName = event.calendar?.title {
            line += " (\(calendarName))"
        }
        if let location = event.location, !location.isEmpty {
            line += " · \(location)"
        }
        return line
    }

    private struct ReminderSnapshot: Sendable {
        let title: String?
        let dueDate: Date?
        let calendarTitle: String?
    }

    private static func fetchReminders(store: EKEventStore, predicate: NSPredicate) async -> [ReminderSnapshot] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).map {
                    ReminderSnapshot(title: $0.title, dueDate: $0.dueDateComponents?.date,
                                     calendarTitle: $0.calendar?.title)
                }
                continuation.resume(returning: snapshots)
            }
        }
    }
}
