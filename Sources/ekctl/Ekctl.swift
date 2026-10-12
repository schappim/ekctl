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
        // Echo what was rejected — a script that built the value from a
        // variable can't otherwise tell what reached the flag. A bare number is
        // turned away on purpose, so explain that here rather than only in the
        // README, which is not where the user is standing.
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let hint = !trimmed.isEmpty && trimmed.allSatisfy(\.isNumber)
            ? " A bare number is ambiguous — write a time as 9am or 09:00, "
                + "or a date as 2026-02-09."
            : ""
        print(
            JSONOutput.error(
                "Invalid \(flag) date format. Got \"\(value)\".\(hint) "
                    + "Use \(DateParsing.acceptedFormats).")
                .format(format))
        throw ExitCode.failure
    }
    return date
}

/// Prints a command's result and, if it's an error, fails the command, so
/// the exit code agrees with the `status` in the output.
private func emit(_ result: JSONOutput, format: OutputFormat) throws {
    print(result.format(format))
    if result.isError { throw ExitCode.failure }
}

/// Parses an alarm-list flag via `AlarmParsing`, printing the standard error
/// payload in the requested output format and failing the command if any
/// entry is invalid. `flag` names the offending option in the message.
private func parseAlarmsOption(_ value: String?, flag: String, format: OutputFormat) throws -> [Double]? {
    do {
        return try AlarmParsing.parse(value)
    } catch {
        print(JSONOutput.error("Invalid \(flag) value. \(error)").format(format))
        throw ExitCode.failure
    }
}

/// `--travel-time` in whole minutes, as seconds for EventKit. Garbage used to
/// be dropped without a word, leaving the user to discover later that the
/// travel time they asked for was never set.
private func parseTravelTimeOption(_ value: String?, format: OutputFormat) throws -> TimeInterval? {
    guard let value = value else { return nil }
    guard let minutes = Int(value.trimmingCharacters(in: .whitespaces)), (0...1440).contains(minutes) else {
        print(
            JSONOutput.error(
                "Invalid --travel-time value. Got \"\(value)\". Use whole minutes from 0 to 1440, e.g. 30.")
                .format(format))
        throw ExitCode.failure
    }
    return TimeInterval(minutes * 60)
}

/// `--color` as a hex colour, checked before anything is created or changed.
/// An unreadable value used to be ignored, so `calendar create --color
/// garbage` made a calendar in the default colour and reported success.
private func parseColorOption(_ value: String?, format: OutputFormat) throws -> String? {
    guard let value = value else { return nil }
    let hex = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
    guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
        print(
            JSONOutput.error("Invalid --color value. Got \"\(value)\". Use a hex colour such as #FF5500.")
                .format(format))
        throw ExitCode.failure
    }
    return value
}

/// Resolves an optional `--calendar` selection. Omitted means every event
/// calendar (nil). Given but naming nothing — an unset shell variable, say —
/// is an error rather than quietly widening to every calendar.
private func parseCalendarSelection(_ value: String?, format: OutputFormat) throws -> [String]? {
    guard let value = value else { return nil }
    // A blank entry inside a list ("work,$UNSET") stays in as an unfindable
    // ID so it fails loudly, as in `free`; see `resolveCalendarIDs`.
    let ids = ConfigManager.resolveCalendarIDs(value)
    guard !ids.isEmpty else {
        print(
            JSONOutput.error(
                "--calendar was given but names no calendar. Omit it to use every calendar, "
                    + "or pass an ID or alias.")
                .format(format))
        throw ExitCode.failure
    }
    return ids
}

