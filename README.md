# ekctl

Native macOS command-line tool for managing Calendar events and Reminders using EventKit. All output is JSON for scripting and automation.

## Features

- List, create, update, and delete calendar events
- List, create, update, complete, and delete reminders
- Calendar aliases (use friendly names instead of UUIDs)
- JSON output for parsing
- Full EventKit integration with proper permission handling
- Support for iCloud, Exchange, and local calendars

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools or Xcode
- Swift 5.9+

## Installation

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

On first run, macOS will prompt for Calendar and Reminders access. Manage permissions in **System Settings → Privacy & Security → Calendars / Reminders**.

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
      "hasRecurrenceRules": false
    }
  ],
  "status": "success"
}
```

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

All dates use **ISO 8601** format with timezone. Examples:

| Format | Example | Description |
| -------- | --------- | ------------- |
| UTC | `2026-01-15T09:00:00Z` | 9:00 AM UTC |
| With offset | `2026-01-15T09:00:00+10:00` | 9:00 AM AEST |
| Midnight | `2026-01-15T00:00:00Z` | Start of day |
| End of day | `2026-01-15T23:59:59Z` | End of day |

## Scripting Examples

### Get calendar ID by name

```bash
CALENDAR_ID=$(ekctl list calendars | jq -r '.calendars[] | select(.title == "Work") | .id')
echo $CALENDAR_ID
```

### List today's events

```bash
TODAY=$(date -u +"%Y-%m-%dT00:00:00Z")
TOMORROW=$(date -u -v+1d +"%Y-%m-%dT00:00:00Z")

ekctl list events \
  --calendar "$CALENDAR_ID" \
  --from "$TODAY" \
  --to "$TOMORROW"
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

```bash
ekctl list events \
  --calendar "$CALENDAR_ID" \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-12-31T23:59:59Z" \
  | jq -r '.events[] | [.title, .startDate, .endDate, .location // ""] | @csv'
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
- `Invalid date format`: Use ISO 8601 format (YYYY-MM-DDTHH:MM:SSZ)

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
