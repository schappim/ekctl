import ArgumentParser
import EventKit
import Foundation

/// EventKitManager handles all interactions with the EventKit framework.
///
/// IMPORTANT: macOS Permission Requirements
/// ----------------------------------------
/// On macOS, command-line tools require special setup to access Calendar and Reminders:
///
/// 1. The tool must be code-signed with appropriate entitlements
/// 2. An Info.plist must include privacy usage descriptions:
///    - NSCalendarsUsageDescription: Explains why calendar access is needed
///    - NSRemindersUsageDescription: Explains why reminders access is needed
///
/// 3. For development, you can embed the Info.plist:
///    - Add to Package.swift target: linkerSettings: [.unsafeFlags(["-sectcreate", "__TEXT", "__info_plist", "Info.plist"])]
///    - Or sign the binary: codesign --entitlements entitlements.plist -s - ekctl
///
/// 4. The first time the tool runs, macOS will prompt the user to grant access.
///    If denied, all operations will fail with a permission error.
///
/// 5. Users can manage permissions in: System Settings > Privacy & Security > Calendars/Reminders
class EventKitManager {
    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var reminderAccessGranted = false

    /// Requests access to both Calendar and Reminders.
    /// This must be called before any EventKit operations.
    func requestAccess() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var calendarError: Error?
        var reminderError: Error?