/// The `--recurrence-*` flags shared by `add event` and `update event`.
struct RecurrenceOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Recurrence frequency (\(RecurrenceParsing.frequencyValues)). On update, 'none' removes the recurrence.")
    var recurrenceFrequency: String?

    @Option(name: .long, help: "Recurrence interval, e.g. 2 for every other week (default: 1).")
    var recurrenceInterval: String?

    @Option(name: .long, help: "End the recurrence after this many occurrences.")
    var recurrenceEndCount: String?

    @Option(
        name: .long,
        help: "End the recurrence on this date, in \(DateParsing.acceptedFormats). On update, 'none' makes it open-ended.")
    var recurrenceEndDate: String?

    // `.unconditional` on the lists that take negative values: without it a
    // value such as `-1fri` looks like a flag and has to be written
    // `--recurrence-days=-1fri`.
    @Option(
        name: .long, parsing: .unconditional,
        help: "Days of week (e.g., 'mon,tue', '1mon' for 1st Monday, '-1fri' for last Friday).")
    var recurrenceDays: String?

    @Option(name: .long, help: "Months of the year (comma-separated: 1-12 or jan,feb...).")
    var recurrenceMonths: String?

    @Option(name: .long, parsing: .unconditional, help: "Days of the month (comma-separated: 1-31 or -1 for last).")
    var recurrenceDaysOfMonth: String?

    @Option(name: .long, parsing: .unconditional, help: "Weeks of the year (comma-separated: 1-53 or -1 for last).")
    var recurrenceWeeksOfYear: String?

    @Option(name: .long, parsing: .unconditional, help: "Days of the year (comma-separated: 1-366 or -1 for last).")
    var recurrenceDaysOfYear: String?

    @Option(name: .long, parsing: .unconditional, help: "Set positions (comma-separated: 1 for 1st, -1 for last, etc.).")
    var recurrenceSetPositions: String?

    /// Parses and validates the flags, printing the error and failing the
    /// command on bad input — before the permission prompt, like dates.
    func spec(forUpdate: Bool, format: OutputFormat) throws -> RecurrenceSpec {
        func fail(_ message: String) -> Error {
            print(JSONOutput.error(message).format(format))
            return ExitCode.failure
        }
        // An empty value is the flag left unset, as it always was on `add
        // event`: scripts pass "$VAR" whether or not it's set.
        func given(_ value: String?) -> String? {
            guard let value = value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        var endDate: Date?
        var clearEndDate = false
        if let value = given(recurrenceEndDate) {
            if forUpdate && value.trimmingCharacters(in: .whitespaces).lowercased() == "none" {
                clearEndDate = true
            } else {
                endDate = try parseDateOption(value, flag: "--recurrence-end-date", format: format)
                // EventKit ends a series at an instant, so a bare date (local
                // midnight) would leave that day's occurrence out. "Ends on
                // 1 December" includes 1 December, as in Calendar.
                if let date = endDate, Calendar.current.startOfDay(for: date) == date {
                    endDate = Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: date)
                }
            }
        }
        let spec: RecurrenceSpec
        do {
            spec = try RecurrenceParsing.parse(
                frequency: given(recurrenceFrequency),
                interval: given(recurrenceInterval),
                endCount: given(recurrenceEndCount),
                endDate: endDate,
                clearEndDate: clearEndDate,
                days: given(recurrenceDays),
                months: given(recurrenceMonths),
                daysOfMonth: given(recurrenceDaysOfMonth),
                weeksOfYear: given(recurrenceWeeksOfYear),
                daysOfYear: given(recurrenceDaysOfYear),
                setPositions: given(recurrenceSetPositions),
                allowNone: forUpdate)
        } catch {
            throw fail("\(error)")
        }
        // A new event has no rule for these to modify, so they need a
        // frequency; an update may be adjusting the event's existing rule,
        // which only the store can tell us about.
        if !forUpdate && spec.frequency == nil && spec.hasRuleDetails {
            throw fail("--recurrence-* flags need --recurrence-frequency to say how often the event repeats.")
        }
        if spec.frequency != nil {
            do { try spec.validate(against: spec) } catch { throw fail("\(error)") }
        }
        return spec
    }
}

/// `--occurrence`, which picks one occurrence of a recurring series.
private func parseOccurrenceOption(_ value: String?, format: OutputFormat) throws -> Date? {
    try value.map { try parseDateOption($0, flag: "--occurrence", format: format) }
}

private let occurrenceHelp: ArgumentHelp = """
    For a recurring event, which occurrence: its start time (the startDate shown by list events) \
    or its occurrenceDate. Every occurrence shares one ID.
    """

private let spanHelp: ArgumentHelp = """
    For a recurring event: this (just the occurrence), future (it and every later one), or all \
    (the whole series).
    """

