# ekctl

Native macOS command-line tool for managing Calendar events and Reminders using EventKit. Output is JSON by default, with `--format csv` and `--format text` available on every command for spreadsheets and quick eyeballing.

## Features

- List, create, update, and delete calendar events
- List, create, update, complete, and delete reminders
- Human date input on every flag — `--start "tomorrow 9am"`, `--from today`, `--to +2w`
- Quick date-range shortcuts: `ekctl today`, `ekctl tomorrow`, `ekctl next`
- Find open time across calendars with `ekctl free` — working hours, buffers, and multi-calendar merging
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
curl -L -o ekctl.tar.gz https://github.com/schappim/ekctl/releases/download/v1.7.0/ekctl-v1.7.0.tar.gz
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
      "alarms": [
        { "type": "relative", "minutesBeforeStart": 10 }
      ],
      "travelTimeMinutes": null,
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
    "alarms": [
      { "type": "relative", "minutesBeforeStart": 10 },
      { "type": "relative", "minutesBeforeStart": 30 }
    ],
    "travelTimeMinutes": 20,
    "hasRecurrenceRules": false
  }
}
```

### Alarms and travel time

`--alarms` takes comma-separated minutes and **replaces** every existing alarm on
the event (it does not append). A bare number means minutes *before* the start; a
leading `+` means minutes *after*:

```bash
ekctl update event EVENT_ID --alarms "10,60"   # 10 min and 1 hour before
ekctl update event EVENT_ID --alarms "+15"     # 15 min after the start
ekctl update event EVENT_ID --alarms "0"       # at the start
```

Both fields are echoed back in the event JSON, in the same units the flags accept,
so output round-trips into input:

```json
"alarms": [
  { "type": "relative", "minutesBeforeStart": 10 },
  { "type": "relative", "minutesBeforeStart": -15 },
  { "type": "absolute", "date": "2026-02-15T08:00:00+11:00" }
],
"travelTimeMinutes": 20
```

`minutesBeforeStart` is negative for an alarm that fires *after* the start, matching
the `+` flag form. Alarms set outside ekctl may be absolute rather than relative, in
which case they carry a `date` instead. EventKit does not preserve the order alarms
were supplied in, so read them as a set.

Two things worth knowing:

- `hasAlarms` is **not** evidence that your `--alarms` took effect. Calendars apply a
  default alarm to new events, so a freshly created event usually reports
  `hasAlarms: true` with an alarm you never asked for. Check `alarms` instead.
- `travelTimeMinutes` is `null` when unset. EventKit exposes no public API for travel
  time, so ekctl reads and writes it through KVC on an undocumented property; if a
  future macOS drops it, `--travel-time` returns a clear error rather than crashing.

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

## Finding Free Time

`ekctl free` answers the question `list events` can't: not what's booked, but what isn't. It merges the busy intervals from every calendar you name, clips them to your working hours day by day, and reports the gaps big enough to be useful.

```bash
ekctl free --calendar work --duration 30
```

**Output:**

```json
{
  "count": 2,
  "minimumDurationMinutes": 30,
  "slots": [
    {
      "startDate": "2026-09-07T09:00:00+10:00",
      "endDate": "2026-09-07T10:00:00+10:00",
      "durationMinutes": 60,
      "date": "2026-09-07",
      "weekday": "monday"
    },
    {
      "startDate": "2026-09-07T11:00:00+10:00",
      "endDate": "2026-09-07T13:00:00+10:00",
      "durationMinutes": 120,
      "date": "2026-09-07",
      "weekday": "monday"
    }
  ],
  "searchedFrom": "2026-09-07T08:15:00+10:00",
  "searchedTo": "2026-09-14T08:15:00+10:00",
  "workingHours": "09:00-17:00",
  "weekdays": "monday,tuesday,wednesday,thursday,friday",
  "busyEventCount": 11,
  "status": "success"
}
```

Each slot is a *maximal* gap, so its `durationMinutes` tells you how much room you actually have — `--duration` is the minimum a gap must reach to be reported, not the size of the slot returned, and it's echoed back at the top level as `minimumDurationMinutes`. Slots come back in chronological order, and use the same `startDate` / `endDate` field names as events.

### Options

| Flag | Default | Description |
| ------ | --------- | ------------- |
| `--calendar` | *required* | Calendar ID or alias. Comma-separated for several (`work,personal`) — their events are merged into one busy view. |
| `--duration` | `30` | Minimum usable slot length, in minutes. |
| `--from` | now | Search start (ISO 8601). |
| `--to` | `--days` after the start | Search end (ISO 8601). |
| `--days` | `7` | How far ahead to search when `--to` is omitted. |
| `--working-hours` | `09:00-17:00` | Daily window. `all` searches the whole day; overnight windows like `22:00-02:00` are supported. |
| `--weekdays` | `weekdays` | `mon,wed,fri`, a range (`mon-fri`, `fri-mon` wraps), or `weekdays` / `weekends` / `all`. An overnight window belongs to the day it *opens*, so `--working-hours 22:00-02:00 --weekdays mon-fri` includes Friday 22:00 – Saturday 02:00. |
| `--buffer` | `0` | Minutes to leave either side of every meeting, so back-to-back slots aren't proposed. |
| `--round` | `0` | Round slot starts up to the next multiple of N minutes (e.g. `15`), instead of whenever the previous meeting ended. |
| `--limit` | `20` | Maximum slots to return. |
| `--ignore-all-day` | off | Drop all-day events entirely instead of honouring their availability. |

### What counts as busy

An event blocks its time unless *you've already said it doesn't*:

- **Marked free** — `availability: free` never blocks. Everything else does, including `tentative`, `unavailable`, and the `notSupported` that calendars without availability report.
- **Cancelled** — an event with a cancelled status doesn't block.
- **Declined** — an invitation you declined isn't a commitment, so it doesn't block.
- **All-day events** block according to their availability like anything else, so a busy all-day "Offsite" takes out the day while a free all-day birthday doesn't. Pass `--ignore-all-day` to skip them regardless.

The rule leans on the availability you (or your calendar server) already recorded rather than guessing from event titles.

### Examples

```bash
# An hour, in the next fortnight, with 15 minutes' padding around every meeting
ekctl free --calendar work,personal --duration 60 --days 14 --buffer 15

