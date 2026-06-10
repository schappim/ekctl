import ArgumentParser
import EventKit
import Foundation
import ekctlCore

// MARK: - Shared Option Parsing

/// Parses a date-flag value via the shared `DateParsing` rules, printing the
/// standard error payload in the requested output format and failing the
/// command if the value is unparseable. `flag` names the offending option in
/// the message (e.g., "--from").
private func parseDateOption(_ value: String, flag: String, format: OutputFormat) throws -> Date {
    guard let date = DateParsing.parse(value) else {
        print(
            JSONOutput.error("Invalid \(flag) date format. Use \(DateParsing.acceptedFormats).")
                .format(format))
        throw ExitCode.failure
    }
    return date
}

// MARK: - Main Command

@main
struct Ekctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ekctl",
        abstract:
            "A command-line tool for managing macOS Calendar events and Reminders using EventKit.",
        version: "1.4.0",
        subcommands: [
            List.self, Show.self, Add.self, Update.self, Delete.self, Complete.self, Alias.self,
            CalendarCmd.self,
            Today.self, Tomorrow.self, Next.self,
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.listCalendars()
        print(result.format(outputFormat.format))
    }
}

struct ListEvents: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events in a calendar within a date range."
    )

    @Option(
        name: .long,
        help:
            "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal). Each event's source calendar is reported in its JSON output."
    )
    var calendar: String

    @Option(name: .long, help: "Start date in \(DateParsing.acceptedFormats).")
    var from: String

    @Option(name: .long, help: "End date in \(DateParsing.acceptedFormats).")
    var to: String

    @Option(
        name: .long,
        help: "Case-insensitive substring filter applied across title, location, and notes."
    )
    var search: String?

    @Option(
        name: .long,
        help: "Filter events by EventKit availability (busy, free, tentative, unavailable, notSupported)."
    )
    var availability: AvailabilityFilter?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        let startDate = try parseDateOption(from, flag: "--from", format: outputFormat.format)
        let endDate = try parseDateOption(to, flag: "--to", format: outputFormat.format)

        let calendarIDs = ConfigManager.resolveCalendarIDs(calendar)

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: startDate,
            to: endDate,
            search: search,
            availability: availability)
        print(result.format(outputFormat.format))
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

    @Option(
        name: .long,
        help: "Case-insensitive substring filter applied across title and notes."
    )
    var search: String?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let listID = ConfigManager.resolveAlias(list)
        let result = manager.listReminders(listID: listID, completed: completed, search: search)
        print(result.format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.showEvent(eventID: eventID)
        print(result.format(outputFormat.format))
    }
}

struct ShowReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Show details of a specific reminder."
    )

    @Argument(help: "The reminder ID to show.")
    var reminderID: String

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.showReminder(reminderID: reminderID)
        print(result.format(outputFormat.format))
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

    @Option(name: .long, help: "Start date in \(DateParsing.acceptedFormats).")
    var start: String

    @Option(name: .long, help: "End date in \(DateParsing.acceptedFormats).")
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

    @Option(name: .long, help: "Recurrence end date in \(DateParsing.acceptedFormats).")
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
    var availability: AvailabilitySetting?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        let startDate = try parseDateOption(start, flag: "--start", format: outputFormat.format)
        let endDate = try parseDateOption(end, flag: "--end", format: outputFormat.format)

        var rEndDate: Date?
        if let recEndDateString = recurrenceEndDate, !recEndDateString.isEmpty {
            rEndDate = try parseDateOption(
                recEndDateString, flag: "--recurrence-end-date", format: outputFormat.format)
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

        let alarmsList = AlarmParsing.parse(alarms)

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
        print(result.format(outputFormat.format))
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

    @Option(name: .long, help: "Optional due date in \(DateParsing.acceptedFormats).")
    var due: String?

    @Option(name: .long, help: "Priority (0=none, 1=high, 5=medium, 9=low).")
    var priority: String?

    @Option(name: .long, help: "Optional notes.")
    var notes: String?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        var dueDate: Date?
        if let due = due {
            dueDate = try parseDateOption(due, flag: "--due", format: outputFormat.format)
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
                    ).format(outputFormat.format))
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
        print(result.format(outputFormat.format))
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

    @Option(name: .long, help: "New start date in \(DateParsing.acceptedFormats).")
    var start: String?

    @Option(name: .long, help: "New end date in \(DateParsing.acceptedFormats).")
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
    var availability: AvailabilitySetting?

    @Option(name: .long, help: "Travel time in minutes.")
    var travelTime: String?

    @Option(name: .long, help: "Alarms relative to start (minutes). Replaces existing alarms.")
    var alarms: String?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        var startDate: Date?
        if let start = start {
            startDate = try parseDateOption(start, flag: "--start", format: outputFormat.format)
        }
        var endDate: Date?
        if let end = end {
            endDate = try parseDateOption(end, flag: "--end", format: outputFormat.format)
        }

        let alarmsList = AlarmParsing.parse(alarms)

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
        print(result.format(outputFormat.format))
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

    @Option(name: .long, help: "New due date in \(DateParsing.acceptedFormats).")
    var due: String?

    @Option(name: .long, help: "New priority (0=none, 1=high, 5=medium, 9=low).")
    var priority: String?

    @Option(name: .long, help: "New notes.")
    var notes: String?

    @Option(name: .long, help: "Mark as completed (true/false).")
    var completed: Bool?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        var dueDate: Date?
        if let due = due {
            dueDate = try parseDateOption(due, flag: "--due", format: outputFormat.format)
        }

        var priorityInt: Int?
        if let priority = priority {
            guard let p = Int(priority) else {
                print(
                    JSONOutput.error(
                        "Invalid --priority value. Must be an integer (0, 1, 5, or 9)."
                    ).format(outputFormat.format))
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
        print(result.format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.createCalendar(title: title, color: color)
        print(result.format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let resolvedID = ConfigManager.resolveAlias(calendarID)
        let result = manager.updateCalendar(calendarID: resolvedID, title: title, color: color)
        print(result.format(outputFormat.format))
    }
}

struct DeleteCalendar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a calendar."
    )

    @Argument(help: "Calendar ID to delete.")
    var calendarID: String

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        // Resolve alias if needed
        let resolvedID = ConfigManager.resolveAlias(calendarID)
        let result = manager.deleteCalendar(calendarID: resolvedID)
        print(result.format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.deleteEvent(eventID: eventID)
        print(result.format(outputFormat.format))
    }
}