// MARK: - Main Command

@main
struct Ekctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ekctl",
        abstract:
            "A command-line tool for managing macOS Calendar events and Reminders using EventKit.",
        version: "1.8.0",
        subcommands: [
            List.self, Show.self, Add.self, Update.self, Delete.self, Complete.self, Alias.self,
            CalendarCmd.self,
            Today.self, Tomorrow.self, Next.self, Free.self,
            InitCommand.self,
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
        try manager.requestAccess(.all, format: outputFormat.format)
        let result = manager.listCalendars()
        try emit(result, format: outputFormat.format)
    }
}

struct ListEvents: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List events within a date range (default: today and the 6 days after it)."
    )

    @Option(
        name: .long,
        help:
            "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal). Omit for every calendar. Each event's source calendar is reported in its JSON output."
    )
    var calendar: String?

    @Option(name: .long, help: "Start date in \(DateParsing.acceptedFormats). Defaults to the start of today.")
    var from: String?

    @Option(name: .long, help: "End date in \(DateParsing.acceptedFormats). Defaults to --days after the start.")
    var to: String?

    @Option(name: .long, help: "How many days to list when --to is omitted (default: 7).")
    var days: Int?

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
        // Validate arguments before triggering the TCC permission prompt.
        func fail(_ message: String) -> Error {
            print(JSONOutput.error(message).format(outputFormat.format))
            return ExitCode.failure
        }
        if let days = days {
            guard to == nil else { throw fail("Pass --to or --days, not both.") }
            // A century is far beyond any useful listing, and keeps the date
            // arithmetic clear of overflow.
            guard (1...36_500).contains(days) else { throw fail("--days must be from 1 to 36500.") }
        }
        let startDate = try from.map {
            try parseDateOption($0, flag: "--from", format: outputFormat.format)
        } ?? DateRanges.today().start
        let endDate = try to.map {
            try parseDateOption($0, flag: "--to", format: outputFormat.format)
        } ?? DateRanges.nextWindow(now: startDate, days: days ?? 7).end
        // Equal bounds are an empty range, as they always were; reversed ones
        // are a mistake worth saying so about.
        guard startDate <= endDate else { throw fail("--to is earlier than --from.") }
        let calendarIDs = try parseCalendarSelection(calendar, format: outputFormat.format)

        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: startDate,
            to: endDate,
            search: search,
            availability: availability)
        try emit(result, format: outputFormat.format)
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
        try manager.requestAccess(.reminders, format: outputFormat.format)
        let listID = ConfigManager.resolveAlias(list)
        let result = manager.listReminders(listID: listID, completed: completed, search: search)
        try emit(result, format: outputFormat.format)
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

    @Option(name: .long, help: occurrenceHelp)
    var occurrence: String?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let occurrenceDate = try parseOccurrenceOption(occurrence, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)
        let result = manager.showEvent(eventID: eventID, occurrence: occurrenceDate)
        try emit(result, format: outputFormat.format)
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
        try manager.requestAccess(.reminders, format: outputFormat.format)
        let result = manager.showReminder(reminderID: reminderID)
        try emit(result, format: outputFormat.format)
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

    @Option(name: .long, help: "The calendar ID or alias. Defaults to the calendar Calendar.app uses for new events.")
    var calendar: String?

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

    @OptionGroup var recurrence: RecurrenceOptions

    @Option(name: .long, help: "Travel time in minutes.")
    var travelTime: String?

    // MARK: - New Features (Alarms, Availability, URL, etc.)

    @Option(
        name: .long, parsing: .unconditional,
        help: "Alarms relative to the start: \(AlarmParsing.acceptedFormats)."
    )
    var alarms: String?

    @Option(name: .long, help: "URL for the event.")
    var url: String?

    @Option(name: .long, help: "Availability (busy, free, tentative, unavailable).")
    var availability: AvailabilitySetting?

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        // Validate arguments before triggering the TCC permission prompt.
        let startDate = try parseDateOption(start, flag: "--start", format: outputFormat.format)
        let endDate = try parseDateOption(end, flag: "--end", format: outputFormat.format)

        let recurrenceSpec = try recurrence.spec(forUpdate: false, format: outputFormat.format)

        let travelTimeSeconds = try parseTravelTimeOption(travelTime, format: outputFormat.format)

        let alarmsList = try parseAlarmsOption(alarms, flag: "--alarms", format: outputFormat.format)
            .map(AlarmParsing.dedupe)
        let calendarID = calendar.map(ConfigManager.resolveAlias)

        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)
        let result = manager.addEvent(
            calendarID: calendarID,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            allDay: allDay,
            recurrence: recurrenceSpec,
            travelTime: travelTimeSeconds,
            alarms: alarmsList,
            url: url,
            availability: availability
        )
        try emit(result, format: outputFormat.format)
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
        // Validate arguments before triggering the TCC permission prompt.
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

        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.reminders, format: outputFormat.format)
        let result = manager.addReminder(
            listID: listID,
            title: title,
            dueDate: dueDate,
            priority: priorityInt,
            notes: notes
        )
        try emit(result, format: outputFormat.format)
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

    @Option(name: .long, help: occurrenceHelp)
    var occurrence: String?

    @Option(name: .long, help: spanHelp)
    var span: EventSpan = .this

    @Option(
        name: .long,
        help: "Move the event to this calendar (ID or alias). A recurring series can only move as a whole: pass --span all.")
    var calendar: String?

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

    @Option(
        name: .long, parsing: .unconditional,
        help: "Alarms relative to the start, replacing any existing ones: \(AlarmParsing.acceptedFormats)."
    )
    var alarms: String?

    @Option(
        name: .long, parsing: .unconditional,
        help: "Alarms to add, keeping the existing ones (same format as --alarms). An alarm already on the event isn't added twice."
    )
    var addAlarms: String?

    @OptionGroup var recurrence: RecurrenceOptions

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        // Validate arguments before triggering the TCC permission prompt.
        let occurrenceDate = try parseOccurrenceOption(occurrence, format: outputFormat.format)
        let recurrenceSpec = try recurrence.spec(forUpdate: true, format: outputFormat.format)
        var startDate: Date?
        if let start = start {
            startDate = try parseDateOption(start, flag: "--start", format: outputFormat.format)
        }
        var endDate: Date?
        if let end = end {
            endDate = try parseDateOption(end, flag: "--end", format: outputFormat.format)
        }

        let alarmsList = try parseAlarmsOption(alarms, flag: "--alarms", format: outputFormat.format)
            .map(AlarmParsing.dedupe)
        let addAlarmsList = try parseAlarmsOption(addAlarms, flag: "--add-alarms", format: outputFormat.format)
            .map(AlarmParsing.dedupe)
        if addAlarmsList?.isEmpty == true {
            print(
                JSONOutput.error(
                    "--add-alarms needs at least one alarm to add. To remove every alarm, use --alarms none.")
                    .format(outputFormat.format))
            throw ExitCode.failure
        }
        if alarmsList != nil && addAlarmsList != nil {
            print(
                JSONOutput.error(
                    "Pass --alarms (replace every alarm) or --add-alarms (keep them and add more), not both.")
                    .format(outputFormat.format))
            throw ExitCode.failure
        }

        let travelTimeSeconds = try parseTravelTimeOption(travelTime, format: outputFormat.format)

        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)
        let result = manager.updateEvent(
            eventID: eventID,
            occurrence: occurrenceDate,
            span: span,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes,
            allDay: allDay,
            url: url,
            availability: availability,
            travelTime: travelTimeSeconds,
            alarms: alarmsList,
            addAlarms: addAlarmsList,
            calendarID: calendar.map(ConfigManager.resolveAlias),
            recurrence: recurrenceSpec
        )
        try emit(result, format: outputFormat.format)
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
        // Validate arguments before triggering the TCC permission prompt.
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

        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.reminders, format: outputFormat.format)
        let result = manager.updateReminder(
            reminderID: reminderID,
            title: title,
            dueDate: dueDate,
            priority: priorityInt,
            notes: notes,
            completed: completed
        )
        try emit(result, format: outputFormat.format)
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
        let color = try parseColorOption(color, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)
        let result = manager.createCalendar(title: title, color: color)
        try emit(result, format: outputFormat.format)
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
        let color = try parseColorOption(color, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        // .all: the ID may name an event calendar or a reminder list.
        try manager.requestAccess(.all, format: outputFormat.format)
        let resolvedID = ConfigManager.resolveAlias(calendarID)
        let result = manager.updateCalendar(calendarID: resolvedID, title: title, color: color)
        try emit(result, format: outputFormat.format)
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
        // .all: the ID may name an event calendar or a reminder list.
        try manager.requestAccess(.all, format: outputFormat.format)
        // Resolve alias if needed
        let resolvedID = ConfigManager.resolveAlias(calendarID)
        let result = manager.deleteCalendar(calendarID: resolvedID)
        try emit(result, format: outputFormat.format)
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

    @Option(name: .long, help: occurrenceHelp)
    var occurrence: String?

    @Option(name: .long, help: spanHelp)
    var span: EventSpan = .this

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        let occurrenceDate = try parseOccurrenceOption(occurrence, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)
        let result = manager.deleteEvent(eventID: eventID, occurrence: occurrenceDate, span: span)
        try emit(result, format: outputFormat.format)
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
        try manager.requestAccess(.reminders, format: outputFormat.format)
        let result = manager.deleteReminder(reminderID: reminderID)
        try emit(result, format: outputFormat.format)
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
        try manager.requestAccess(.reminders, format: outputFormat.format)
        let result = manager.completeReminder(reminderID: reminderID)
        try emit(result, format: outputFormat.format)
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
        help: "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal). Omit for every calendar."
    )
    var calendar: String?

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
        let calendarIDs = try parseCalendarSelection(calendar, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)

        let (start, end) = DateRanges.today()

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: start,
            to: end,
            search: search,
            availability: availability)
        try emit(result, format: outputFormat.format)
    }
}

