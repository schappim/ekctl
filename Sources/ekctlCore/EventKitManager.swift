import ArgumentParser
import CoreGraphics
import CoreLocation
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

public class EventKitManager {
    public init() {}

    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var reminderAccessGranted = false

    /// Requests access to both Calendar and Reminders.
    /// This must be called before any EventKit operations.
    public func requestAccess() throws {
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
            print(
                JSONOutput.error("Reminders access error: \(error.localizedDescription)").toJSON())
            throw ExitCode.failure
        }

        // Check permissions
        if !calendarAccessGranted && !reminderAccessGranted {
            print(
                JSONOutput.error(
                    "Permission denied for both Calendar and Reminders. "
                        + "Please grant access in System Settings > Privacy & Security."
                ).toJSON())
            throw ExitCode.failure
        }
    }

    // MARK: - Calendar Operations

    /// Create a new calendar
    public func createCalendar(title: String, color: String?) -> JSONOutput {
        // Attempt to find a source (usually iCloud or Local)
        let sources = eventStore.sources
        // Prefer iCloud, then Local source
        guard
            let source = sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
                ?? sources.first(where: { $0.sourceType == .local })
                ?? sources.first
        else {
            return JSONOutput.error("No suitable calendar source found")
        }

        let newCalendar = EKCalendar(for: .event, eventStore: eventStore)
        newCalendar.title = title
        newCalendar.source = source

        if let colorHex = color {
            if let cgColor = CGColor.fromHex(colorHex) {
                newCalendar.cgColor = cgColor
            }
        }

        do {
            try eventStore.saveCalendar(newCalendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Calendar created successfully",
                "id": newCalendar.calendarIdentifier,
            ])
        } catch {
            return JSONOutput.error("Failed to create calendar: \(error.localizedDescription)")
        }
    }

    /// Update a calendar
    public func updateCalendar(calendarID: String, title: String?, color: String?) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)")
        }

        if let title = title { calendar.title = title }
        if let colorHex = color {
            if let cgColor = CGColor.fromHex(colorHex) {
                calendar.cgColor = cgColor
            }
        }

        do {
            try eventStore.saveCalendar(calendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Calendar updated successfully",
            ])
        } catch {
            return JSONOutput.error("Failed to update calendar: \(error.localizedDescription)")
        }
    }

    /// Delete a calendar
    public func deleteCalendar(calendarID: String) -> JSONOutput {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return JSONOutput.error("Calendar not found with ID: \(calendarID)")
        }

        do {
            try eventStore.removeCalendar(calendar, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Calendar deleted successfully",
            ])
        } catch {
            return JSONOutput.error("Failed to delete calendar: \(error.localizedDescription)")
        }
    }

    /// Lists all calendars (event calendars and reminder lists)
    public func listCalendars() -> JSONOutput {
        var calendars: [[String: Any]] = []

        // Event calendars
        for calendar in eventStore.calendars(for: .event) {
            calendars.append([
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": "event",
                "source": calendar.source?.title ?? "Unknown",
                "color": calendar.cgColor?.hexString ?? "#000000",
                "allowsModifications": calendar.allowsContentModifications,
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
                "allowsModifications": calendar.allowsContentModifications,
            ])
        }

        return JSONOutput.success(["calendars": calendars])
    }

    // MARK: - Event Operations

    /// Lists events in a calendar within a date range
    public func listEvents(calendarID: String, from startDate: Date, to endDate: Date) -> JSONOutput {
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
    public func showEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
        }

        return JSONOutput.success(["event": eventToDict(event)])
    }

    /// Updates an existing calendar event
    public func updateEvent(
        eventID: String,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        location: String?,
        notes: String?,
        allDay: Bool?,
        url: String?,
        availability: String?,
        travelTime: TimeInterval?,
        alarms: [Double]?
    ) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
        }

        if let title = title { event.title = title }
        if let startDate = startDate { event.startDate = startDate }
        if let endDate = endDate { event.endDate = endDate }
        if let location = location {
            event.location = location
            // Use shared resolver (5s timeout) for consistent behavior with addEvent
            let structured = resolveLocation(location)
            event.structuredLocation = structured
        }
        if let notes = notes { event.notes = notes }
        if let allDay = allDay { event.isAllDay = allDay }

        if let urlString = url, let urlObj = URL(string: urlString) {
            event.url = urlObj
        }

        if let avail = availability?.lowercased() {
            switch avail {
            case "busy": event.availability = .busy
            case "free": event.availability = .free
            case "tentative": event.availability = .tentative
            case "unavailable": event.availability = .unavailable
            default: break
            }
        }

        if let travelTime = travelTime {
            // IMPORTANT: `travelTime` is set using KVC on a private/undocumented property name ("travelTime").
            // This is intentional as EventKit does not expose a public API for travel time.
            // This may break in future macOS updates.
            event.setValue(travelTime, forKey: "travelTime")
        }

        if let alarms = alarms {
            if let existing = event.alarms {
                for alarm in existing { event.removeAlarm(alarm) }
            }
            for offset in alarms {
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event updated successfully",
                "event": eventToDict(event),
            ])
        } catch {
            return JSONOutput.error("Failed to update event: \(error.localizedDescription)")
        }
    }

    /// Creates a new calendar event
    public func addEvent(
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        allDay: Bool,
        recurrenceFrequency: String? = nil,
        recurrenceInterval: Int = 1,
        recurrenceEndCount: Int? = nil,
        recurrenceEndDate: Date? = nil,
        recurrenceDays: String? = nil,
        recurrenceMonths: [NSNumber]? = nil,
        recurrenceDaysOfMonth: [NSNumber]? = nil,
        recurrenceWeeksOfYear: [NSNumber]? = nil,
        recurrenceDaysOfYear: [NSNumber]? = nil,
        recurrenceSetPositions: [NSNumber]? = nil,
        travelTime: TimeInterval? = nil,
        alarms: [Double]? = nil,
        url: String? = nil,
        availability: String? = nil
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
        // Location handling will be done below
        event.notes = notes
        event.isAllDay = allDay

        if let urlString = url, let urlObj = URL(string: urlString) {
            event.url = urlObj
        }

        if let avail = availability?.lowercased() {
            switch avail {
            case "busy": event.availability = .busy
            case "free": event.availability = .free
            case "tentative": event.availability = .tentative
            case "unavailable": event.availability = .unavailable
            default: break
            }
        }

        if let alarms = alarms {
            for offset in alarms {
                event.addAlarm(EKAlarm(relativeOffset: offset))
            }
        }

        // Location & Structured Location
        if let locationString = location {
            // First set standard location string
            event.location = locationString

            // Use shared resolveLocation helper which is more robust
            let structuredLocation = resolveLocation(locationString)
            event.structuredLocation = structuredLocation
        }

        // Recurrence Support
        if let freqString = recurrenceFrequency?.lowercased(), !freqString.isEmpty {
            var frequency: EKRecurrenceFrequency
            switch freqString {
            case "daily": frequency = .daily
            case "weekly": frequency = .weekly
            case "monthly": frequency = .monthly
            case "yearly": frequency = .yearly
            default: return JSONOutput.error("Invalid recurrence frequency: \(freqString)")
            }

            var daysOfTheWeek: [EKRecurrenceDayOfWeek]?
            if let daysStr = recurrenceDays {
                var days: [EKRecurrenceDayOfWeek] = []
                let dayMap: [String: EKWeekday] = [
                    "mon": .monday, "monday": .monday,
                    "tue": .tuesday, "tuesday": .tuesday,
                    "wed": .wednesday, "wednesday": .wednesday,
                    "thu": .thursday, "thursday": .thursday,
                    "fri": .friday, "friday": .friday,
                    "sat": .saturday, "saturday": .saturday,
                    "sun": .sunday, "sunday": .sunday,
                ]

                // Parse strings like "mon", "1mon", "-1fri"
                for dayPart in daysStr.split(separator: ",") {
                    var part = dayPart.trimmingCharacters(in: .whitespaces).lowercased()
                    var weekNumber = 0

                    // Extract leading number if present
                    if let range = part.range(of: "^-?\\d+", options: .regularExpression) {
                        if let num = Int(part[range]) {
                            weekNumber = num
                            part.removeSubrange(range)
                        }
                    }

                    if let weekday = dayMap[part] {
                        if weekNumber != 0 {
                            days.append(EKRecurrenceDayOfWeek(weekday, weekNumber: weekNumber))
                        } else {
                            days.append(EKRecurrenceDayOfWeek(weekday))
                        }
                    } else {
                        return JSONOutput.error("Invalid recurrence day: \(dayPart)")
                    }
                }
                daysOfTheWeek = days.isEmpty ? nil : days
            }

            var recurrenceEnd: EKRecurrenceEnd?
            if let count = recurrenceEndCount {
                recurrenceEnd = EKRecurrenceEnd(occurrenceCount: count)
            } else if let recEndDate = recurrenceEndDate {
                recurrenceEnd = EKRecurrenceEnd(end: recEndDate)
            }

            let rule = EKRecurrenceRule(
                recurrenceWith: frequency,
                interval: recurrenceInterval,
                daysOfTheWeek: daysOfTheWeek,
                daysOfTheMonth: recurrenceDaysOfMonth,
                monthsOfTheYear: recurrenceMonths,
                weeksOfTheYear: recurrenceWeeksOfYear,
                daysOfTheYear: recurrenceDaysOfYear,
                setPositions: recurrenceSetPositions,
                end: recurrenceEnd
            )
            event.addRecurrenceRule(rule)
        }

        // Travel Time (Manual)
        if let tTime = travelTime {
            event.setValue(tTime, forKey: "travelTime")
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event created successfully",
                "event": eventToDict(event),
            ])
        } catch {
            return JSONOutput.error("Failed to create event: \(error.localizedDescription)")
        }
    }

    /// Deletes a calendar event
    public func deleteEvent(eventID: String) -> JSONOutput {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return JSONOutput.error("Event not found with ID: \(eventID)")
        }

        let title = event.title ?? "Untitled"

        do {
            try eventStore.remove(event, span: .thisEvent)
            return JSONOutput.success([
                "status": "success",
                "message": "Event '\(title)' deleted successfully",
                "deletedEventID": eventID,
            ])
        } catch {
            return JSONOutput.error("Failed to delete event: \(error.localizedDescription)")
        }
    }

    // MARK: - Reminder Operations

    /// Lists reminders in a reminder list
    public func listReminders(listID: String, completed: Bool?) -> JSONOutput {
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
    public func showReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        return JSONOutput.success(["reminder": reminderToDict(reminder)])
    }

    /// Creates a new reminder
    public func addReminder(
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
            return JSONOutput.error(
                "Reminder list '\(calendar.title)' does not allow modifications.")
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
                "reminder": reminderToDict(reminder),
            ])
        } catch {
            return JSONOutput.error("Failed to create reminder: \(error.localizedDescription)")
        }
    }

    /// Updates an existing reminder
    public func updateReminder(
        reminderID: String,
        title: String?,
        dueDate: Date?,
        priority: Int?,
        notes: String?,
        completed: Bool?
    ) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        if let title = title { reminder.title = title }
        if let notes = notes { reminder.notes = notes }
        if let priority = priority { reminder.priority = priority }
        if let completed = completed {
            reminder.isCompleted = completed
            reminder.completionDate = completed ? Date() : nil
        }
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
                "message": "Reminder updated successfully",
                "reminder": reminderToDict(reminder),
            ])
        } catch {
            return JSONOutput.error("Failed to update reminder: \(error.localizedDescription)")
        }
    }

    /// Marks a reminder as completed
    public func completeReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()

        do {
            try eventStore.save(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(reminder.title ?? "Untitled")' marked as completed",
                "reminder": reminderToDict(reminder),
            ])
        } catch {
            return JSONOutput.error("Failed to complete reminder: \(error.localizedDescription)")
        }
    }

    /// Deletes a reminder
    public func deleteReminder(reminderID: String) -> JSONOutput {
        guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder
        else {
            return JSONOutput.error("Reminder not found with ID: \(reminderID)")
        }

        let title = reminder.title ?? "Untitled"

        do {
            try eventStore.remove(reminder, commit: true)
            return JSONOutput.success([
                "status": "success",
                "message": "Reminder '\(title)' deleted successfully",
                "deletedReminderID": reminderID,
            ])
        } catch {
            return JSONOutput.error("Failed to delete reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    /// Resolves a string address to an EKStructuredLocation using CLGeocoder
    private func resolveLocation(_ address: String) -> EKStructuredLocation {
        let group = DispatchGroup()
        group.enter()
        var result = EKStructuredLocation(title: address)

        let geocoder = CLGeocoder()
        geocoder.geocodeAddressString(address) { placemarks, error in
            if let placemark = placemarks?.first, let location = placemark.location {
                let s = EKStructuredLocation(title: address)
                s.geoLocation = location
                s.radius = 0
                result = s
            }
            group.leave()
        }

        // Wait for geocoding (max 5 seconds to be safe)
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while group.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            if Date() > timeout { break }
        }
        return result
    }

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
                "title": event.calendar?.title ?? "",
            ],
            "allDay": event.isAllDay,
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

        return dict
    }

    /// Converts an EKReminder to a dictionary for JSON output
    private func reminderToDict(_ reminder: EKReminder) -> [String: Any] {
        let formatter = localDateFormatter()

        var dict: [String: Any] = [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "list": [
                "id": reminder.calendar?.calendarIdentifier ?? "",
                "title": reminder.calendar?.title ?? "",
            ],
            "completed": reminder.isCompleted,
            "priority": reminder.priority,
        ]

        if let dueDateComponents = reminder.dueDateComponents,
            let dueDate = Calendar.current.date(from: dueDateComponents)
        {
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

extension CGColor {
    public var hexString: String {
        guard let components = components, components.count >= 3 else {
            return "#000000"
        }

        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)

        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public static func fromHex(_ hex: String) -> CGColor? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