# Early starts and Fridays off, with times landing on the quarter hour
ekctl free --calendar work --working-hours 08:00-16:00 --weekdays mon-thu --round 15

# Any time at all this weekend — for scheduling that isn't work
ekctl free --calendar personal --working-hours all --weekdays weekends

# Human-readable, for eyeballing
ekctl free --calendar work --duration 45 --format text
```

The earliest workable start time, as a one-liner:

```bash
ekctl free --calendar work --duration 30 --limit 1 | jq -r '.slots[0].startDate'
```

Slots are a first-class row type in CSV and text output, the same as events and reminders:

```bash
ekctl free --calendar work --duration 30 --days 30 --format csv > openings.csv
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

All date **inputs** (`--from`, `--to`, `--start`, `--end`, `--due`, `--recurrence-end-date`) accept either a full ISO 8601 timestamp or a shorthand. The two are interchangeable everywhere:

```bash
ekctl add event --calendar work --title Standup --start "tomorrow 9am" --end "tomorrow 9:15am"
ekctl list events --calendar work --from today --to +1w
ekctl add reminder --list personal --title "Call the dentist" --due "fri 5pm"
```

### Shorthand

| Form | Example | Means |
| ------ | --------- | ------- |
| Now | `now` | The current instant |
| Offset | `+90m`, `-2h`, `+3d`, `+1w` | From now. Units: `m`/`min`, `h`/`hr`, `d`/`day`, `w`/`week` |
| Named day | `today`, `tomorrow`, `yesterday` | Local midnight of that day |
| Weekday | `fri`, `friday` | The next Friday, **today included** |
| Qualified weekday | `next fri`, `last fri` | The next / previous Friday, **today excluded** |
| Week | `next week`, `last week` | Seven days either side of today |
| Plain date | `2026-02-01` | Local midnight |
| Time | `14:30`, `3pm`, `9:15am` | That time today |
| Named time | `noon`, `midnight` | |
| Day + time | `tomorrow 3pm`, `next fri at 09:00`, `2026-02-01 14:30` | Any day above with any time above |

Case doesn't matter, and `at` is optional filler. A bare day resolves to the *start* of that day, which is what `--from tomorrow` should mean.

A bare number like `9` is **rejected**, not guessed — it could be 9am or the 9th, and being wrong there books a meeting three weeks out. Write `9am` or `09:00`. Months and years are not offset units for the same reason: `+3m` is unambiguously 3 minutes.

Times are grafted onto days by wall clock, so `tomorrow 09:00` is 9am even on the day the clocks change.

### ISO 8601

Accepted with any of these timezone suffixes, with or without fractional seconds. ISO is matched first, so a timestamp always parses as itself:

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

The `today` / `tomorrow` / `next` subcommands work out the date range locally, and they accept the same `--search`, `--availability`, and `--format` flags as `list events`. (For anything they don't cover, `--from` and `--to` take the same shorthand — `--from today --to +1w` — so there's no need to wrangle `date -v+1d` either.)

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

### Find a slot and book it

`free` and `add event` compose — the slot's `start` is already in a format `--start` accepts:

```bash
# --time-format compact so jq's strptime can read the offset (see Date Format)
SLOT=$(ekctl free --calendar work --duration 30 --limit 1 --time-format compact)
START=$(echo "$SLOT" | jq -r '.slots[0].startDate')
END=$(echo "$SLOT" | jq -r '.slots[0].startDate as $s | $s
  | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime + 1800
  | strftime("%Y-%m-%dT%H:%M:%S") + $s[19:]')

ekctl add event --calendar work --title "Focus block" --start "$START" --end "$END"
```

`+ $s[19:]` re-attaches the slot's own UTC offset. Don't be tempted to write
`strftime("%Y-%m-%dT%H:%M:%SZ")` instead: jq's `strptime` hands back *local*
wall-clock fields and `mktime` reads them back as UTC, so labelling the result
`Z` books an event wrong by your whole UTC offset — a 30-minute focus block
becomes ten and a half hours in Sydney, and ends before it starts in New York.
This recipe relies on ekctl rendering timestamps in your machine's own zone; it
isn't a general-purpose converter for timestamps from elsewhere.

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
