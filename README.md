# ekctl

Native macOS command-line tool for managing Calendar events and Reminders using EventKit. Output is JSON by default, with `--format csv` and `--format text` available on every command for spreadsheets and quick eyeballing.

## Features

- List, create, update, and delete calendar events
- List, create, update, complete, and delete reminders
- Quick date-range shortcuts: `ekctl today`, `ekctl tomorrow`, `ekctl next`
- Search and filter (`--search`, `--availability busy`) without piping through jq
- Calendar aliases (use friendly names instead of UUIDs)
- JSON, CSV, or plain-text output (`--format json|csv|text`)
- RFC 3339 or jq-friendly compact timestamps (`--time-format rfc3339|compact`)
- Full EventKit integration with proper permission handling
- Support for iCloud, Exchange, and local calendars

## Requirements

- macOS 13.0 (Ventura) or later
- Building from source additionally requires a full Xcode installation
  (the Command Line Tools alone currently fail on the SwiftPM manifest);
  the prebuilt release binary has no build-time requirements

## Installation

### Prebuilt binary (no Xcode required)

Every release ships a prebuilt universal (Apple Silicon + Intel) binary —
pick the latest from the [releases page](https://github.com/schappim/ekctl/releases):

```bash
curl -L -o ekctl.tar.gz https://github.com/schappim/ekctl/releases/download/v1.5.0/ekctl-v1.5.0.tar.gz
tar -xzf ekctl.tar.gz
xattr -d com.apple.quarantine ekctl   # release binaries are ad-hoc signed, not notarized
sudo mv ekctl /usr/local/bin/
```

A `.sha256` checksum is published next to each tarball.

### Homebrew

```bash
brew tap schappim/ekctl
brew install ekctl
```

### Build from source

```bash
git clone https://github.com/schappim/ekctl.git
cd ekctl
swift build -c release

# Optional: Sign with entitlements
codesign --force --sign - --entitlements ekctl.entitlements .build/release/ekctl

# Install
sudo cp .build/release/ekctl /usr/local/bin/
```

### Permissions

On first run, macOS will prompt for access to the data the command touches — Calendars, Reminders, or both (e.g., `ekctl list calendars` lists both stores). Commands only request what they need, so a reminders-only workflow never triggers the Calendar prompt. Manage permissions in **System Settings → Privacy & Security → Calendars / Reminders**.

## Calendars

### List Calendars

**Command:**

```bash
ekctl list calendars
```

**Output:**

```json
{
  "calendars": [
    {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work",
      "type": "event",
      "source": "iCloud",
      "color": "#0088FF",
      "allowsModifications": true
    }
  ],
  "status": "success"
}
```

### Create Calendar

**Command:**

```bash
ekctl calendar create --title "Project X" --color "#FF5500"
```

### Update Calendar

**Command:**

```bash
ekctl calendar update CALENDAR_ID --title "New Name" --color "#00FF00"
```

### Delete Calendar

**Command:**

```bash
ekctl calendar delete CALENDAR_ID
```

### Aliases

Use friendly names instead of UUIDs. Aliases work anywhere a calendar ID is accepted.

**Set alias:**

```bash
ekctl alias set work "CA513B39-1659-4359-8FE9-0C2A3DCEF153"
ekctl alias set personal "4E367C6F-354B-4811-935E-7F25A1BB7D39"
```

**List aliases:**

```bash
ekctl alias list
```

**Output:**

```json
{
  "aliases": [
    { "name": "groceries", "id": "E30AE972-8F29-40AF-BFB9-E984B98B08AB" },
    { "name": "personal", "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39" },
    { "name": "work", "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153" }
  ],
  "count": 3,
  "configPath": "/Users/you/.ekctl/config.json",
  "status": "success"
}
```

**Remove alias:**

```bash
ekctl alias remove work
```

**Usage:**

```bash
# These are equivalent:
ekctl list events --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
ekctl list events --calendar work --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
```

Aliases are stored in `~/.ekctl/config.json`.

## Events

### List Events

**Command:**

```bash
ekctl list events --calendar work --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
```

To fetch events from multiple calendars in a single call, pass a comma-separated list of IDs or aliases. Each event's source calendar is reported in its `calendar` field, so the merged stream is still distinguishable:

```bash
ekctl list events --calendar work,personal --from "2026-01-01T00:00:00Z" --to "2026-01-31T23:59:59Z"
```

**Filtering:**

Narrow the result set further with `--search` (case-insensitive substring across title, location, and notes) and `--availability` (one of `busy`, `free`, `tentative`, `unavailable`, `notSupported`). Both filters compose with each other and with the calendar/date selection:

```bash
# Just the standup-related events
ekctl list events --calendar work --from "$NOWISH" --to "$TOMORROW" --search standup

# Only "busy" events — useful for finding actual blocked-out time
ekctl list events --calendar work --from "$NOWISH" --to "$TOMORROW" --availability busy

# Combine — standups marked busy
ekctl list events --calendar work --from "$NOWISH" --to "$TOMORROW" --search standup --availability busy
```

**Output:**

```json
{
  "count": 2,
  "events": [
    {
      "id": "ABC123:DEF456",
      "title": "Team Meeting",
      "calendar": {
        "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
        "title": "Work"
      },
      "startDate": "2026-01-15T09:00:00Z",
      "endDate": "2026-01-15T10:00:00Z",
      "location": "Conference Room A",
      "notes": null,
      "allDay": false,
      "hasAlarms": true,
      "hasRecurrenceRules": false,
      "availability": "busy",
      "attendees": []
    }
  ],
  "status": "success"
}
```

### Quick date ranges: `today` / `tomorrow` / `next`

Three top-level shortcuts wrap the most common `list events` queries with a pre-computed local date range. No more `date -u -v+1d` shell prelude (which is BSD-only and breaks on Linux):

```bash
# Events occurring today (local time)
ekctl today --calendar work

# Events occurring tomorrow
ekctl tomorrow --calendar work

# The single next upcoming event (looks 90 days ahead by default)
ekctl next --calendar work

# The next N events
ekctl next --calendar work --count 5

# Look further out
ekctl next --calendar work --count 5 --days 365
```

All three accept the same filter / format flags as `list events` (`--search`, `--availability`, `--format`, and comma-separated `--calendar`), so they compose:

```bash
ekctl today --calendar work,personal --availability busy --format csv
ekctl next --calendar work --search standup --count 3 --format text
```

`next` returns events sorted by start time ascending and includes events that are currently in progress (their `endDate` is still in the future).

### Show Event

**Command:**

```bash
ekctl show event EVENT_ID
```

### Add Event

Basic event:

```bash
ekctl add event --calendar work --title "Lunch" --start "2026-02-10T12:30:00Z" --end "2026-02-10T13:30:00Z"
```

With location, notes, and alarms:

```bash
ekctl add event \
  --calendar work \
  --title "Project Review" \
  --start "2026-02-15T14:00:00Z" \
  --end "2026-02-15T15:30:00Z" \
  --location "Building 2, Room 301" \
  --notes "Bring Q1 reports" \
  --alarms "10,60"
```

Recurring event (weekly):

```bash
ekctl add event \
  --calendar personal \
  --title "Gym" \
  --start "2026-02-12T18:00:00Z" \
  --end "2026-02-12T19:00:00Z" \
  --recurrence-frequency weekly \
  --recurrence-days "mon,wed,fri" \
  --recurrence-end-count 20
```

With travel time:

```bash
ekctl add event \
  --calendar work \
  --title "Client Site Visit" \
  --start "2026-02-20T14:00:00Z" \
  --end "2026-02-20T16:00:00Z" \
  --location "1 Infinite Loop, Cupertino, CA" \
  --travel-time 30
```

**Output:**

```json
{
  "status": "success",
  "message": "Event created successfully",
  "event": {
    "id": "NEW123:EVENT456",
    "title": "Lunch",
    "calendar": {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work"
    },
    "startDate": "2026-02-10T12:30:00Z",
    "endDate": "2026-02-10T13:30:00Z",
    "location": null,
    "notes": null,
    "allDay": false
  }
}
```

### Update Event

All flags are optional — only the fields you pass will be changed:

```bash
ekctl update event EVENT_ID --title "New title"
```

With multiple fields:

```bash
ekctl update event EVENT_ID \
  --title "Updated title" \
  --start "2026-02-15T14:00:00Z" \
  --end "2026-02-15T15:30:00Z" \
  --location "Building 2, Room 301" \
  --notes "Updated notes" \
  --alarms "10,30" \
  --travel-time 20 \
  --availability busy \
  --url "https://example.com/meeting"
```

**Output:**

```json
{
  "status": "success",
  "message": "Event updated successfully",
  "event": {
    "id": "ABC123:DEF456",
    "title": "Updated title",
    "calendar": {
      "id": "CA513B39-1659-4359-8FE9-0C2A3DCEF153",
      "title": "Work"
    },
    "startDate": "2026-02-15T14:00:00+08:00",
    "endDate": "2026-02-15T15:30:00+08:00",
    "location": "Building 2, Room 301",
    "notes": "Updated notes",
    "allDay": false,
    "hasAlarms": true,
    "hasRecurrenceRules": false
  }
}
```

### Delete Event

**Command:**

```bash
ekctl delete event EVENT_ID
```

**Output:**

```json
{
  "status": "success",
  "message": "Event 'Team Meeting' deleted successfully",
  "deletedEventID": "ABC123:DEF456"
}
```

## Reminders

### List Reminders

All reminders:

```bash
ekctl list reminders --list personal
```

Only incomplete:

```bash
ekctl list reminders --list personal --completed false
```

Only completed:

```bash
ekctl list reminders --list personal --completed true
```

Substring filter on title and notes:

```bash
ekctl list reminders --list personal --search milk
```

**Output:**

```json
{
  "count": 2,
  "reminders": [
    {
      "id": "REM123-456-789",
      "title": "Buy groceries",
      "list": {
        "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
        "title": "Reminders"
      },
      "dueDate": "2026-01-20T17:00:00Z",
      "completed": false,
      "priority": 0,
      "notes": null
    }
  ],
  "status": "success"
}
```

### Show Reminder

**Command:**

```bash
ekctl show reminder REMINDER_ID
```

### Add Reminder

Simple reminder:

```bash
ekctl add reminder --list personal --title "Call dentist"
```

With due date:

```bash
ekctl add reminder --list personal --title "Submit expense report" --due "2026-01-25T09:00:00Z"
```

With priority and notes (priority: 0=none, 1=high, 5=medium, 9=low):

```bash
ekctl add reminder \
  --list groceries \
  --title "Buy milk" \
  --due "2026-02-01T12:00:00Z" \
  --priority 1 \
  --notes "Check expiration date"
```

**Output:**

```json
{
  "status": "success",
  "message": "Reminder created successfully",
  "reminder": {
    "id": "NEWREM-123-456",
    "title": "Submit expense report",
    "list": {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders"
    },
    "dueDate": "2026-01-25T09:00:00Z",
    "completed": false,
    "priority": 0,
    "notes": null
  }
}
```

### Update Reminder

**Command:**

```bash
ekctl update reminder REMINDER_ID --title "New title" --due "2026-02-01T09:00:00Z" --priority 1 --notes "Updated notes"
```

All flags are optional — only the fields you pass will be changed:

```bash
# Just change the title
ekctl update reminder REMINDER_ID --title "Renamed reminder"

# Bump priority and add a due date
ekctl update reminder REMINDER_ID --priority 1 --due "2026-03-10T09:00:00Z"

# Mark as completed via update (same effect as complete command)
ekctl update reminder REMINDER_ID --completed true
```

**Output:**

```json
{
  "status": "success",
  "message": "Reminder updated successfully",
  "reminder": {
    "id": "REM123-456-789",
    "title": "New title",
    "list": {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders"
    },
    "dueDate": "2026-02-01T09:00:00+08:00",
    "completed": false,
    "priority": 1,
    "notes": "Updated notes"
  }
}
```

### Complete Reminder

**Command:**

```bash
ekctl complete reminder REMINDER_ID
```

**Output:**

```json
{
  "status": "success",
  "message": "Reminder 'Buy groceries' marked as completed",
  "reminder": {
    "id": "REM123-456-789",
    "title": "Buy groceries",
    "completed": true,
    "completionDate": "2026-01-21T10:30:00Z"
  }
}
```

### Delete Reminder

**Command:**

```bash
ekctl delete reminder REMINDER_ID
```

## Date Format

All date **inputs** (`--from`, `--to`, `--start`, `--end`, `--due`, `--recurrence-end-date`) accept **ISO 8601** with any of these timezone suffixes, with or without fractional seconds:

| Format | Example | Description |
| -------- | --------- | ------------- |
| UTC | `2026-01-15T09:00:00Z` | 9:00 AM UTC |
| Offset with colon | `2026-01-15T09:00:00+10:00` | 9:00 AM AEST (RFC 3339) |
| Compact offset | `2026-01-15T09:00:00+1000` | Same instant, jq-style `%z` form |

Timestamps in **output** are rendered in your local timezone and are always valid input, so values round-trip between commands. The rendering is controlled by `--time-format` on every command:

- `--time-format rfc3339` (default): colon-separated offset, `Z` for UTC — `2026-01-15T20:00:00+11:00`
- `--time-format compact`: no colon, and `+0000` instead of `Z` — `2026-01-15T20:00:00+1100`

`compact` exists because jq's `strptime` understands the `%z` offset form (`+1100`) but not the colon-separated `%:z` form (`+11:00`), so it can post-process ekctl timestamps directly:

```bash
# "09:00AM Standup" — the next 5 events with 12-hour start times
ekctl next --calendar work --count 5 --time-format compact |
  jq -r '.events[] | "\(.startDate | strptime("%Y-%m-%dT%H:%M:%S%z") | strftime("%I:%M%p")) \(.title)"'
```

## Scripting Examples

### Get calendar ID by name

```bash
CALENDAR_ID=$(ekctl list calendars | jq -r '.calendars[] | select(.title == "Work") | .id')
echo $CALENDAR_ID
```

### List today's events

```bash
ekctl today --calendar "$CALENDAR_ID"
```

The `today` / `tomorrow` / `next` subcommands work out the date range locally so you don't have to wrangle `date -v+1d` (which is BSD-only and breaks under Linux), and they accept the same `--search`, `--availability`, and `--format` flags as `list events`:

```bash
# Tomorrow's busy meetings as CSV
ekctl tomorrow --calendar work --availability busy --format csv

# Next 3 events that mention "standup"
ekctl next --calendar work --count 3 --search standup
```

### Create event from variables

```bash
TITLE="Sprint Planning"
START="2026-01-20T10:00:00Z"
END="2026-01-20T11:00:00Z"

ekctl add event \
  --calendar "$CALENDAR_ID" \
  --title "$TITLE" \
  --start "$START" \
  --end "$END"
```

### Count incomplete reminders

```bash
ekctl list reminders --list "$LIST_ID" --completed false | jq '.count'
```

### Export events to CSV

Use the built-in `--format csv` flag — no jq pipeline required. The CSV header is the union of every field across the returned events, so new fields like `availability` and `attendees` are picked up automatically as they're added:

```bash
ekctl list events \
  --calendar "$CALENDAR_ID" \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-12-31T23:59:59Z" \
  --format csv \
  > events.csv
```

Nested objects flatten to dot-notated columns (e.g., `calendar.id`, `calendar.title`), and nested arrays (like `attendees`) become a single JSON-encoded cell.

### Human-readable plain text

`--format text` emits one `key: value` line per field, with a blank line between items — handy for `grep`, eyeballing, or quick `head`/`tail` checks:

```bash
ekctl list events --calendar work --from "$TODAY" --to "$TOMORROW" --format text
```

## Error Handling

All errors return JSON with `status: "error"`:

```json
{
  "status": "error",
  "error": "Calendar not found with ID: invalid-id"
}
```

Common errors:

- `Permission denied`: Grant access in System Settings → Privacy & Security → Calendars/Reminders
- `Calendar not found`: Check calendar ID with `ekctl list calendars`
- `Invalid date format`: Use ISO 8601 (e.g., `2026-01-15T09:00:00Z`, `+10:00`, or `+1000` offsets — see [Date Format](#date-format))

Exit codes: `0` success, `1` failure, `2` permission denied, `64` invalid usage (bad flags/values).

## Help

```bash
ekctl --help
ekctl list --help
ekctl add event --help
```

## License

MIT License

## Contributing

Pull requests welcome.

## Who made this?

ekctl was made by [Marcus Schappi](https://twitter.com/schappim). I create software (and even hardware) for real-world businesses, including:

* **[Little Bird Electronics](https://littlebirdelectronics.com.au/)** — Australia's electronics and STEM store, shipping Australia-wide. We sell [Arduino](https://littlebirdelectronics.com.au/collections/arduino), [Raspberry Pi](https://littlebirdelectronics.com.au/collections/raspberry-pi), [micro:bit](https://littlebirdelectronics.com.au/collections/micro-bit), [STEM and STEAM education kits](https://littlebirdelectronics.com.au/collections/stem-education), [e-textiles](https://littlebirdelectronics.com.au/collections/e-textiles), [robotics](https://littlebirdelectronics.com.au/collections/robotics), [sensors](https://littlebirdelectronics.com.au/collections/sensors) and [electronic components](https://littlebirdelectronics.com.au/collections/components).
* **[Struth.app](https://struth.app/)** — AI runs and grows your trade business. The Struth platform is field service management + CRM + AI.