        // Request calendar access
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                self.calendarAccessGranted = granted
                calendarError = error
                semaphore.signal()
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                self.calendarAccessGranted = granted
                calendarError = error
                semaphore.signal()
            }
        }
        semaphore.wait()

        // Request reminders access
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                self.reminderAccessGranted = granted
                reminderError = error
                semaphore.signal()
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                self.reminderAccessGranted = granted
                reminderError = error
                semaphore.signal()
            }
        }
        semaphore.wait()

        // Check for errors
        if let error = calendarError {
            print(JSONOutput.error("Calendar access error: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }
        if let error = reminderError {
            print(JSONOutput.error("Reminders access error: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }

        // Check permissions
        if !calendarAccessGranted && !reminderAccessGranted {
            print(JSONOutput.error(
                "Permission denied for both Calendar and Reminders. " +
                "Please grant access in System Settings > Privacy & Security."
            ).toJSON())
            throw ExitCode.failure
        }
    }

    // MARK: - Calendar Operations

    /// Lists all calendars (event calendars and reminder lists)
    func listCalendars() -> JSONOutput {
        var calendars: [[String: Any]] = []

        // Event calendars
        for calendar in eventStore.calendars(for: .event) {
            calendars.append([
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": "event",
                "source": calendar.source?.title ?? "Unknown",
                "color": calendar.cgColor?.hexString ?? "#000000",
                "allowsModifications": calendar.allowsContentModifications
            ])
        }

        // Reminder lists
        for calendar in eventStore.calendars(for: .reminder) {
            calendars.append([
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": "reminder",
                "source": calendar.source?.title ?? "Unknown",
                "color": calendar.cgColor?.hexString ?? "#000000",
                "allowsModifications": calendar.allowsContentModifications
            ])
        }

        return JSONOutput.success(["calendars": calendars])
    }

    // MARK: - Event Operations

    /// Lists events in a calendar within a date range
    func listEvents(calendarID: String, from startDate: Date, to endDate: Date) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)")
        }

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: [calendar]
        )

        let events = eventStore.events(matching: predicate)
        let eventDicts = events.map { eventToDict($0) }

        return JSONOutput.success(["events": eventDicts, "count": eventDicts.count])
    }

    /// Shows details of a specific event
    func showEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
        }

        return JSONOutput.success(["event": eventToDict(event)])
    }

    /// Creates a new calendar event
    func addEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        allDay: Bool,
        frequency: String? = nil,
        interval: Int = 1,
        daysOfTheWeek: String? = nil,
        daysOfTheMonth: String? = nil,
        monthsOfTheYear: String? = nil,
        weeksOfTheYear: String? = nil,
        daysOfTheYear: String? = nil,
        setPositions: String? = nil,
        recurrenceEndDate: Date? = nil,
        recurrenceCount: Int? = nil
    ) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)")
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications.")
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.notes = notes
        event.isAllDay = allDay

        if let frequency = frequency {
            guard let parsedFrequency = parseFrequency(frequency) else {
                return JSONOutput.error("Invalid frequency '\(frequency)'. Use: daily, weekly, monthly, or yearly.")
            }

            var parsedDaysOfTheWeek: [EKRecurrenceDayOfWeek]?
            if let raw = daysOfTheWeek {
                let parsed = raw.split(separator: ",").compactMap { parseDayOfWeek(String($0)) }
                if parsed.isEmpty {
                    return JSONOutput.error("Invalid --days-of-the-week. Use: mon,tue,wed,thu,fri,sat,sun or with week number: 1mon, -1fri.")
                }
                parsedDaysOfTheWeek = parsed
            }

            let (adjustedStartDate, adjustedEndDate) = adjustStartDateForRecurrence(
                startDate: startDate,
                endDate: endDate,
                frequency: parsedFrequency,
                daysOfTheWeek: parsedDaysOfTheWeek
            )
            event.startDate = adjustedStartDate
            event.endDate = adjustedEndDate

            let parsedDaysOfTheMonth = parseIntList(daysOfTheMonth)
            let parsedMonthsOfTheYear = parseIntList(monthsOfTheYear)
            let parsedWeeksOfTheYear = parseIntList(weeksOfTheYear)
            let parsedDaysOfTheYear = parseIntList(daysOfTheYear)
            let parsedSetPositions = parseIntList(setPositions)

            var end: EKRecurrenceEnd?
            if let endDate = recurrenceEndDate {
                end = EKRecurrenceEnd(end: endDate)
            } else if let count = recurrenceCount {
                end = EKRecurrenceEnd(occurrenceCount: count)
            }

            let rule = EKRecurrenceRule(
                recurrenceWith: parsedFrequency,
                interval: interval,
                daysOfTheWeek: parsedDaysOfTheWeek,
                daysOfTheMonth: parsedDaysOfTheMonth,
                monthsOfTheYear: parsedMonthsOfTheYear,
                weeksOfTheYear: parsedWeeksOfTheYear,
                daysOfTheYear: parsedDaysOfTheYear,
                setPositions: parsedSetPositions,
                end: end
            )
            event.addRecurrenceRule(rule)
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event created successfully",
                "event": eventToDict(event)
            ])
        } catch {
            return JSONOutput.error("Failed to create event: \(error.localizedDescription)")
        }
    }

    /// Deletes a calendar event
    func deleteEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
        }

        let title = event.title ?? "Untitled"

        do {
            try eventStore.remove(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event '\(title)' deleted successfully",
                "deletedEventID": eventID
            ])
        } catch {
            return JSONOutput.error("Failed to delete event: \(error.localizedDescription)")
        }
    }

    // MARK: - Reminder Operations

    /// Lists reminders in a reminder list
    func listReminders(listID: String, completed: Bool?) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: listID) else {
            return JSONOutput.error("Reminder list not found with ID: \(listID)")
        }

        let predicate = eventStore.predicateForReminders(in: [calendar])

        var reminders: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)

        eventStore.fetchReminders(matching: predicate) { fetchedReminders in
            if let fetchedReminders = fetchedReminders {
                reminders = fetchedReminders
            }
            semaphore.signal()
        }
        semaphore.wait()

        // Filter by completion status if specified
        if let completed = completed {
            reminders = reminders.filter { $0.isCompleted == completed }
        }

        let reminderDicts = reminders.map { reminderToDict($0) }

        return JSONOutput.success(["reminders": reminderDicts, "count": reminderDicts.count])
    }

    /// Shows details of a specific reminder
    func showReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        return JSONOutput.success(["reminder": reminderToDict(reminder)])
    }

    /// Creates a new reminder
    func addReminder(
        listID: String,
        title: String,
        dueDate: Date?,
        priority: Int,
        notes: String?
    ) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: listID) else {
            return JSONOutput.error("Reminder list not found with ID: \(listID)")
        }

        guard calendar.allowsContentModifications else {
            return JSONOutput.error("Reminder list '\(calendar.title)' does not allow modifications.")
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.priority = priority
        reminder.notes = notes

        if let dueDate = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
        }

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder created successfully",
                "reminder": reminderToDict(reminder)
            ])
        } catch {
            return JSONOutput.error("Failed to create reminder: \(error.localizedDescription)")
        }
    }

    /// Marks a reminder as completed
    func completeReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(reminder.title ?? "Untitled")' marked as completed",
                "reminder": reminderToDict(reminder)
            ])
        } catch {
            return JSONOutput.error("Failed to complete reminder: \(error.localizedDescription)")
        }
    }

    /// Deletes a reminder
    func deleteReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        let title = reminder.title ?? "Untitled"

        do {
            try eventStore.remove(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(title)' deleted successfully",
                "deletedReminderID": reminderID
            ])
        } catch {
            return JSONOutput.error("Failed to delete reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    /// Creates a date formatter that outputs ISO 8601 format in the user's local timezone
    private func localDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"  // ISO 8601 with timezone offset
        formatter.timeZone = TimeZone.current
        return formatter
    }

    /// Converts an EKEvent to a dictionary for JSON output
    private func eventToDict(_ event: EKEvent) -> [String: Any] {
        let formatter = localDateFormatter()

        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "calendar": [
                "id": event.calendar?.calendarIdentifier ?? "",
                "title": event.calendar?.title ?? ""
            ],
            "allDay": event.isAllDay
        ]

        if let startDate = event.startDate {
            dict["startDate"] = formatter.string(from: startDate)
        }
        if let endDate = event.endDate {
            dict["endDate"] = formatter.string(from: endDate)
        }
        if let location = event.location, !location.isEmpty {
            dict["location"] = location
        } else {
            dict["location"] = NSNull()
        }
        if let notes = event.notes, !notes.isEmpty {
            dict["notes"] = notes
        } else {
            dict["notes"] = NSNull()
        }
        if let url = event.url {
            dict["url"] = url.absoluteString
        }

        dict["hasAlarms"] = event.hasAlarms
        dict["hasRecurrenceRules"] = event.hasRecurrenceRules

        if event.hasRecurrenceRules, let rules = event.recurrenceRules {
            dict["recurrenceRules"] = rules.map { recurrenceRuleToDict($0) }
        }

        return dict
    }

    private func recurrenceRuleToDict(_ rule: EKRecurrenceRule) -> [String: Any] {
        var dict: [String: Any] = [
            "frequency": frequencyString(rule.frequency),
            "interval": rule.interval
        ]

        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate {
                let formatter = localDateFormatter()
                dict["end"] = ["type": "date", "date": formatter.string(from: endDate)]
            } else if end.occurrenceCount > 0 {
                dict["end"] = ["type": "count", "count": end.occurrenceCount]
            }
        }

        if let days = rule.daysOfTheWeek {
            dict["daysOfTheWeek"] = days.map { day -> [String: Any] in
                var d: [String: Any] = ["dayOfTheWeek": weekdayString(day.dayOfTheWeek)]
                if day.weekNumber != 0 {
                    d["weekNumber"] = day.weekNumber
                }
                return d
            }
        }
        if let days = rule.daysOfTheMonth {
            dict["daysOfTheMonth"] = days.map { $0.intValue }
        }
        if let months = rule.monthsOfTheYear {
            dict["monthsOfTheYear"] = months.map { $0.intValue }
        }
        if let weeks = rule.weeksOfTheYear {
            dict["weeksOfTheYear"] = weeks.map { $0.intValue }
        }
        if let days = rule.daysOfTheYear {
            dict["daysOfTheYear"] = days.map { $0.intValue }
        }
        if let positions = rule.setPositions {
            dict["setPositions"] = positions.map { $0.intValue }
        }

        return dict
    }

    private func frequencyString(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .yearly: return "yearly"
        @unknown default: return "unknown"
        }
    }

    private func adjustStartDateForRecurrence(
        startDate: Date,
        endDate: Date,
        frequency: EKRecurrenceFrequency,
        daysOfTheWeek: [EKRecurrenceDayOfWeek]?
    ) -> (start: Date, end: Date) {
        guard frequency == .monthly,
              let days = daysOfTheWeek,
              !days.isEmpty,
              days.allSatisfy({ $0.weekNumber != 0 }) else {
            return (startDate, endDate)
        }

        let cal = Calendar.current
        let duration = endDate.timeIntervalSince(startDate)

        for monthOffset in 0..<13 {
            guard let refDate = cal.date(byAdding: .month, value: monthOffset, to: startDate) else { continue }
            let year = cal.component(.year, from: refDate)
            let month = cal.component(.month, from: refDate)

            var earliest: Date?
            for day in days {
                guard let candidate = nthWeekdayInMonth(
                    weekday: day.dayOfTheWeek,
                    weekNumber: day.weekNumber,
                    year: year,
                    month: month
                ) else { continue }

                var comps = cal.dateComponents([.year, .month, .day], from: candidate)
                let timeComps = cal.dateComponents([.hour, .minute, .second], from: startDate)
                comps.hour = timeComps.hour
                comps.minute = timeComps.minute
                comps.second = timeComps.second
                guard let withTime = cal.date(from: comps) else { continue }

                if withTime >= startDate {
                    if earliest == nil || withTime < earliest! {
                        earliest = withTime
                    }
                }
            }

            if let adjusted = earliest {
                return (adjusted, adjusted.addingTimeInterval(duration))
            }
        }

        return (startDate, endDate)
    }

    private func nthWeekdayInMonth(weekday: EKWeekday, weekNumber: Int, year: Int, month: Int) -> Date? {
        let cal = Calendar.current
        let calWeekday = ekWeekdayToCalendarWeekday(weekday)

        if weekNumber > 0 {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.weekday = calWeekday
            comps.weekdayOrdinal = weekNumber
            guard let date = cal.date(from: comps) else { return nil }
            guard cal.component(.month, from: date) == month else { return nil }
            return date
        }

        var firstOfMonth = DateComponents()
        firstOfMonth.year = year
        firstOfMonth.month = month
        firstOfMonth.day = 1
        guard let first = cal.date(from: firstOfMonth),
              let range = cal.range(of: .day, in: .month, for: first) else { return nil }

        var lastDayComps = DateComponents()
        lastDayComps.year = year
        lastDayComps.month = month
        lastDayComps.day = range.count
        guard let lastDay = cal.date(from: lastDayComps) else { return nil }

        let lastWeekday = cal.component(.weekday, from: lastDay)
        var diff = lastWeekday - calWeekday
        if diff < 0 { diff += 7 }

        let daysBack = diff + (-(weekNumber + 1)) * 7
        return cal.date(byAdding: .day, value: -daysBack, to: lastDay)
    }

    private func ekWeekdayToCalendarWeekday(_ weekday: EKWeekday) -> Int {
        switch weekday {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        @unknown default: return 1
        }
    }

    private func parseFrequency(_ string: String) -> EKRecurrenceFrequency? {
        switch string.lowercased() {
        case "daily": return .daily
        case "weekly": return .weekly
        case "monthly": return .monthly
        case "yearly": return .yearly
        default: return nil
        }
    }

    private func weekdayString(_ weekday: EKWeekday) -> String {
        switch weekday {
        case .sunday: return "sun"
        case .monday: return "mon"
        case .tuesday: return "tue"
        case .wednesday: return "wed"
        case .thursday: return "thu"
        case .friday: return "fri"
        case .saturday: return "sat"
        @unknown default: return "unknown"
        }
    }

    private func parseWeekday(_ string: String) -> EKWeekday? {
        switch string.lowercased() {
        case "sun": return .sunday
        case "mon": return .monday
        case "tue": return .tuesday
        case "wed": return .wednesday
        case "thu": return .thursday
        case "fri": return .friday
        case "sat": return .saturday
        default: return nil
        }
    }

    private func parseDayOfWeek(_ string: String) -> EKRecurrenceDayOfWeek? {
        let s = string.trimmingCharacters(in: .whitespaces).lowercased()
        if s.count == 3, let weekday = parseWeekday(s) {
            return EKRecurrenceDayOfWeek(weekday)
        }
        let letters = s.suffix(3)
        let digits = s.dropLast(3)
        guard let weekday = parseWeekday(String(letters)),
              let weekNumber = Int(digits) else {
            return nil
        }
        return EKRecurrenceDayOfWeek(weekday, weekNumber: weekNumber)
    }

    private func parseIntList(_ string: String?) -> [NSNumber]? {
        guard let string = string else { return nil }
        let numbers = string.split(separator: ",").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
        return numbers.isEmpty ? nil : numbers.map { NSNumber(value: $0) }
    }

    /// Converts an EKReminder to a dictionary for JSON output
    private func reminderToDict(_ reminder: EKReminder) -> [String: Any] {
        let formatter = localDateFormatter()

        var dict: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": [
                "id": reminder.calendar?.calendarIdentifier ?? "",
                "title": reminder.calendar?.title ?? ""
            ],
            "completed": reminder.isCompleted,
            "priority": reminder.priority
        ]

        if let dueDateComponents = reminder.dueDateComponents,
           let dueDate = Calendar.current.date(from: dueDateComponents) {
            dict["dueDate"] = formatter.string(from: dueDate)
        } else {
            dict["dueDate"] = NSNull()
        }

        if let completionDate = reminder.completionDate {
            dict["completionDate"] = formatter.string(from: completionDate)
        }

        if let notes = reminder.notes, !notes.isEmpty {
            dict["notes"] = notes
        } else {
            dict["notes"] = NSNull()
        }

        if let url = reminder.url {
            dict["url"] = url.absoluteString
        }

        return dict
    }
}

// MARK: - CGColor Extension for Hex String

import CoreGraphics

extension CGColor {
    var hexString: String {
        guard let components = components, components.count >= 3 else {
            return "#000000"
        }

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
