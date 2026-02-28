import ArgumentParser
import EventKit
import Foundation
import ekctlCore

// MARK: - Main Command

@main
struct Ekctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ekctl",
        abstract:
            "A command-line tool for managing macOS Calendar events and Reminders using EventKit.",
        version: "1.3.0",
        subcommands: [
            List.self, Show.self, Add.self, Update.self, Delete.self, Complete.self, Alias.self,
            CalendarCmd.self,
        ],
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
            print(
                JSONOutput.error(
                    "Invalid --from date format. Use ISO8601 (e.g., 2026-02-01T00:00:00Z)."
                ).toJSON())
            throw ExitCode.failure
        }
        guard let endDate = ISO8601DateFormatter().date(from: to) else {
            print(
                JSONOutput.error(
                    "Invalid --to date format. Use ISO8601 (e.g., 2026-02-07T23:59:59Z)."
                ).toJSON())
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

    // MARK: - Recurrence & Travel Time

    @Option(name: .long, help: "Recurrence frequency (daily, weekly, monthly).")
    var recurrenceFrequency: String?

    @Option(name: .long, help: "Recurrence interval (default: 1).")
    var recurrenceInterval: String?

    @Option(name: .long, help: "Recurrence end count.")
    var recurrenceEndCount: String?

    @Option(name: .long, help: "Recurrence end date in ISO8601 format.")
    var recurrenceEndDate: String?

    @Option(
        name: .long,
        help: "Days of week (e.g., 'mon,tue', '1mon' for 1st Monday, '-1fri' for last Friday).")
    var recurrenceDays: String?

    @Option(name: .long, help: "Months of the year (comma-separated: 1-12 or jan,feb...).")
    var recurrenceMonths: String?

    @Option(name: .long, help: "Days of the month (comma-separated: 1-31 or -1 for last).")
    var recurrenceDaysOfMonth: String?

    @Option(name: .long, help: "Weeks of the year (comma-separated: 1-53 or -1 for last).")
    var recurrenceWeeksOfYear: String?

    @Option(name: .long, help: "Days of the year (comma-separated: 1-366 or -1 for last).")
    var recurrenceDaysOfYear: String?

    @Option(name: .long, help: "Set positions (comma-separated: 1 for 1st, -1 for last, etc.).")
    var recurrenceSetPositions: String?

    @Option(name: .long, help: "Travel time in minutes.")
    var travelTime: String?

    // MARK: - New Features (Alarms, Availability, URL, etc.)

    @Option(
        name: .long,
        help:
            "Alarms in minutes. Positive numbers mean minutes before (e.g., 10). Prefix '+' for minutes after (e.g., +10). Negative numbers are accepted."
    )
    var alarms: String?

    @Option(name: .long, help: "URL for the event.")
    var url: String?

    @Option(name: .long, help: "Availability (busy, free, tentative, unavailable).")
    var availability: String?

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

        var rEndDate: Date?
        if let recEndDateString = recurrenceEndDate, !recEndDateString.isEmpty {
            guard let date = ISO8601DateFormatter().date(from: recEndDateString) else {
                print(
                    JSONOutput.error("Invalid --recurrence-end-date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            rEndDate = date
        }

        // Parse recurrence interval (default to 1)
        let recurrenceIntervalInt = (recurrenceInterval.flatMap(Int.init)) ?? 1

        let recurrenceEndCountInt = recurrenceEndCount.flatMap(Int.init)

        // Convert travel time to seconds if provided and valid
        var travelTimeSeconds: TimeInterval?
        if let ttString = travelTime, let ttInt = Int(ttString) {
            travelTimeSeconds = TimeInterval(ttInt * 60)
        }

        // Helper to parse comma-separated integers
        func parseInts(_ string: String?) -> [NSNumber]? {
            guard let string = string else { return nil }
            return string.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces)).map { NSNumber(value: $0) }
            }
        }

        // Helper to parse months (names or numbers)
        func parseMonths(_ string: String?) -> [NSNumber]? {
            guard let string = string else { return nil }
            let monthMap: [String: Int] = [
                "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
                "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6,
                "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "september": 9,
                "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
            ]

            return string.split(separator: ",").compactMap { component in
                let trimmed = component.trimmingCharacters(in: .whitespaces).lowercased()
                if let val = Int(trimmed) { return NSNumber(value: val) }
                if let val = monthMap[trimmed] { return NSNumber(value: val) }
                return nil
            }
        }

        func parseAlarms(_ string: String?) -> [Double]? {
            guard let string = string else { return nil }
            return string.split(separator: ",").compactMap { component in
                let s = component.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("+") {
                    if let val = Double(s.dropFirst()) { return val * 60 }
                    return nil
                }
                guard let val = Double(s) else { return nil }
                if val < 0 {
                    return val * 60
                } else {
                    return -val * 60
                }
            }
        }

        let alarmsList = parseAlarms(alarms)

        let calendarID = ConfigManager.resolveAlias(calendar)
        let result = manager.addEvent(
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            allDay: allDay,
            recurrenceFrequency: recurrenceFrequency,
            recurrenceInterval: recurrenceIntervalInt,
            recurrenceEndCount: recurrenceEndCountInt,
            recurrenceEndDate: rEndDate,
            recurrenceDays: recurrenceDays,
            recurrenceMonths: parseMonths(recurrenceMonths),
            recurrenceDaysOfMonth: parseInts(recurrenceDaysOfMonth),
            recurrenceWeeksOfYear: parseInts(recurrenceWeeksOfYear),
            recurrenceDaysOfYear: parseInts(recurrenceDaysOfYear),
            recurrenceSetPositions: parseInts(recurrenceSetPositions),
            travelTime: travelTimeSeconds,
            alarms: alarmsList,
            url: url,
            availability: availability
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
    var priority: String?

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

        // Parse priority: require an integer when provided, else error
        var priorityInt: Int = 0
        if let priority = priority {
            if let p = Int(priority) {
                priorityInt = p
            } else {
                print(
                    JSONOutput.error(
                        "Invalid --priority value. Must be an integer (e.g., 0,1,5,9). Please use numeric priorities."
                    ).toJSON())
                throw ExitCode.failure
            }
        }

        let listID = ConfigManager.resolveAlias(list)
        let result = manager.addReminder(
            listID: listID,
            title: title,
            dueDate: dueDate,
            priority: priorityInt,
            notes: notes
        )
        print(result.toJSON())
    }
}

