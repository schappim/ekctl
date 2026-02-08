# ekctl

Native macOS command-line tool for managing Calendar events and Reminders using EventKit. All output is JSON for scripting and automation.

## Features

- List, create, update, and delete calendar events
- List, create, complete, and delete reminders
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

### List

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

### Create

**Command:**
```bash
ekctl calendar create --title "Project X" --color "#FF5500"
```

### Update

**Command:**
```bash
ekctl calendar update CALENDAR_ID --title "New Name" --color "#00FF00"
```

### Delete

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

### List

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

### Show

**Command:**
```bash
ekctl show event EVENT_ID
```

### Add

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

### Delete

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

### List

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

### Show

**Command:**
```bash
ekctl show reminder REMINDER_ID
```

### Add

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

### Complete

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

### Delete

**Command:**
```bash
ekctl delete reminder REMINDER_ID
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