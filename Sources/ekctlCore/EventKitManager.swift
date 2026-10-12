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

/// Which EventKit stores a command touches, and therefore which TCC
/// permission prompts the user sees on first run. Commands request the
/// narrowest scope they can: a reminders-only workflow never triggers the
/// Calendar prompt, and a denied-but-unneeded permission no longer produces
/// confusing downstream "not found" errors.
public enum AccessScope {
    case events
    case reminders
    /// Mixed-store commands (e.g. `list calendars`, which lists event
    /// calendars *and* reminder lists). Proceeds when at least one of the
    /// two permissions is granted, degrading to the accessible store.
    case all

    var includesEvents: Bool { self != .reminders }
    var includesReminders: Bool { self != .events }
}

public class EventKitManager {
    /// `timeFormat` controls how `eventToDict`/`reminderToDict` render
    /// timestamps — see `TimeFormat` (issue #3).
    public init(timeFormat: TimeFormat = .rfc3339) {
        self.timeFormat = timeFormat
    }

    private let timeFormat: TimeFormat
    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var reminderAccessGranted = false

    /// Requests access to the EventKit stores named by `scope`.
    /// This must be called before any other EventKit operation. Denial of a
    /// *needed* permission prints an error (in `format`) and exits with
    /// `ExitCode.permissionDenied` so scripts can distinguish it from other
    /// failures.
    public func requestAccess(_ scope: AccessScope = .all, format: OutputFormat = .json) throws {
        var calendarError: Error?
        var reminderError: Error?

        if scope.includesEvents {
            let semaphore = DispatchSemaphore(value: 0)
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
        }

        if scope.includesReminders {
            let semaphore = DispatchSemaphore(value: 0)
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
        }

        // Check for errors
        if let error = calendarError {
            print(JSONOutput.error("Calendar access error: \(error.localizedDescription)").format(format))
            throw ExitCode.failure
        }
        if let error = reminderError {
            print(
                JSONOutput.error("Reminders access error: \(error.localizedDescription)").format(format))
            throw ExitCode.failure
        }

        // Check the permission the requested scope actually depends on, and
        // name the matching Settings pane in the error.
        let deniedMessage: String?
        switch scope {
        case .events:
            deniedMessage = calendarAccessGranted
                ? nil
                : "Permission denied for Calendar. "
                    + "Please grant access in System Settings > Privacy & Security > Calendars."
        case .reminders:
            deniedMessage = reminderAccessGranted
                ? nil
                : "Permission denied for Reminders. "
                    + "Please grant access in System Settings > Privacy & Security > Reminders."
        case .all:
            // Mixed-store commands degrade gracefully when only one side is
            // granted, so only a full denial is fatal.
            deniedMessage = (calendarAccessGranted || reminderAccessGranted)
                ? nil
                : "Permission denied for both Calendar and Reminders. "
                    + "Please grant access in System Settings > Privacy & Security."
        }
        if let deniedMessage = deniedMessage {
            print(JSONOutput.error(deniedMessage).format(format))
            throw ExitCode.permissionDenied
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
        // Only consult a store whose permission was granted: asking for the
        // default calendar of a store we can't read just logs noise.
        let defaultEventCalendarID = calendarAccessGranted
            ? eventStore.defaultCalendarForNewEvents?.calendarIdentifier : nil
        let defaultReminderListID = reminderAccessGranted
            ? eventStore.defaultCalendarForNewReminders()?.calendarIdentifier : nil

        func entry(_ calendar: EKCalendar, type: String, defaultID: String?) -> [String: Any] {
            [
                "id": calendar.calendarIdentifier,
                "title": calendar.title,
                "type": type,
                "source": calendar.source?.title ?? "Unknown",
                "calendarType": Self.calendarTypeString(calendar.type),
                "color": calendar.cgColor?.hexString ?? "#000000",
                "allowsModifications": calendar.allowsContentModifications,
                // Where `add event` / `add reminder` put things when no
                // calendar is named.
                "isDefault": calendar.calendarIdentifier == defaultID,
            ]
        }

        for calendar in eventStore.calendars(for: .event) {
            calendars.append(entry(calendar, type: "event", defaultID: defaultEventCalendarID))
        }
        for calendar in eventStore.calendars(for: .reminder) {
            calendars.append(entry(calendar, type: "reminder", defaultID: defaultReminderListID))
        }

        return JSONOutput.success(["calendars": calendars])
    }

    /// The kind of account behind a calendar: `local` (On My Mac), `calDAV`
    /// (iCloud, Google, Fastmail...), `exchange`, `subscription` (a read-only
    /// feed such as public holidays), or `birthday` (generated from Contacts).
    static func calendarTypeString(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Event Operations

    /// Lists events within a date range, from the calendars named by
    /// `calendarIDs`, or from every event calendar when it is nil.
    public func listEvents(
        calendarIDs: [String]?,
        from startDate: Date,
        to endDate: Date,
        search: String? = nil,
        availability: AvailabilityFilter? = nil,
        sortedByStartAscending: Bool = false,
        limit: Int? = nil
    ) -> JSONOutput {
        // nil, not an empty array, is EventKit's "all calendars". An empty
        // selection is an error the CLI catches before it gets here.
        var calendars: [EKCalendar]?
        if let calendarIDs = calendarIDs {
            var selected: [EKCalendar] = []
            for id in calendarIDs {
                guard let calendar = eventStore.calendar(withIdentifier: id) else {
                    return JSONOutput.error("Calendar not found with ID: \(id)")
                }
                selected.append(calendar)
            }
            calendars = selected
        }

        var filtered = fetchEvents(from: startDate, to: endDate, calendars: calendars).filter { event in
            EventFilter.matchesSearch(search, in: [event.title, event.location, event.notes])
            && EventFilter.matchesAvailability(
                availability,
                eventAvailability: Self.availabilityString(event.availability))
        }
        if sortedByStartAscending {
            filtered.sort { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        }
        if let limit = limit, filtered.count > limit {
            filtered = Array(filtered.prefix(limit))
        }
        let eventDicts = filtered.map { eventToDict($0) }

        return JSONOutput.success(["events": eventDicts, "count": eventDicts.count])
    }

    /// Convenience overload that accepts a single calendar ID.
    public func listEvents(calendarID: String, from startDate: Date, to endDate: Date) -> JSONOutput {
        return listEvents(calendarIDs: [calendarID], from: startDate, to: endDate)
    }

    /// Every event occurrence overlapping `[start, end]`, however long the
    /// range.
    ///
    /// EventKit silently truncates a predicate spanning more than four years
    /// to its first four, so `list events --from 2019-01-01 --to 2031-01-01`
    /// used to return 2019-2023 and nothing after. Longer ranges are fetched
    /// in chunks; an event straddling a chunk boundary comes back from both,
    /// so occurrences are deduplicated by ID and start.
    func fetchEvents(from start: Date, to end: Date, calendars: [EKCalendar]?) -> [EKEvent] {
        let chunk: TimeInterval = 3 * 365 * 86_400
        var events: [EKEvent] = []
        var seen = Set<String>()
        var chunkStart = start
        repeat {
            let chunkEnd = min(end, chunkStart.addingTimeInterval(chunk))
            let predicate = eventStore.predicateForEvents(
                withStart: chunkStart, end: chunkEnd, calendars: calendars)
            for event in eventStore.events(matching: predicate) {
                let key = "\(event.eventIdentifier ?? "")@\(event.startDate?.timeIntervalSinceReferenceDate ?? 0)"
                if seen.insert(key).inserted { events.append(event) }
            }
            chunkStart = chunkEnd
        } while chunkStart < end
        return events
    }

    /// Single source of truth for mapping EKEventAvailability to its public string
    /// form. Used by both `eventToDict` (for output) and `listEvents` (for filtering
    /// against `AvailabilityFilter`) so the two paths can't drift apart.
    static func availabilityString(_ a: EKEventAvailability) -> String {
        switch a {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        case .notSupported: return "notSupported"
        @unknown default: return "unknown"
        }
    }

    /// Finds open time slots across `calendarIDs` — the engine behind
    /// `ekctl free`.
    ///
    /// An event blocks its interval unless it is marked *free*: availability is
    /// the user's own statement about whether the time is really taken, so it
    /// is used in preference to any guess based on titles. Cancelled events and
    /// invitations the user has declined don't block — they aren't commitments.
    /// All-day events block by their availability like anything else (a busy
    /// all-day "Offsite" is exactly the conflict you want surfaced); pass
    /// `ignoreAllDay` to drop them entirely.
    public func findFreeSlots(
        calendarIDs: [String],
        from startDate: Date,
        to endDate: Date,
        durationMinutes: Int,
        workingHours: WorkingHours,
        weekdays: Set<Int>,
        bufferMinutes: Int = 0,
        roundToMinutes: Int = 0,
        limit: Int? = nil,
        ignoreAllDay: Bool = false
    ) -> JSONOutput {
        // Reporting free time for no calendars would claim the whole window is
        // open. The CLI rejects this earlier; guarded here too because the
        // wrong answer is so much worse than the error.
        guard !calendarIDs.isEmpty else {
            return JSONOutput.error("No calendars given to search for free time.")
        }

        var calendars: [EKCalendar] = []
        for id in calendarIDs {
            guard let calendar = eventStore.calendar(withIdentifier: id) else {
                return JSONOutput.error("Calendar not found with ID: \(id)")
            }
            // `calendar(withIdentifier:)` also resolves Reminders lists. One of
            // those holds no events, so it would contribute no busy time and
            // the command would confidently report the window as free.
            guard calendar.allowedEntityTypes.contains(.event) else {
                return JSONOutput.error(
                    "'\(calendar.title)' is a Reminders list, not an event calendar. "
                        + "Run `ekctl list calendars` to find an event calendar.")
            }
            calendars.append(calendar)
        }

        let events = fetchEvents(from: startDate, to: endDate, calendars: calendars)
        let busy: [TimeSlot] = events.compactMap { event in
            guard Self.blocksTime(event, ignoreAllDay: ignoreAllDay),
                  let start = event.startDate,
                  let end = event.endDate
            else { return nil }
            return TimeSlot(start: start, end: end)
        }

        let slots = FreeBusy.slots(
            busy: busy,
            from: startDate,
            to: endDate,
            workingHours: workingHours,
            weekdays: weekdays,
            minimumDurationMinutes: durationMinutes,
            bufferMinutes: bufferMinutes,
            roundToMinutes: roundToMinutes,
            limit: limit
        )

        let formatter = localDateFormatter
        let dayFormatter = localDayFormatter
        let calendar = Calendar.current
        // `startDate`/`endDate` rather than `start`/`end`: slot rows sit
        // alongside event and reminder rows in CSV and jq pipelines, and those
        // already use the longer names.
        let slotDicts: [[String: Any]] = slots.map { slot in
            [
                "startDate": formatter.string(from: slot.start),
                "endDate": formatter.string(from: slot.end),
                "durationMinutes": slot.durationMinutes,
                "date": dayFormatter.string(from: slot.start),
                "weekday": Weekdays.name(for: calendar.component(.weekday, from: slot.start)),
            ]
        }

        return JSONOutput.success([
            "slots": slotDicts,
            "count": slotDicts.count,
            // Named for what it is — the filter that was applied — so it can't
            // be mistaken for the length of the slot in a single-slot response.
            "minimumDurationMinutes": durationMinutes,
            "searchedFrom": formatter.string(from: startDate),
            "searchedTo": formatter.string(from: endDate),
            "workingHours": workingHours.formatted,
            "weekdays": Weekdays.formatted(weekdays),
            "busyEventCount": busy.count,
        ])
    }

    /// Whether an event occupies time for free-slot purposes, expressed over
    /// plain values rather than an `EKEvent` so the rule can be unit-tested
    /// without a live store (an in-memory `EKEvent` can't even hold an
    /// availability — that lives on its calendar).
    ///
    /// The rule: an event blocks its time unless the user has already said
    /// otherwise — marked it free, had it cancelled, or declined the invite.
    public static func blocksTime(availability: EKEventAvailability,
                                  isAllDay: Bool,
                                  status: EKEventStatus,
                                  currentUserDeclined: Bool,
                                  ignoreAllDay: Bool) -> Bool {
        if ignoreAllDay && isAllDay { return false }
        if availability == .free { return false }
        if status == .canceled { return false }
        if currentUserDeclined { return false }
        return true
    }

    /// Adapter from a live `EKEvent` onto the rule above.
    static func blocksTime(_ event: EKEvent, ignoreAllDay: Bool) -> Bool {
        let declined = event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } ?? false
        return blocksTime(
            availability: event.availability,
            isAllDay: event.isAllDay,
            status: event.status,
            currentUserDeclined: declined,
            ignoreAllDay: ignoreAllDay)
    }

    /// Finds the occurrence an event ID (plus optional `--occurrence` date)
    /// refers to.
    ///
    /// Every occurrence of a recurring series shares one identifier, and
    /// `event(withIdentifier:)` always answers with the *first* one. So an ID
    /// alone can't say "the 16 March standup"; `occurrence` — the start time
    /// shown in `list events`, or its `occurrenceDate` — does. Occurrences
    /// edited on their own carry a `/RID=` suffix and resolve directly.
    ///
    /// - Parameter requireOccurrenceForSeries: when true, a bare series ID is
    ///   refused rather than silently meaning its first occurrence. Updates
    ///   and deletes pass true unless the span is `all`; before this check
    ///   existed, `delete event <id>` on a listed weekly meeting quietly
    ///   deleted the first meeting of the series instead.
    enum EventLookup {
        case success(EKEvent)
        /// The error response to print, already worded for the user.
        case failure(JSONOutput)
    }

    func resolveEvent(
        eventID: String,
        occurrence: Date?,
        requireOccurrenceForSeries: Bool = false
    ) -> EventLookup {
        guard let event = eventStore.event(withIdentifier: eventID) else {
            return .failure(JSONOutput.error("Event not found with ID: \(eventID)"))
        }
        let series = EventIdentifiers.seriesID(eventID)
        guard let occurrence = occurrence else {
            // Judged by the ID's shape, not `isDetached`: when a series' first
            // occurrence has been edited on its own, the bare series ID
            // resolves to that detached occurrence, and it still isn't a
            // choice of occurrence.
            if requireOccurrenceForSeries && series == eventID
                && (event.hasRecurrenceRules || event.isDetached)
            {
                return .failure(JSONOutput.error(
                    "'\(event.title ?? "Untitled")' is a recurring event, and every occurrence shares "
                        + "this ID. Pass --occurrence with the occurrence's start time (its startDate in "
                        + "`ekctl list events`) to choose one, or --span all for the whole series."))
            }
            return .success(event)
        }

        var candidates: [EKEvent] = []
        func consider(_ candidate: EKEvent) {
            let key = { (e: EKEvent) in "\(e.eventIdentifier ?? "")@\(e.startDate?.timeIntervalSinceReferenceDate ?? 0)" }
            if !candidates.contains(where: { key($0) == key(candidate) }) { candidates.append(candidate) }
        }
        func sameInstant(_ date: Date?) -> Bool {
            guard let date = date else { return false }
            return abs(date.timeIntervalSince(occurrence)) < 1
        }

        // An occurrence moved on its own is stored under its original slot:
        // `<series>/RID=<seconds since 2001>`. Looking that up directly finds
        // it however far it was moved.
        // A floating all-day event's slot is that date's midnight in UTC
        // rather than local midnight, so that spelling is tried as well.
        var slots = [occurrence]
        if event.isAllDay {
            let local = Calendar.current.dateComponents([.year, .month, .day], from: occurrence)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            if let midnight = utc.date(from: local) { slots.append(midnight) }
        }
        for slot in slots {
            let rid = "\(series)/RID=\(Int(slot.timeIntervalSinceReferenceDate.rounded()))"
            if let detached = eventStore.event(withIdentifier: rid),
               EventIdentifiers.seriesID(detached.eventIdentifier ?? "") == series,
               detached.eventIdentifier == rid || sameInstant(detached.occurrenceDate)
            {
                consider(detached)
            }
        }
        // Matching on startDate *or* occurrenceDate finds an occurrence
        // whether the caller copied its current start time or its original
        // slot (they differ once it has been moved on its own).
        let window: TimeInterval = 24 * 60 * 60
        for candidate in fetchEvents(
            from: occurrence.addingTimeInterval(-window), to: occurrence.addingTimeInterval(window),
            calendars: event.calendar.map { [$0] })
        where EventIdentifiers.seriesID(candidate.eventIdentifier ?? "") == series
            && (sameInstant(candidate.startDate) || sameInstant(candidate.occurrenceDate))
        {
            consider(candidate)
        }

        switch candidates.count {
        case 0:
            return .failure(JSONOutput.error(
                "No occurrence of '\(event.title ?? "Untitled")' starts at "
                    + "\(localDateFormatter.string(from: occurrence)). Run `ekctl list events` to see "
                    + "when its occurrences start."))
        case 1:
            return .success(candidates[0])
        default:
            // An occurrence moved onto another one's slot: both match. Picking
            // either would edit or delete a meeting the caller may not mean.
            let listed = candidates.map {
                "\($0.eventIdentifier ?? "") (starts \(localDateFormatter.string(from: $0.startDate)))"
            }.joined(separator: "; ")
            return .failure(JSONOutput.error(
                "--occurrence \(localDateFormatter.string(from: occurrence)) matches "
                    + "\(candidates.count) occurrences of '\(event.title ?? "Untitled")': \(listed). "
                    + "Pass the ID of the one you mean instead (an occurrence moved on its own has an "
                    + "ID ending in /RID=…)."))
        }
    }

    /// Shows details of a specific event, or of one occurrence of a series.
    public func showEvent(eventID: String, occurrence: Date? = nil) -> JSONOutput {
        switch resolveEvent(eventID: eventID, occurrence: occurrence) {
        case .failure(let error): return error
        case .success(let event): return JSONOutput.success(["event": eventToDict(event)])
        }
    }

    // MARK: Side effects of series edits

    /// What a calendar held before a series-wide change, so anything EventKit
    /// changed beyond what was asked can be detected and reported.
    ///
    /// EventKit keeps a series split with `.futureEvents` linked to the one
    /// it came from, and changes to the original can cascade into it: a
    /// `.futureEvents` removal of the original also removes the split-off
    /// series, and moving the original's start can move it too and drop
    /// occurrences. There's no public API to see the link, so the only
    /// honest option is to compare before and after.
    private struct Snapshot {
        let from: Date
        let to: Date
        let calendars: [EKCalendar]
        /// Start times of each series' occurrences, keyed by series ID.
        var starts: [String: [TimeInterval]] = [:]
        var titles: [String: String] = [:]
        /// Original slots (`occurrenceDate`) of each series' occurrences.
        var slots: [String: Set<TimeInterval>] = [:]
        /// Start and title of each occurrence: a cascade can rename as well
        /// as move or delete.
        var signatures: [String: [String]] = [:]
    }

    /// Calendars by ID, fetched fresh: `eventStore.reset()` invalidates
    /// calendar objects as well as events.
    private func calendars(_ ids: [String]) -> [EKCalendar] {
        ids.compactMap { eventStore.calendar(withIdentifier: $0) }
    }

    private func snapshot(from: Date, to: Date, calendars: [EKCalendar]) -> Snapshot {
        var snap = Snapshot(from: from, to: to, calendars: calendars)
        for event in fetchEvents(from: from, to: to, calendars: calendars) {
            let series = EventIdentifiers.seriesID(event.eventIdentifier ?? "")
            snap.starts[series, default: []].append(event.startDate.timeIntervalSinceReferenceDate)
            snap.signatures[series, default: []].append(
                "\(event.startDate.timeIntervalSinceReferenceDate)|\(event.title ?? "")")
            snap.slots[series, default: []].insert(
                (event.occurrenceDate ?? event.startDate).timeIntervalSinceReferenceDate.rounded())
            snap.titles[series] = event.title ?? "Untitled"
        }
        return snap
    }

    /// Series other than `expected` whose occurrences changed between the
    /// two snapshots.
    private func sideEffects(before: Snapshot, after: Snapshot, expected: Set<String>) -> [[String: Any]] {
        before.starts.keys.filter { !expected.contains($0) }.sorted().compactMap { series in
            let was = (before.starts[series] ?? []).sorted()
            let now = (after.starts[series] ?? []).sorted()
            guard was != now
                || (before.signatures[series] ?? []).sorted() != (after.signatures[series] ?? []).sorted()
            else { return nil }
            return [
                "id": series,
                "title": before.titles[series] ?? "Untitled",
                "change": now.isEmpty ? "deleted" : "changed",
                "occurrencesBefore": was.count,
                "occurrencesAfter": now.count,
            ]
        }
    }

    private static func sideEffectWarning(_ affected: [[String: Any]]) -> String? {
        guard !affected.isEmpty else { return nil }
        let names = affected.map { "'\($0["title"] ?? "")'" }.joined(separator: ", ")
        return "EventKit also changed \(affected.count == 1 ? "another series" : "\(affected.count) other series") "
            + "in this calendar: \(names), listed in alsoAffected. This happens to a series that was split off "
            + "this one with --span future. Check them with `ekctl list events`."
    }

    // MARK: Update

    /// Updates an existing calendar event: one occurrence, an occurrence and
    /// everything after it, or the whole series (`span`).
    public func updateEvent(
        eventID: String,
        occurrence: Date? = nil,
        span: EventSpan = .this,
        title newTitle: String?,
        startDate: Date?,
        endDate: Date?,
        location: String?,
        notes: String?,
        allDay: Bool?,
        url: String?,
        availability: AvailabilitySetting?,
        travelTime: TimeInterval?,
        alarms: [Double]?,
        addAlarms: [Double]? = nil,
        calendarID: String? = nil,
        recurrence: RecurrenceSpec = RecurrenceSpec()
    ) -> JSONOutput {
        let addressed: EKEvent
        switch resolveEvent(
            eventID: eventID, occurrence: occurrence, requireOccurrenceForSeries: span != .all)
        {
        case .failure(let error): return error
        case .success(let event): addressed = event
        }
        let partOfSeries = addressed.hasRecurrenceRules || addressed.isDetached
        let title = addressed.title ?? "Untitled"
        let seriesID = EventIdentifiers.seriesID(addressed.eventIdentifier ?? eventID)
        let first = partOfSeries ? eventStore.event(withIdentifier: seriesID) : addressed

        let target: EKEvent
        switch seriesTarget(for: addressed, span: span, partOfSeries: partOfSeries) {
        case .failure(let error): return error
        case .success(let event): target = event
        }
        guard let addressedStart = addressed.startDate, let addressedEnd = addressed.endDate,
              let targetStart = target.startDate, target.endDate != nil
        else {
            return JSONOutput.error("'\(title)' has no start or end date, so it can't be updated.")
        }

        // Validate everything that can be refused before changing anything.
        var newCalendar: EKCalendar?
        if let calendarID = calendarID {
            switch writableEventCalendar(calendarID) {
            case .failure(let error): return error
            case .success(let calendar): newCalendar = calendar
            }
            // EventKit keeps a series in one calendar: assigning a new one to
            // a single occurrence and saving it with `.thisEvent` silently
            // moves every occurrence, detached ones included.
            if partOfSeries && span != .all
                && newCalendar?.calendarIdentifier != target.calendar?.calendarIdentifier
            {
                return JSONOutput.error(
                    "'\(title)' is part of a recurring series, and EventKit can only move a whole series "
                        + "between calendars. Pass --span all to move every occurrence.")
            }
        }

        // The rule the series has now. A detached occurrence carries none of
        // its own, so it's read from the series.
        let currentRule = (target.recurrenceRules?.first ?? first?.recurrenceRules?.first)
            .map(RecurrenceSpec.init)
        var newRule: RecurrenceSpec?
        if !recurrence.isEmpty {
            // With `.thisEvent`, EventKit doesn't change the series' rule; it
            // detaches this one occurrence and reports success.
            if partOfSeries && span == .this {
                return JSONOutput.error(
                    "Changing the recurrence of '\(title)' needs --span future (this occurrence onwards) "
                        + "or --span all (the whole series).")
            }
            // EventKit mishandles a `.futureEvents` save of a rule through an
            // occurrence that was edited on its own: it splits the series but
            // leaves the occurrence stranded in the old one.
            if addressed.isDetached && span == .future {
                return JSONOutput.error(
                    "This occurrence of '\(title)' was edited on its own, and EventKit can't start a new "
                        + "recurrence from it. Use --span all, or --span future from an occurrence that hasn't "
                        + "been edited.")
            }
            if recurrence.removesRecurrence {
                guard partOfSeries else {
                    return JSONOutput.error("'\(title)' doesn't repeat, so there's no recurrence to remove.")
                }
            } else {
                let rule = recurrence.applying(to: currentRule)
                guard rule.ekRule != nil else {
                    return JSONOutput.error(
                        "'\(title)' doesn't repeat, so there's no recurrence to change. "
                            + "Pass --recurrence-frequency to make it repeat.")
                }
                do {
                    try recurrence.validate(against: rule)
                } catch {
                    return JSONOutput.error("\(error)")
                }
                newRule = rule
            }
        }

        if travelTime != nil && !Self.supportsTravelTime(target) {
            // See `supportsTravelTime` for why the guard is not optional.
            return JSONOutput.error(
                "Travel time is not supported by EventKit on this version of macOS; omit --travel-time.")
        }

        // Times are a clock-time shift of the addressed occurrence, measured
        // in the event's own zone (see `WallClockShift`). For `--span all`
        // the same shift is applied to the series' first occurrence: moving
        // "the 16 March standup" to 11:00 moves every standup to 11:00
        // rather than restarting the series on 16 March.
        let timeZone = target.timeZone ?? .current
        let startShift = startDate.map { WallClockShift(from: addressedStart, to: $0, in: timeZone) }
        let endShift = endDate.map { WallClockShift(from: addressedEnd, to: $0, in: timeZone) }
        let seriesEdit = partOfSeries && span != .this

        // A rule pinned to particular days keeps generating them: moving a
        // Monday-only series to Tuesday would leave its first occurrence on
        // a Tuesday and every other on a Monday. Only the pinned part
        // matters (a Monday series moved a week later is still on Mondays),
        // and only when the caller isn't replacing it.
        if seriesEdit, let shift = startShift, !shift.isZero, let rule = newRule ?? currentRule {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = timeZone
            let moved = shift.applied(to: addressedStart)
            func changes(_ component: Calendar.Component) -> Bool {
                gregorian.component(component, from: addressedStart) != gregorian.component(component, from: moved)
            }
            let pinned: [(Bool, Bool, String)] = [
                (rule.daysOfTheWeek != nil && recurrence.daysOfTheWeek == nil, changes(.weekday),
                 "--recurrence-days"),
                (rule.daysOfTheMonth != nil && recurrence.daysOfTheMonth == nil, changes(.day),
                 "--recurrence-days-of-month"),
                (rule.monthsOfTheYear != nil && recurrence.monthsOfTheYear == nil, changes(.month),
                 "--recurrence-months"),
                ((rule.daysOfTheYear != nil && recurrence.daysOfTheYear == nil)
                    || (rule.weeksOfTheYear != nil && recurrence.weeksOfTheYear == nil),
                 changes(.day) || changes(.month), "--recurrence-days-of-year or --recurrence-weeks-of-year"),
            ]
            if let (_, _, flag) = pinned.first(where: { $0.0 && $0.1 }) {
                return JSONOutput.error(
                    "This moves '\(title)' to a different day, but its recurrence is pinned to particular "
                        + "days, so EventKit would keep repeating on the old ones. Pass the new days with \(flag) "
                        + "as well, or move it to the same day of the week or month.")
            }
        }

        // "From this occurrence on, stop repeating": EventKit ignores a
        // `.futureEvents` save that removes the rule mid-series and strips it
        // from the whole series instead, deleting every occurrence but the
        // first. A one-occurrence rule *does* split the series, so that's
        // saved first and the new series' rule removed afterwards.
        let isFirstOccurrence = first.map {
            abs(($0.occurrenceDate ?? $0.startDate).timeIntervalSince(addressed.occurrenceDate ?? addressedStart)) < 1
        } ?? true
        let endsSeriesHere = recurrence.removesRecurrence && span == .future && !isFirstOccurrence

        // Snapshot the calendar(s) before a series-wide change; see
        // `Snapshot`. The window runs from the series' start to four years
        // past now (or past its start, if that's later), widened by any time
        // shift so both snapshots cover the same occurrences.
        let shiftMargin = abs(startShift?.seconds ?? 0) + 2 * 86_400
        let windowStart = min(first?.startDate ?? targetStart, targetStart).addingTimeInterval(-shiftMargin)
        let windowEnd = max(windowStart, Date()).addingTimeInterval(4 * 365 * 86_400 + shiftMargin)
        let watchedCalendarIDs = [target.calendar, newCalendar].compactMap { $0?.calendarIdentifier }
        let before = seriesEdit
            ? snapshot(from: windowStart, to: windowEnd, calendars: calendars(watchedCalendarIDs)) : nil
        // The slot the target occupied, to measure how far EventKit actually
        // moved the series (see the re-cancelling below).
        let targetSlot = target.occurrenceDate ?? targetStart

        if target === addressed {
            if let startDate = startDate { target.startDate = startDate }
            if let endDate = endDate { target.endDate = endDate }
        } else {
            if let shift = startShift { target.startDate = shift.applied(to: target.startDate) }
            if let shift = endShift { target.endDate = shift.applied(to: target.endDate) }
        }
        if let newTitle = newTitle { target.title = newTitle }
        if let location = location {
            target.location = location
            // Use shared resolver (5s timeout) for consistent behavior with addEvent
            target.structuredLocation = resolveLocation(location)
        }
        if let notes = notes { target.notes = notes }
        if let allDay = allDay { target.isAllDay = allDay }
        if let urlString = url, let urlObj = URL(string: urlString) {
            target.url = urlObj
        }
        if let availability = availability {
            target.availability = availability.ekAvailability
        }
        if let travelTime = travelTime {
            // IMPORTANT: `travelTime` is set using KVC on a private/undocumented property name ("travelTime").
            // This is intentional as EventKit does not expose a public API for travel time.
            target.setValue(travelTime, forKey: Self.travelTimeKey)
        }
        if let alarms = alarms {
            for alarm in target.alarms ?? [] { target.removeAlarm(alarm) }
            for offset in alarms { target.addAlarm(EKAlarm(relativeOffset: offset)) }
        }
        if let addAlarms = addAlarms {
            // An alarm that's already there isn't added twice.
            let existing = Set((target.alarms ?? []).filter { $0.absoluteDate == nil }.map(\.relativeOffset))
            for offset in addAlarms where !existing.contains(offset) {
                target.addAlarm(EKAlarm(relativeOffset: offset))
            }
        }
        if let newCalendar = newCalendar { target.calendar = newCalendar }
        if endsSeriesHere, var single = currentRule {
            single.end = .count(1)
            target.recurrenceRules = single.ekRule.map { [$0] }
        } else if recurrence.removesRecurrence {
            target.recurrenceRules = nil
        } else if let rule = newRule?.ekRule {
            target.recurrenceRules = [rule]
        }

        do {
            try eventStore.save(target, span: span == .this ? .thisEvent : .futureEvents)
        } catch {
            return JSONOutput.error("Failed to update event: \(error.localizedDescription)")
        }

        // Read everything back from the store from here on: objects fetched
        // before a series save can be stale.
        let savedID = target.eventIdentifier ?? eventID
        let savedSeries = EventIdentifiers.seriesID(savedID)
        let addressedID = addressed.eventIdentifier
        let movedThroughFirst = target !== addressed && addressed.isDetached
        let savedStart = target.startDate ?? targetStart
        let split = span == .future && savedSeries != seriesID
        let finalCalendarID = (newCalendar ?? target.calendar)?.calendarIdentifier
        var warnings: [String] = []
        eventStore.reset()

        // `.futureEvents` from mid-series splits it: earlier occurrences keep
        // the old ID, the rest become a new series with a new one. When the
        // save also carries a new rule, EventKit truncates the old series
        // correctly but saves the new one *without* the rule (observed on
        // macOS 26), so it's applied again to the new series' first
        // occurrence. Ending the series here removes the one-occurrence rule
        // saved above the same way.
        if split && (newRule != nil || endsSeriesHere) {
            if let head = eventStore.event(withIdentifier: savedID) {
                if endsSeriesHere {
                    head.recurrenceRules = nil
                } else if var rule = newRule {
                    // A series that ended after N occurrences still ends after
                    // N in total: the new series gets what the old one hadn't
                    // used, unless the caller set a new end or a new rule.
                    if recurrence.frequency == nil && recurrence.end == nil, case .count(let total) = rule.end,
                       case .count(let used)? = eventStore.event(withIdentifier: seriesID)?
                        .recurrenceRules?.first.map({ RecurrenceSpec($0).end })
                    {
                        rule.end = .count(max(1, total - used))
                    }
                    head.recurrenceRules = rule.ekRule.map { [$0] }
                }
                do {
                    try eventStore.save(head, span: .futureEvents)
                } catch {
                    warnings.append(
                        "The series was split at this occurrence (new ID \(savedID)), but its new recurrence "
                            + "couldn't be applied: \(error.localizedDescription). Set it with "
                            + "`ekctl update event \(savedID) --span all` and the --recurrence-* flags.")
                }
            } else {
                warnings.append(
                    "The series was split at this occurrence, but the new series (\(savedID)) couldn't be read "
                        + "back to apply its recurrence. Check it with `ekctl list events`.")
            }
            eventStore.reset()
        }

        // An occurrence edited on its own keeps its own times when the series
        // moves, but the caller gave a time for *this* one: put it there.
        if movedThroughFirst, startDate != nil || endDate != nil, let id = addressedID,
           let occurrence = eventStore.event(withIdentifier: id)
        {
            if let startDate = startDate { occurrence.startDate = startDate }
            if let endDate = endDate { occurrence.endDate = endDate }
            do {
                try eventStore.save(occurrence, span: .thisEvent)
            } catch {
                warnings.append(
                    "The series moved, but this occurrence (edited on its own earlier) couldn't be moved to the "
                        + "time given: \(error.localizedDescription).")
            }
            eventStore.reset()
        }

        // Re-saving a series' rule or moving its start makes EventKit forget
        // which occurrences had been deleted from it (their exclusions are
        // keyed to the old times), so they come back. Any occurrence whose
        // original slot wasn't there before is one of those, and is deleted
        // again. The shift is read from what EventKit actually did to the
        // target's slot, not from the request: saving through an occurrence
        // that was moved on its own rebuilds the series from where it sits.
        //
        // Slots are compared with a few hours' tolerance: EventKit repeats
        // at most daily, so distinct slots are ~23 hours apart or more, while
        // a slot moved into a DST gap lands up to an hour off. Only when the
        // rule produces the same slots as before (unchanged, or only its end
        // changed), and only within the range the old slots covered, so an
        // extended series keeps its new occurrences.
        var recancelled = 0
        let seriesShift = WallClockShift(from: targetSlot, to: savedStart, in: timeZone)
        let slotsKept = recurrence.isEmpty || recurrence.changesOnlyEnd
        if seriesEdit, slotsKept, !recurrence.removesRecurrence, newRule != nil || !seriesShift.isZero,
           let before = before, let previous = before.slots[seriesID], !previous.isEmpty
        {
            let tolerance: TimeInterval = 3 * 3600
            let floatingPrevious = previous.map {
                WallClockShift.floating(Date(timeIntervalSinceReferenceDate: $0), in: timeZone)
            }.sorted()
            // From the series' own first slot (which may itself have been
            // deleted), or from the addressed occurrence for `future`. An
            // unchanged rule produces exactly its old slots, so any newcomer
            // is a returned deletion; a changed end may legitimately add
            // slots past the old last one.
            let lowest = span == .future
                ? WallClockShift.floating(addressed.occurrenceDate ?? addressedStart, in: timeZone)
                : min(floatingPrevious[0], WallClockShift.floating(targetSlot, in: timeZone))
            let highest = recurrence.isEmpty ? .infinity : floatingPrevious[floatingPrevious.count - 1]
            for event in fetchEvents(from: windowStart, to: windowEnd, calendars: calendars(watchedCalendarIDs))
            where EventIdentifiers.seriesID(event.eventIdentifier ?? "") == savedSeries && !event.isDetached {
                let slot = event.occurrenceDate ?? event.startDate!
                let original = WallClockShift.floating(slot, in: timeZone) - seriesShift.seconds
                guard original >= lowest - tolerance, original <= highest + tolerance else { continue }
                if !floatingPrevious.contains(where: { abs($0 - original) <= tolerance }) {
                    do {
                        try eventStore.remove(event, span: .thisEvent)
                        recancelled += 1
                    } catch {
                        warnings.append(
                            "An occurrence deleted earlier came back at \(localDateFormatter.string(from: slot)) "
                                + "and couldn't be removed again: \(error.localizedDescription).")
                    }
                }
            }
            if recancelled > 0 { eventStore.reset() }
        }

        var payload: [String: Any] = [
            "status": "success",
            "message": "Event updated successfully",
            "span": span.rawValue,
        ]
        // The occurrence the caller addressed, as it now stands: where they
        // asked for it, or where the series' move put it. The series' first
        // occurrence (what a `--span all` save goes through) may itself be
        // deleted or moved, so it isn't reported.
        let expected = startDate ?? seriesShift.applied(to: addressed.occurrenceDate ?? addressedStart)
        let saved = fetchEvents(
            from: expected.addingTimeInterval(-2 * 86_400), to: expected.addingTimeInterval(2 * 86_400),
            calendars: calendars([finalCalendarID].compactMap { $0 })
        ).filter {
            $0.eventIdentifier == addressedID || EventIdentifiers.seriesID($0.eventIdentifier ?? "") == savedSeries
        }.min { abs($0.startDate.timeIntervalSince(expected)) < abs($1.startDate.timeIntervalSince(expected)) }
            ?? eventStore.event(withIdentifier: savedID)
        if let saved = saved { payload["event"] = eventToDict(saved) }
        if recancelled > 0 {
            payload["recancelledOccurrences"] = recancelled
            warnings.append(
                "Saving the series brought back \(recancelled) occurrence(s) that had been deleted; "
                    + "they were deleted again.")
        }
        if let before = before {
            let after = snapshot(from: windowStart, to: windowEnd, calendars: calendars(watchedCalendarIDs))
            let affected = sideEffects(before: before, after: after, expected: [seriesID, savedSeries])
            if !affected.isEmpty {
                payload["alsoAffected"] = affected
                if let warning = Self.sideEffectWarning(affected) { warnings.append(warning) }
            }
        }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        return JSONOutput.success(payload)
    }

    /// The event a span-aware change acts on: the addressed occurrence, or,
    /// for `--span all` on a series, the series' first occurrence (saving or
    /// removing that with `.futureEvents` covers every occurrence).
    private func seriesTarget(
        for addressed: EKEvent, span: EventSpan, partOfSeries: Bool
    ) -> EventLookup {
        guard span == .all && partOfSeries else { return .success(addressed) }
        let series = EventIdentifiers.seriesID(addressed.eventIdentifier ?? "")
        guard let first = eventStore.event(withIdentifier: series) else {
            return .failure(JSONOutput.error("Couldn't find the series '\(addressed.title ?? "Untitled")' belongs to."))
        }
        return .success(first)
    }

    private enum CalendarLookup {
        case success(EKCalendar)
        case failure(JSONOutput)
    }

    /// An event calendar that can take new or moved events.
    private func writableEventCalendar(_ calendarID: String) -> CalendarLookup {
        guard let calendar = eventStore.calendar(withIdentifier: calendarID) else {
            return .failure(JSONOutput.error("Calendar not found with ID: \(calendarID)"))
        }
        // `calendar(withIdentifier:)` also resolves Reminders lists.
        guard calendar.allowedEntityTypes.contains(.event) else {
            return .failure(JSONOutput.error(
                "'\(calendar.title)' is a Reminders list, not an event calendar. "
                    + "Run `ekctl list calendars` to find an event calendar."))
        }
        guard calendar.allowsContentModifications else {
            return .failure(JSONOutput.error("Calendar '\(calendar.title)' does not allow modifications."))
        }
        return .success(calendar)
    }

    /// Creates a new calendar event, in `calendarID` or, when nil, the
    /// calendar the user chose for new events in Calendar's settings.
    public func addEvent(
        calendarID: String?,
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        notes: String?,
        allDay: Bool,
        recurrence: RecurrenceSpec = RecurrenceSpec(),
        travelTime: TimeInterval? = nil,
        alarms: [Double]? = nil,
        url: String? = nil,
        availability: AvailabilitySetting? = nil
    ) -> JSONOutput {
        let calendar: EKCalendar
        if let calendarID = calendarID {
            switch writableEventCalendar(calendarID) {
            case .failure(let error): return error
            case .success(let found): calendar = found
            }
        } else {
            guard let defaultCalendar = eventStore.defaultCalendarForNewEvents else {
                return JSONOutput.error(
                    "No default calendar is set for new events. Pass --calendar, or pick a default "
                        + "in Calendar > Settings > General.")
            }
            guard defaultCalendar.allowsContentModifications else {
                return JSONOutput.error(
                    "The default calendar '\(defaultCalendar.title)' does not allow modifications. "
                        + "Pass --calendar.")
            }
            calendar = defaultCalendar
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

        if let availability = availability {
            event.availability = availability.ekAvailability
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

        // Recurrence: parsed and validated by the CLI before the permission
        // prompt (see `RecurrenceParsing`).
        if let rule = recurrence.ekRule {
            event.addRecurrenceRule(rule)
        }

        // Travel Time (Manual) — see `supportsTravelTime` for the KVC guard.
        if let tTime = travelTime {
            guard Self.supportsTravelTime(event) else {
                return JSONOutput.error(
                    "Travel time is not supported by EventKit on this version of macOS; omit --travel-time."
                )
            }
            event.setValue(tTime, forKey: Self.travelTimeKey)
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

    /// Deletes a calendar event: one occurrence, an occurrence and everything
    /// after it, or the whole series (`span`).
    public func deleteEvent(eventID: String, occurrence: Date? = nil, span: EventSpan = .this) -> JSONOutput {
        let addressed: EKEvent
        switch resolveEvent(
            eventID: eventID, occurrence: occurrence, requireOccurrenceForSeries: span != .all)
        {
        case .failure(let error): return error
        case .success(let event): addressed = event
        }
        let partOfSeries = addressed.hasRecurrenceRules || addressed.isDetached
        let seriesID = EventIdentifiers.seriesID(addressed.eventIdentifier ?? eventID)

        let target: EKEvent
        switch seriesTarget(for: addressed, span: span, partOfSeries: partOfSeries) {
        case .failure(let error): return error
        case .success(let event): target = event
        }

        // Rendered before removal: a removed event no longer has its fields.
        let deleted = eventToDict(target)
        let title = target.title ?? "Untitled"
        let message: String
        switch (span, partOfSeries) {
        case (.this, _), (_, false): message = "Event '\(title)' deleted successfully"
        case (.future, true): message = "Event '\(title)' and its later occurrences deleted successfully"
        case (.all, true): message = "All occurrences of '\(title)' deleted successfully"
        }

        // A series-wide removal can cascade into a series split off this one
        // earlier; see `Snapshot`.
        let watch = partOfSeries && span != .this
        let windowStart = (target.startDate ?? Date()).addingTimeInterval(-86_400)
        let windowEnd = max(windowStart, Date()).addingTimeInterval(4 * 365 * 86_400)
        let calendars = [target.calendar].compactMap { $0 }
        let before = watch ? snapshot(from: windowStart, to: windowEnd, calendars: calendars) : nil

        do {
            try eventStore.remove(target, span: span == .this ? .thisEvent : .futureEvents)
        } catch {
            return JSONOutput.error("Failed to delete event: \(error.localizedDescription)")
        }

        var payload: [String: Any] = [
            "status": "success",
            "message": message,
            "deletedEventID": eventID,
            "span": span.rawValue,
            // Not `event`: CSV and text output render a top-level `event` as
            // the row, which would hide the status and message.
            "deletedEvent": deleted,
        ]
        if let before = before {
            eventStore.reset()
            let after = snapshot(from: windowStart, to: windowEnd, calendars: calendars)
            let affected = sideEffects(before: before, after: after, expected: [seriesID])
            if !affected.isEmpty {
                payload["alsoAffected"] = affected
                payload["warnings"] = [Self.sideEffectWarning(affected)].compactMap { $0 }
            }
        }
        return JSONOutput.success(payload)
    }

    // MARK: - Reminder Operations

    /// Lists reminders in a reminder list
    public func listReminders(listID: String, completed: Bool?, search: String? = nil) -> JSONOutput {
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

        if let completed = completed {
            reminders = reminders.filter { $0.isCompleted == completed }
        }
        reminders = reminders.filter { reminder in
            EventFilter.matchesSearch(search, in: [reminder.title, reminder.notes])
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
            var dueComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
            // Attach an explicit time zone so the due date is stored zoned, not
            // floating. A floating dueDateComponents (timeZone == nil) is rendered
            // shifted by the host's UTC offset on iCloud Web, while native EventKit
            // clients treat it as local time.
            dueComponents.timeZone = TimeZone.current
            reminder.dueDateComponents = dueComponents
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
            var dueComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: dueDate
            )
            // Attach an explicit time zone so the due date is stored zoned, not
            // floating (see addReminder for full explanation).
            dueComponents.timeZone = TimeZone.current
            reminder.dueDateComponents = dueComponents
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

    /// Date formatter for all timestamp output — ISO 8601 in the user's local
    /// timezone. Built once per manager (not per item): DateFormatter
    /// construction is comparatively expensive and `listEvents` renders a
    /// timestamp pair for every event returned.
    private lazy var localDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX locale forces 24-hour `HH` to actually mean 24-hour, regardless of the
        // user's "Use 24-hour time" system preference (Apple QA1480). Without this, PM
        // times silently render as 12-hour without an AM/PM marker on locales like en_GB
        // — e.g. 16:00 becomes "4:00" (see issue #8).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeFormat.dateFormatPattern  // ISO 8601 with timezone offset
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// `yyyy-MM-dd` in the local zone, for the `date` field on a free slot.
    /// POSIX locale for the same reason as `localDateFormatter`: the pattern
    /// must mean what it says regardless of the user's regional settings.
    private lazy var localDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// The undocumented EventKit property backing an event's travel time.
    /// EventKit exposes no public API for it, so both the read and the write
    /// go through KVC. `responds(to:)` guards every access: KVC on a key the
    /// class doesn't define raises `NSUnknownKeyException`, an Objective-C
    /// exception Swift cannot catch, so an unguarded call would hard-crash the
    /// CLI if Apple ever drops the property.
    private static let travelTimeKey = "travelTime"

    static func supportsTravelTime(_ event: EKEvent) -> Bool {
        event.responds(to: Selector((travelTimeKey)))
    }

    /// Reads the event's travel time as whole minutes, or nil when unset or
    /// unsupported on this OS. Mirrors the `--travel-time` flag, which is
    /// also expressed in minutes.
    static func travelTimeMinutes(of event: EKEvent) -> Int? {
        guard supportsTravelTime(event),
            let seconds = event.value(forKey: travelTimeKey) as? Double,
            seconds > 0
        else { return nil }
        return Int((seconds / 60).rounded())
    }

    /// Renders alarms in the same units the `--alarms` flag accepts, so output
    /// round-trips back into input: a relative alarm 10 minutes *before* the
    /// start reads `minutesBeforeStart: 10`, matching `--alarms "10"`, and one
    /// 15 minutes *after* reads `-15`, matching `--alarms "+15"`.
    ///
    /// Exposed for tests; `formatter` renders absolute alarm dates so this
    /// stays free of the manager's instance state.
    public static func alarmDicts(
        _ alarms: [EKAlarm]?,
        formatter: (Date) -> String
    ) -> [[String: Any]] {
        guard let alarms = alarms else { return [] }
        return alarms.map { alarm in
            if let absoluteDate = alarm.absoluteDate {
                return ["type": "absolute", "date": formatter(absoluteDate)]
            }
            // EventKit stores relative offsets as negative seconds for "before
            // start"; the flag treats positive as "before", so the sign flips.
            let minutes = Int((-alarm.relativeOffset / 60).rounded())
            return ["type": "relative", "minutesBeforeStart": minutes]
        }
    }

    /// Converts an EKEvent to a dictionary for JSON output
    private func eventToDict(_ event: EKEvent) -> [String: Any] {
        let formatter = localDateFormatter

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
        dict["alarms"] = Self.alarmDicts(event.alarms) { formatter.string(from: $0) }
        if let travelTimeMinutes = Self.travelTimeMinutes(of: event) {
            dict["travelTimeMinutes"] = travelTimeMinutes
        } else {
            dict["travelTimeMinutes"] = NSNull()
        }
        dict["hasRecurrenceRules"] = event.hasRecurrenceRules
        dict["recurrenceRules"] = (event.recurrenceRules ?? []).map {
            RecurrenceSpec($0).outputDict { formatter.string(from: $0) }
        }
        // Every occurrence of a series shares `id`, so this is what tells
        // them apart — and what `--occurrence` takes back.
        if let occurrenceDate = event.occurrenceDate {
            dict["occurrenceDate"] = formatter.string(from: occurrenceDate)
        } else {
            dict["occurrenceDate"] = NSNull()
        }
        dict["isDetached"] = event.isDetached

        dict["availability"] = Self.availabilityString(event.availability)

        if let attendees = event.attendees, !attendees.isEmpty {
            dict["attendees"] = attendees.map { participant -> [String: Any] in
                var entry: [String: Any] = [
                    "name": participant.name ?? "",
                    "status": participantStatusString(participant.participantStatus),
                    "role": participantRoleString(participant.participantRole),
                ]
                // EKParticipant email is encoded in the URL as mailto:
                let url = participant.url
                if url.scheme == "mailto" {
                    entry["email"] = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                }
                return entry
            }
        } else {
            dict["attendees"] = [] as [[String: Any]]
        }

        return dict
    }

    /// Converts an EKReminder to a dictionary for JSON output
    private func reminderToDict(_ reminder: EKReminder) -> [String: Any] {
        let formatter = localDateFormatter

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

// MARK: - AvailabilitySetting → EventKit

extension AvailabilitySetting {
    /// The EKEventAvailability value this CLI setting assigns. Lives here
    /// (not Filters.swift) so the CLI-string enum stays EventKit-free.
    public var ekAvailability: EKEventAvailability {
        switch self {
        case .busy: return .busy
        case .free: return .free
        case .tentative: return .tentative
        case .unavailable: return .unavailable
        }
    }
}

// MARK: - RecurrenceSpec ↔ EventKit

extension RecurrenceSpec {
    /// Reads an existing rule back into the CLI's terms, so an update can
    /// change one part of it and rebuild the rest unchanged.
    init(_ rule: EKRecurrenceRule) {
        self.init()
        switch rule.frequency {
        case .daily: frequency = .some(.daily)
        case .weekly: frequency = .some(.weekly)
        case .monthly: frequency = .some(.monthly)
        case .yearly: frequency = .some(.yearly)
        @unknown default: frequency = nil
        }
        interval = rule.interval
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                self.end = .date(date)
            } else {
                self.end = .count(end.occurrenceCount)
            }
        } else {
            self.end = .never
        }
        daysOfTheWeek = rule.daysOfTheWeek?.map {
            RecurrenceDay(weekday: $0.dayOfTheWeek.rawValue, week: $0.weekNumber)
        }
        monthsOfTheYear = rule.monthsOfTheYear?.map(\.intValue)
        daysOfTheMonth = rule.daysOfTheMonth?.map(\.intValue)
        weeksOfTheYear = rule.weeksOfTheYear?.map(\.intValue)
        daysOfTheYear = rule.daysOfTheYear?.map(\.intValue)
        setPositions = rule.setPositions?.map(\.intValue)
    }

    /// The EventKit rule this spec describes, or nil when it names no
    /// frequency (nothing to build) or removes the recurrence.
    var ekRule: EKRecurrenceRule? {
        guard case .some(.some(let frequency)) = frequency else { return nil }
        let ekFrequency: EKRecurrenceFrequency
        switch frequency {
        case .daily: ekFrequency = .daily
        case .weekly: ekFrequency = .weekly
        case .monthly: ekFrequency = .monthly
        case .yearly: ekFrequency = .yearly
        }
        let ekEnd: EKRecurrenceEnd?
        switch end {
        case .count(let count): ekEnd = EKRecurrenceEnd(occurrenceCount: count)
        case .date(let date): ekEnd = EKRecurrenceEnd(end: date)
        case .never, nil: ekEnd = nil
        }
        func numbers(_ values: [Int]?) -> [NSNumber]? { values.map { $0.map(NSNumber.init(value:)) } }
        return EKRecurrenceRule(
            recurrenceWith: ekFrequency,
            interval: interval ?? 1,
            daysOfTheWeek: daysOfTheWeek?.compactMap { day in
                guard let weekday = EKWeekday(rawValue: day.weekday) else { return nil }
                return day.week == 0
                    ? EKRecurrenceDayOfWeek(weekday)
                    : EKRecurrenceDayOfWeek(weekday, weekNumber: day.week)
            },
            daysOfTheMonth: numbers(daysOfTheMonth),
            monthsOfTheYear: numbers(monthsOfTheYear),
            weeksOfTheYear: numbers(weeksOfTheYear),
            daysOfTheYear: numbers(daysOfTheYear),
            setPositions: numbers(setPositions),
            end: ekEnd
        )
    }

    /// Output form, using the flag names' vocabulary so a rule read from one
    /// event can be handed back to `--recurrence-*` on another.
    func outputDict(formatDate: (Date) -> String) -> [String: Any] {
        var dict: [String: Any] = [:]
        if case .some(.some(let frequency)) = frequency { dict["frequency"] = frequency.rawValue }
        dict["interval"] = interval ?? 1
        func list<T>(_ values: [T]?) -> Any { values.map { $0 as Any } ?? NSNull() }
        dict["daysOfTheWeek"] = list(daysOfTheWeek?.map(\.formatted))
        dict["monthsOfTheYear"] = list(monthsOfTheYear)
        dict["daysOfTheMonth"] = list(daysOfTheMonth)
        dict["weeksOfTheYear"] = list(weeksOfTheYear)
        dict["daysOfTheYear"] = list(daysOfTheYear)
        dict["setPositions"] = list(setPositions)
        switch end {
        case .count(let count):
            dict["endCount"] = count
            dict["endDate"] = NSNull()
        case .date(let date):
            dict["endCount"] = NSNull()
            dict["endDate"] = formatDate(date)
        case .never, nil:
            dict["endCount"] = NSNull()
            dict["endDate"] = NSNull()
        }
        return dict
    }
}

// MARK: - EKParticipant Helpers

private func participantStatusString(_ status: EKParticipantStatus) -> String {
    switch status {
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "tentative"
    case .pending: return "pending"
    case .delegated: return "delegated"
    case .completed: return "completed"
    case .inProcess: return "inProcess"
    default: return "unknown"
    }
}

private func participantRoleString(_ role: EKParticipantRole) -> String {
    switch role {
    case .required: return "required"
    case .optional: return "optional"
    case .chair: return "chair"
    case .nonParticipant: return "nonParticipant"
    default: return "unknown"
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