// MARK: - Update Command

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Update an existing event or reminder.",
        subcommands: [UpdateEvent.self, UpdateReminder.self]
    )
}

struct UpdateEvent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Update a calendar event."
    )

    @Argument(help: "The event ID to update.")
    var eventID: String

    @Option(name: .long, help: "New title.")
    var title: String?

    @Option(name: .long, help: "New start date (ISO8601).")
    var start: String?

    @Option(name: .long, help: "New end date (ISO8601).")
    var end: String?

    @Option(name: .long, help: "New location.")
    var location: String?

    @Option(name: .long, help: "New notes.")
    var notes: String?

    @Option(name: .long, help: "Mark as all-day event (true/false).")
    var allDay: Bool?

    @Option(name: .long, help: "New URL.")
    var url: String?

    @Option(name: .long, help: "New availability (busy, free, tentative, unavailable).")
    var availability: String?

    @Option(name: .long, help: "Travel time in minutes.")
    var travelTime: String?

    @Option(name: .long, help: "Alarms relative to start (minutes). Replaces existing alarms.")
    var alarms: String?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()

        var startDate: Date?
        if let start = start {
            guard let da = ISO8601DateFormatter().date(from: start) else {
                print(JSONOutput.error("Invalid --start date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            startDate = da
        }
        var endDate: Date?
        if let end = end {
            guard let da = ISO8601DateFormatter().date(from: end) else {
                print(JSONOutput.error("Invalid --end date format. Use ISO8601.").toJSON())
                throw ExitCode.failure
            }
            endDate = da
        }

        func parseAlarms(_ string: String?) -> [Double]? {
            guard let string = string else { return nil }
            return string.split(separator: ",").compactMap { component in
                let s = component.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("+") {
                    if let val = Double(s.dropFirst()) { return val * 60 }
                    return nil
                }
                guard let val = Double(s) else { return nil }
                if val < 0 {
                    return val * 60
                } else {
                    return -val * 60
                }
            }
        }

        let alarmsList = parseAlarms(alarms)

        var travelTimeSeconds: TimeInterval?
        if let ttString = travelTime, let ttInt = Int(ttString) {
            travelTimeSeconds = TimeInterval(ttInt * 60)
        }

        let result = manager.updateEvent(
            eventID: eventID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            allDay: allDay,
            url: url,
            availability: availability,
            travelTime: travelTimeSeconds,
            alarms: alarmsList
        )
        print(result.toJSON())
    }
}

struct UpdateReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Update an existing reminder."
    )

    @Argument(help: "The reminder ID to update.")
    var reminderID: String

    @Option(name: .long, help: "New title.")
    var title: String?

    @Option(name: .long, help: "New due date (ISO8601).")
    var due: String?

    @Option(name: .long, help: "New priority (0=none, 1=high, 5=medium, 9=low).")
    var priority: String?

    @Option(name: .long, help: "New notes.")
    var notes: String?

    @Option(name: .long, help: "Mark as completed (true/false).")
    var completed: Bool?

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

        var priorityInt: Int?
        if let priority = priority {
            guard let p = Int(priority) else {
                print(
                    JSONOutput.error(
                        "Invalid --priority value. Must be an integer (0, 1, 5, or 9)."
                    ).toJSON())
                throw ExitCode.failure
            }
            priorityInt = p
        }

        let result = manager.updateReminder(
            reminderID: reminderID,
            title: title,
            dueDate: dueDate,
            priority: priorityInt,
            notes: notes,
            completed: completed
        )
        print(result.toJSON())
    }
}

