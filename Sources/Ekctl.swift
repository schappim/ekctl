import ArgumentParser
import EventKit
import Foundation

// MARK: - Main Command

@main
struct Ekctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ekctl",
        abstract: "A command-line tool for managing macOS Calendar events and Reminders using EventKit.",
        version: "1.3.0",
        subcommands: [List.self, Show.self, Add.self, Delete.self, Complete.self, Alias.self],
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

    @Option(name: .long, help: "The calendar ID or alias.")
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

        let calendarID = ConfigManager.resolveAlias(calendar)
        let result = manager.listEvents(calendarID: calendarID, from: startDate, to: endDate)
        print(result.toJSON())
    }
}

struct ListReminders: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "List reminders in a reminder list."
    )

    @Option(name: .long, help: "The reminder list ID or alias.")
    var list: String

    @Option(name: .long, help: "Filter by completion status (true/false).")
    var completed: Bool?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let listID = ConfigManager.resolveAlias(list)
        let result = manager.listReminders(listID: listID, completed: completed)
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

    @Option(name: .long, help: "The calendar ID or alias.")
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

    @Option(name: .long, help: "Recurrence frequency: daily, weekly, monthly, or yearly.")
    var frequency: String?

    @Option(name: .long, help: "Recurrence interval (default 1). E.g., 2 with weekly = every 2 weeks.")
    var interval: Int?

    @Option(name: .long, parsing: .unconditional, help: "Days of the week (comma-separated). Plain: mon,tue,fri. With week number: 1mon (first Monday), -1fri (last Friday).")
    var daysOfTheWeek: String?

    @Option(name: .long, parsing: .unconditional, help: "Days of the month (comma-separated, 1-31 or negative from end: -1 = last day).")
    var daysOfTheMonth: String?

    @Option(name: .long, help: "Months of the year (comma-separated, 1-12).")
    var monthsOfTheYear: String?

    @Option(name: .long, parsing: .unconditional, help: "Weeks of the year (comma-separated, 1-53 or negative from end).")
    var weeksOfTheYear: String?

    @Option(name: .long, parsing: .unconditional, help: "Days of the year (comma-separated, 1-366 or negative from end).")
    var daysOfTheYear: String?

    @Option(name: .long, parsing: .unconditional, help: "Set positions to filter expanded rules (comma-separated, e.g., 1,-1).")
    var setPositions: String?

    @Option(name: .long, help: "End recurrence after this date (ISO8601 format).")
    var recurrenceEndDate: String?

    @Option(name: .long, help: "End recurrence after this many occurrences.")
    var recurrenceCount: Int?

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

        var parsedRecurrenceEndDate: Date?
        if let recurrenceEndDate = recurrenceEndDate {
            guard let parsed = ISO8601DateFormatter().date(from: recurrenceEndDate) else {
                print(JSONOutput.error("Invalid --recurrence-end-date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            parsedRecurrenceEndDate = parsed
        }

        let calendarID = ConfigManager.resolveAlias(calendar)
        let result = manager.addEvent(
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            allDay: allDay,
            frequency: frequency,
            interval: interval ?? 1,
            daysOfTheWeek: daysOfTheWeek,
            daysOfTheMonth: daysOfTheMonth,
            monthsOfTheYear: monthsOfTheYear,
            weeksOfTheYear: weeksOfTheYear,
            daysOfTheYear: daysOfTheYear,
            setPositions: setPositions,
            recurrenceEndDate: parsedRecurrenceEndDate,
            recurrenceCount: recurrenceCount
        )
        print(result.toJSON())
    }
}

struct AddReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Create a new reminder."
    )

    @Option(name: .long, help: "The reminder list ID or alias.")
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

        let listID = ConfigManager.resolveAlias(list)
        let result = manager.addReminder(
            listID: listID,
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

// MARK: - Alias Commands

struct Alias: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage calendar and reminder list aliases.",
        subcommands: [AliasSet.self, AliasRemove.self, AliasList.self]
    )
}

struct AliasSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Create or update an alias for a calendar or reminder list."
    )

    @Argument(help: "The alias name (e.g., 'work', 'personal', 'groceries').")
    var name: String

    @Argument(help: "The calendar or reminder list ID.")
    var id: String

    func run() throws {
        do {
            try ConfigManager.setAlias(name: name, id: id)
            print(JSONOutput.success([
                "status": "success",
                "message": "Alias '\(name)' set successfully",
                "alias": [
                    "name": name,
                    "id": id
                ]
            ]).toJSON())
        } catch {
            print(JSONOutput.error("Failed to save alias: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }
    }
}

struct AliasRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an alias."
    )

    @Argument(help: "The alias name to remove.")
    var name: String

    func run() throws {
        do {
            let removed = try ConfigManager.removeAlias(name: name)
            if removed {
                print(JSONOutput.success([
                    "status": "success",
                    "message": "Alias '\(name)' removed successfully"
                ]).toJSON())
            } else {
                print(JSONOutput.error("Alias '\(name)' not found").toJSON())
                throw ExitCode.failure
            }
        } catch let error where !(error is ExitCode) {
            print(JSONOutput.error("Failed to remove alias: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }
    }
}

struct AliasList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured aliases."
    )

    func run() throws {
        let aliases = ConfigManager.getAliases()
        var aliasList: [[String: String]] = []

        for (name, id) in aliases.sorted(by: { $0.key < $1.key }) {
            aliasList.append(["name": name, "id": id])
        }

        print(JSONOutput.success([
            "aliases": aliasList,
            "count": aliasList.count,
            "configPath": ConfigManager.configPath()
        ]).toJSON())
    }
}
