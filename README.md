# ekctl

A native macOS command-line tool for managing Calendar events and Reminders using the EventKit framework. All output is JSON, making it perfect for scripting and automation.

## Features

- List, create, and delete calendar events
- List, create, complete, and delete reminders
- JSON output for easy parsing and scripting
- Full EventKit integration with proper permission handling
- Support for all calendar and reminder list types (iCloud, Exchange, local, etc.)

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode Command Line Tools or Xcode
- Swift 5.9+

## Installation

### Build from Source

```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/ekctl.git
cd ekctl

# Build release version
swift build -c release

# Optional: Sign with entitlements for better permission handling
codesign --force --sign - --entitlements ekctl.entitlements .build/release/ekctl

# Install to /usr/local/bin
sudo cp .build/release/ekctl /usr/local/bin/
```

### First Run

On first run, macOS will prompt you to grant access to Calendars and Reminders. You can manage these permissions later in:

**System Settings → Privacy & Security → Calendars / Reminders**

## Usage

### List Calendars

List all calendars (event calendars and reminder lists):

```bash
ekctl list calendars
```

Output:
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
    },
    {
      "id": "4E367C6F-354B-4811-935E-7F25A1BB7D39",
      "title": "Reminders",
      "type": "reminder",
      "source": "iCloud",
      "color": "#1BADF8",
      "allowsModifications": true
    }
  ],
  "status": "success"
}
```

### List Events

List events in a calendar within a date range:

```bash
# List events for January 2026
ekctl list events \
  --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" \
  --from "2026-01-01T00:00:00Z" \
  --to "2026-01-31T23:59:59Z"
```

Output:
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

### Show Event Details

```bash
ekctl show event "ABC123:DEF456"
```

### Add Event

Create a new calendar event:

```bash
# Basic event
ekctl add event \
  --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" \
  --title "Lunch with Client" \
  --start "2026-02-10T12:30:00Z" \
  --end "2026-02-10T13:30:00Z"

# Event with location and notes
ekctl add event \
  --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" \
  --title "Project Review" \
  --start "2026-02-15T14:00:00Z" \
  --end "2026-02-15T15:30:00Z" \
  --location "Building 2, Room 301" \
  --notes "Bring Q1 reports"

# All-day event
ekctl add event \
  --calendar "CA513B39-1659-4359-8FE9-0C2A3DCEF153" \
  --title "Company Holiday" \
  --start "2026-03-01T00:00:00Z" \
  --end "2026-03-02T00:00:00Z" \
  --all-day
```

Output:
```json
{
  "status": "success",
  "message": "Event created successfully",
  "event": {
    "id": "NEW123:EVENT456",
    "title": "Lunch with Client",
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

### Delete Event

```bash
ekctl delete event "ABC123:DEF456"
```

Output:
```json
{
  "status": "success",
  "message": "Event 'Team Meeting' deleted successfully",
  "deletedEventID": "ABC123:DEF456"
}
```

### List Reminders

List reminders in a reminder list:

```bash
# List all reminders
ekctl list reminders --list "4E367C6F-354B-4811-935E-7F25A1BB7D39"

# List only incomplete reminders
ekctl list reminders --list "4E367C6F-354B-4811-935E-7F25A1BB7D39" --completed false

# List only completed reminders
ekctl list reminders --list "4E367C6F-354B-4811-935E-7F25A1BB7D39" --completed true
```

Output:
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

### Show Reminder Details

```bash
ekctl show reminder "REM123-456-789"
```

### Add Reminder

Create a new reminder:

```bash
# Simple reminder (no due date)
ekctl add reminder \
  --list "4E367C6F-354B-4811-935E-7F25A1BB7D39" \
  --title "Call the dentist"

# Reminder with due date
ekctl add reminder \
  --list "4E367C6F-354B-4811-935E-7F25A1BB7D39" \
  --title "Submit expense report" \
  --due "2026-01-25T09:00:00Z"

# Reminder with priority and notes
# Priority: 0=none, 1=high, 5=medium, 9=low
ekctl add reminder \
  --list "4E367C6F-354B-4811-935E-7F25A1BB7D39" \
  --title "Renew passport" \
  --due "2026-02-01T12:00:00Z" \
  --priority 1 \
  --notes "Check expiration date first"
```

Output:
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

### Complete Reminder

Mark a reminder as completed:

```bash
ekctl complete reminder "REM123-456-789"
```

Output:
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

```bash
ekctl delete reminder "REM123-456-789"
```

## Date Format

All dates use **ISO 8601** format with timezone. Examples:

| Format | Example | Description |
|--------|---------|-------------|
| UTC | `2026-01-15T09:00:00Z` | 9:00 AM UTC |
| With offset | `2026-01-15T09:00:00+10:00` | 9:00 AM AEST |
| Midnight | `2026-01-15T00:00:00Z` | Start of day |
| End of day | `2026-01-15T23:59:59Z` | End of day |

## Scripting Examples

### Get calendar ID by name

```bash
# Using jq to find a calendar by name
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

When an error occurs, the output includes an error message:

```json
{
  "status": "error",
  "error": "Calendar not found with ID: invalid-id"
}
```

Common errors:
- `Permission denied` - Grant access in System Settings
- `Calendar not found` - Check the calendar ID with `list calendars`
- `Invalid date format` - Use ISO 8601 format (see examples above)

## Help

Get help for any command:

```bash
ekctl --help
ekctl list --help
ekctl add event --help
ekctl list reminders --help
```

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