struct Tomorrow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tomorrow",
        abstract: "List events occurring tomorrow (local time)."
    )

    @Option(
        name: .long,
        help: "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal). Omit for every calendar."
    )
    var calendar: String?

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
        let calendarIDs = try parseCalendarSelection(calendar, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)

        let (start, end) = DateRanges.tomorrow()

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: start,
            to: end,
            search: search,
            availability: availability)
        try emit(result, format: outputFormat.format)
    }
}

struct Next: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next",
        abstract: "Show upcoming events from now, sorted by start time."
    )

    @Option(
        name: .long,
        help: "Calendar ID or alias. Pass multiple comma-separated values to fetch events from several calendars (e.g., work,personal). Omit for every calendar."
    )
    var calendar: String?

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
        // Validate arguments before triggering the TCC permission prompt.
        guard count > 0 else {
            print(JSONOutput.error("--count must be a positive integer.").format(outputFormat.format))
            throw ExitCode.failure
        }
        guard days > 0 else {
            print(JSONOutput.error("--days must be a positive integer.").format(outputFormat.format))
            throw ExitCode.failure
        }

        let calendarIDs = try parseCalendarSelection(calendar, format: outputFormat.format)
        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)

        let (start, end) = DateRanges.nextWindow(days: days)

        let result = manager.listEvents(
            calendarIDs: calendarIDs,
            from: start,
            to: end,
            search: search,
            availability: availability,
            sortedByStartAscending: true,
            limit: count)
        try emit(result, format: outputFormat.format)
    }
}