// MARK: - Calendar Managment Commands

struct CalendarCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Manage calendars.",
        subcommands: [CreateCalendar.self, UpdateCalendar.self, DeleteCalendar.self]
    )
}

struct CreateCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new calendar."
    )

    @Option(name: .long, help: "Title of the new calendar.")
    var title: String

    @Option(name: .long, help: "Color hex code (e.g. #FF0000).")
    var color: String?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let result = manager.createCalendar(title: title, color: color)
        print(result.toJSON())
    }
}

struct UpdateCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a calendar."
    )

    @Argument(help: "Calendar ID to update.")
    var calendarID: String

    @Option(name: .long, help: "New title.")
    var title: String?

    @Option(name: .long, help: "New color hex code.")
    var color: String?

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        let resolvedID = ConfigManager.resolveAlias(calendarID)
        let result = manager.updateCalendar(calendarID: resolvedID, title: title, color: color)
        print(result.toJSON())
    }
}

struct DeleteCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a calendar."
    )

    @Argument(help: "Calendar ID to delete.")
    var calendarID: String

    func run() throws {
        let manager = EventKitManager()
        try manager.requestAccess()
        // Resolve alias if needed
        let resolvedID = ConfigManager.resolveAlias(calendarID)
        let result = manager.deleteCalendar(calendarID: resolvedID)
        print(result.toJSON())
    }
}

// MARK: - Helper Methods

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
            print(
                JSONOutput.success([
                    "status": "success",
                    "message": "Alias '\(name)' set successfully",
                    "alias": [
                        "name": name,
                        "id": id,
                    ],
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
                print(
                    JSONOutput.success([
                        "status": "success",
                        "message": "Alias '\(name)' removed successfully",
                    ]).toJSON())
            } else {
                print(JSONOutput.error("Alias '\(name)' not found").toJSON())
                throw ExitCode.failure
            }
        } catch let error where !(error is ExitCode) {
            print(
                JSONOutput.error("Failed to remove alias: \(error.localizedDescription)").toJSON())
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

        print(
            JSONOutput.success([
                "aliases": aliasList,
                "count": aliasList.count,
                "configPath": ConfigManager.configPath(),
            ]).toJSON())
    }
}
