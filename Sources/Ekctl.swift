import ArgumentParser
import EventKit
import Foundation

// MARK: - Main Command

@main
struct Ekctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ekctl",
        abstract: "A command-line tool for managing macOS Calendar events and Reminders using EventKit.",
        version: "1.0.0",
        subcommands: [List.self, Show.self, Add.self, Delete.self, Complete.self],
        defaultSubcommand: List.self
    )
}

// MARK: - List Commands

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List calendars, events, or reminders.",
        subcommands: [ListCalendars.self, ListEvents.self, ListReminders.self]
    )
}

struct ListCalendars: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List all calendars and reminder lists."
    )

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.listCalendars()
        print(result.toJSON())
    }
}

struct ListEvents: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events in a calendar within a date range."
    )

    @Option(name: .long, help: "The calendar ID to list events from.")
    var calendar: String

    @Option(name: .long, help: "Start date in ISO8601 format (e.g., 2026-02-01T00:00:00Z).")
    var from: String

    @Option(name: .long, help: "End date in ISO8601 format (e.g., 2026-02-07T23:59:59Z).")
    var to: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        guard let startDate = ISO8601DateFormatter().date(from: from) else {
            print(JSONOutput.error("Invalid --from date format. Use ISO8601 (e.g., 2026-02-01T00:00:00Z).").toJSON())
            throw ExitCode.failure
        }
        guard let endDate = ISO8601DateFormatter().date(from: to) else {
            print(JSONOutput.error("Invalid --to date format. Use ISO8601 (e.g., 2026-02-07T23:59:59Z).").toJSON())
            throw ExitCode.failure
        }

        let result = manager.listEvents(calendarID: calendar, from: startDate, to: endDate)
        print(result.toJSON())
    }
}

struct ListReminders: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "List reminders in a reminder list."
    )

    @Option(name: .long, help: "The reminder list ID.")
    var list: String

    @Option(name: .long, help: "Filter by completion status (true/false).")
    var completed: Bool?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.listReminders(listID: list, completed: completed)
        print(result.toJSON())
    }
}

// MARK: - Show Commands

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show details of a specific item.",
        subcommands: [ShowEvent.self, ShowReminder.self]
    )
}

struct ShowEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Show details of a specific event."
    )

    @Argument(help: "The event ID to show.")
    var eventID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.showEvent(eventID: eventID)
        print(result.toJSON())
    }
}

struct ShowReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Show details of a specific reminder."
    )

    @Argument(help: "The reminder ID to show.")
    var reminderID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.showReminder(reminderID: reminderID)
        print(result.toJSON())
    }
}

// MARK: - Add Commands

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a new event or reminder.",
        subcommands: [AddEvent.self, AddReminder.self]
    )
}

struct AddEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Create a new calendar event."
    )

    @Option(name: .long, help: "The calendar ID to add the event to.")
    var calendar: String

    @Option(name: .long, help: "The event title.")
    var title: String

    @Option(name: .long, help: "Start date in ISO8601 format.")
    var start: String

    @Option(name: .long, help: "End date in ISO8601 format.")
    var end: String

    @Option(name: .long, help: "Optional location.")
    var location: String?

    @Option(name: .long, help: "Optional notes.")
    var notes: String?

    @Flag(name: .long, help: "Mark as all-day event.")
    var allDay: Bool = false

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        guard let startDate = ISO8601DateFormatter().date(from: start) else {
            print(JSONOutput.error("Invalid --start date format. Use ISO8601.").toJSON())
            throw ExitCode.failure
        }
        guard let endDate = ISO8601DateFormatter().date(from: end) else {
            print(JSONOutput.error("Invalid --end date format. Use ISO8601.").toJSON())
            throw ExitCode.failure
        }

        let result = manager.addEvent(
            calendarID: calendar,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            allDay: allDay
        )
        print(result.toJSON())
    }
}

struct AddReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Create a new reminder."
    )

    @Option(name: .long, help: "The reminder list ID.")
    var list: String

    @Option(name: .long, help: "The reminder title.")
    var title: String

    @Option(name: .long, help: "Optional due date in ISO8601 format.")
    var due: String?

    @Option(name: .long, help: "Priority (0=none, 1=high, 5=medium, 9=low).")
    var priority: Int?

    @Option(name: .long, help: "Optional notes.")
    var notes: String?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        var dueDate: Date?
        if let due = due {
            guard let parsed = ISO8601DateFormatter().date(from: due) else {
                print(JSONOutput.error("Invalid --due date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            dueDate = parsed
        }

        let result = manager.addReminder(
            listID: list,
            title: title,
            dueDate: dueDate,
            priority: priority ?? 0,
            notes: notes
        )
        print(result.toJSON())
    }
}

// MARK: - Delete Commands

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete an event or reminder.",
        subcommands: [DeleteEvent.self, DeleteReminder.self]
    )
}

struct DeleteEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Delete a calendar event."
    )

    @Argument(help: "The event ID to delete.")
    var eventID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.deleteEvent(eventID: eventID)
        print(result.toJSON())
    }
}

struct DeleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Delete a reminder."
    )

    @Argument(help: "The reminder ID to delete.")
    var reminderID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.deleteReminder(reminderID: reminderID)
        print(result.toJSON())
    }
}

// MARK: - Complete Command

struct Complete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark items as completed.",
        subcommands: [CompleteReminder.self]
    )
}

struct CompleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Mark a reminder as completed."
    )

    @Argument(help: "The reminder ID to complete.")
    var reminderID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.completeReminder(reminderID: reminderID)
        print(result.toJSON())
    }
}