// MARK: - Free/Busy Command

/// `ekctl free` — the inverse of `list events`: instead of what's booked, what
/// isn't. Merging busy intervals across calendars, clipping them to working
/// hours day by day, and doing it without DST errors is the one calendar
/// question a jq pipeline can't reasonably answer, so it lives here.
struct Free: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "free",
        abstract: "Find open time slots across one or more calendars.",
        discussion: """
            Reports the gaps between your commitments, in chronological order. \
            An event blocks its time unless it is marked free, cancelled, or an \
            invitation you declined.

            Examples:
              ekctl free --calendar work --duration 30
              ekctl free --calendar work,personal --duration 60 --days 14 --buffer 15
              ekctl free --calendar work --working-hours 08:00-18:00 --weekdays mon-thu --round 15
            """
    )

    @Option(
        name: .long,
        help: "Calendar ID or alias. Pass multiple comma-separated values to search several calendars at once (e.g., work,personal)."
    )
    var calendar: String

    @Option(name: .long, help: "Minimum length of a usable slot, in minutes.")
    var duration: Int = 30

    @Option(name: .long, help: "Search start in \(DateParsing.acceptedFormats). Defaults to now.")
    var from: String?

    @Option(
        name: .long,
        help: "Search end in \(DateParsing.acceptedFormats). Defaults to --days after the start."
    )
    var to: String?

    @Option(name: .long, help: "How many days to search when --to is omitted.")
    var days: Int = 7

    @Option(
        name: .long,
        help: "Daily window to search: \(WorkingHours.acceptedFormats). Overnight windows such as 22:00-02:00 are supported."
    )
    var workingHours: String = "09:00-17:00"

    @Option(
        name: .long,
        help: "Days to consider: \(Weekdays.acceptedFormats). An overnight window belongs to the day it opens, so 22:00-02:00 with mon-fri includes Friday night into Saturday morning."
    )
    var weekdays: String = "weekdays"

    @Option(
        name: .long,
        help: "Minutes of breathing room to leave either side of every meeting."
    )
    var buffer: Int = 0

    @Option(
        name: .long,
        help: "Round slot starts up to the next multiple of this many minutes, e.g. 15. Zero keeps the exact gap edges."
    )
    var round: Int = 0

    @Option(name: .long, help: "Maximum number of slots to return.")
    var limit: Int = 20

    @Flag(
        name: .long,
        help: "Ignore all-day events entirely. By default a busy all-day event blocks its days."
    )
    var ignoreAllDay: Bool = false

    @OptionGroup var outputFormat: OutputFormatOptions

    func run() throws {
        // Validate every argument before triggering the TCC permission prompt,
        // so a typo'd flag doesn't cost the user a permission dialog.
        func fail(_ message: String) -> Error {
            print(JSONOutput.error(message).format(outputFormat.format))
            return ExitCode.failure
        }

        guard duration > 0 else { throw fail("--duration must be a positive number of minutes.") }
        guard days > 0 else { throw fail("--days must be a positive integer.") }
        guard buffer >= 0 else { throw fail("--buffer cannot be negative.") }
        guard round >= 0 else { throw fail("--round cannot be negative.") }
        guard limit > 0 else { throw fail("--limit must be a positive integer.") }

        guard let hours = WorkingHours.parse(workingHours) else {
            throw fail("Invalid --working-hours value. Use \(WorkingHours.acceptedFormats).")
        }
        guard let selectedWeekdays = Weekdays.parse(weekdays) else {
            throw fail("Invalid --weekdays value. Use \(Weekdays.acceptedFormats).")
        }

        let startDate = try from.map {
            try parseDateOption($0, flag: "--from", format: outputFormat.format)
        } ?? Date()
        let endDate: Date
        if let to = to {
            endDate = try parseDateOption(to, flag: "--to", format: outputFormat.format)
        } else {
            endDate = DateRanges.nextWindow(now: startDate, days: days).end
        }
        guard startDate < endDate else {
            throw fail("The search range is empty: --to must be later than --from.")
        }

        // An unset shell variable (`--calendar "$CAL"`) resolves to no
        // calendars at all, and "no calendars are busy" would be reported as a
        // completely free week — the most confidently wrong answer this command
        // can give. Reject it here, before the permission prompt.
        let calendarIDs = ConfigManager.resolveCalendarIDs(calendar)
        guard !calendarIDs.isEmpty else {
            throw fail("--calendar must name at least one calendar ID or alias.")
        }

        let manager = EventKitManager(timeFormat: outputFormat.timeFormat)
        try manager.requestAccess(.events, format: outputFormat.format)

        let result = manager.findFreeSlots(
            calendarIDs: calendarIDs,
            from: startDate,
            to: endDate,
            durationMinutes: duration,
            workingHours: hours,
            weekdays: selectedWeekdays,
            bufferMinutes: buffer,
            roundToMinutes: round,
            limit: limit,
            ignoreAllDay: ignoreAllDay)
        try emit(result, format: outputFormat.format)
    }
}