struct DeleteReminder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminder",
        abstract: "Delete a reminder."
    )

    @Argument(help: "The reminder ID to delete.")
    var reminderID: String

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.deleteReminder(reminderID: reminderID)
        print(result.format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()
        let result = manager.completeReminder(reminderID: reminderID)
        print(result.format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

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
                ]).format(outputFormat.format))
        } catch {
            print(JSONOutput.error("Failed to save alias: \(error.localizedDescription)").format(outputFormat.format))
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

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        do {
            let removed = try ConfigManager.removeAlias(name: name)
            if removed {
                print(
                    JSONOutput.success([
                        "status": "success",
                        "message": "Alias '\(name)' removed successfully",
                    ]).format(outputFormat.format))
            } else {
                print(JSONOutput.error("Alias '\(name)' not found").format(outputFormat.format))
                throw ExitCode.failure
            }
        } catch let error where !(error is ExitCode) {
            print(
                JSONOutput.error("Failed to remove alias: \(error.localizedDescription)").format(outputFormat.format))
            throw ExitCode.failure
        }
    }
}

struct AliasList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all configured aliases."
    )

    @OptionGroup var outputFormat: OutputFormatOptions

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
            ]).format(outputFormat.format))
    }
}

// MARK: - Quick Date-Range Commands
//
// Convenience subcommands that wrap `list events` with a pre-computed local
// date range, removing the BSD-only `date -v+1d …` prelude that every script
// otherwise needs. All three accept the same filter/format flags as
// `list events`, so they compose cleanly with `--search`, `--availability`,
// and `--format`.

struct Today: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "today",
        abstract: "List events occurring today (local time)."
    )

    @Option(
        name: .long,
        help: "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal)."
    )
    var calendar: String

    @Option(
        name: .long,
        help: "Case-insensitive substring filter applied across title, location, and notes."
    )
    var search: String?

    @Option(
        name: .long,
        help: "Filter events by EventKit availability (busy, free, tentative, unavailable, notSupported)."
    )
    var availability: AvailabilityFilter?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        let (start, end) = DateRanges.today()
        let calendarIDs = ConfigManager.resolveCalendarIDs(calendar)

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: start,
            to: end,
            search: search,
            availability: availability)
        print(result.format(outputFormat.format))
    }
}

struct Tomorrow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tomorrow",
        abstract: "List events occurring tomorrow (local time)."
    )

    @Option(
        name: .long,
        help: "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal)."
    )
    var calendar: String

    @Option(
        name: .long,
        help: "Case-insensitive substring filter applied across title, location, and notes."
    )
    var search: String?

    @Option(
        name: .long,
        help: "Filter events by EventKit availability (busy, free, tentative, unavailable, notSupported)."
    )
    var availability: AvailabilityFilter?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        let (start, end) = DateRanges.tomorrow()
        let calendarIDs = ConfigManager.resolveCalendarIDs(calendar)

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: start,
            to: end,
            search: search,
            availability: availability)
        print(result.format(outputFormat.format))
    }
}

struct Next: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next",
        abstract: "Show upcoming events from now, sorted by start time."
    )

    @Option(
        name: .long,
        help: "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal)."
    )
    var calendar: String

    @Option(
        name: .long,
        help: "Number of upcoming events to return (default: 1)."
    )
    var count: Int = 1

    @Option(
        name: .long,
        help: "Lookahead window in days. Events further out than this are ignored (default: 90)."
    )
    var days: Int = 90

    @Option(
        name: .long,
        help: "Case-insensitive substring filter applied across title, location, and notes."
    )
    var search: String?

    @Option(
        name: .long,
        help: "Filter events by EventKit availability (busy, free, tentative, unavailable, notSupported)."
    )
    var availability: AvailabilityFilter?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess()

        guard count > 0 else {
            print(JSONOutput.error("--count must be a positive integer.").format(outputFormat.format))
            throw ExitCode.failure
        }
        guard days > 0 else {
            print(JSONOutput.error("--days must be a positive integer.").format(outputFormat.format))
            throw ExitCode.failure
        }

        let (start, end) = DateRanges.nextWindow(days: days)
        let calendarIDs = ConfigManager.resolveCalendarIDs(calendar)

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: start,
            to: end,
            search: search,
            availability: availability,
            sortedByStartAscending: true,
            limit: count)
        print(result.format(outputFormat.format))
    }
}
