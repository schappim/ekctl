# ekctl

Native macOS command-line tool for managing Calendar events and Reminders using EventKit. Output is JSON by default, with `--format csv` and `--format text` available on every command for spreadsheets and quick eyeballing.

## Features

- List, create, update, and delete calendar events
- Edit or delete one occurrence of a recurring event, everything from one onwards, or the whole series, and change or remove the recurrence itself
- List, create, update, complete, and delete reminders
- Human date input on every flag — `--start "tomorrow 9am"`, `--from today`, `--to +2w`
- Quick date-range shortcuts: `ekctl today`, `ekctl tomorrow`, `ekctl next`
- Find open time across calendars with `ekctl free` — working hours, buffers, and multi-calendar merging
- Search and filter (`--search`, `--availability busy`) without piping through jq
- Calendar aliases (use friendly names instead of UUIDs)
- JSON, CSV, or plain-text output (`--format json|csv|text`)
- RFC 3339 or jq-friendly compact timestamps (`--time-format rfc3339|compact`)
- `ekctl init` installs an agent skill for Claude Code, Codex, Pi, Antigravity, and OpenCode
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
curl -L -o ekctl.tar.gz https://github.com/schappim/ekctl/releases/download/v1.9.0/ekctl-v1.9.0.tar.gz
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

## Agent skill

`ekctl init` installs a bundled [skill](skills/ekctl/SKILL.md) that teaches AI coding agents how to drive ekctl: finding IDs, recurring-event spans, date formats, and permission prompts. The skill is embedded in the binary, so it works from a bare `/usr/local/bin/ekctl`.

```bash
ekctl init                                  # every agent detected on this Mac
ekctl init --agent claude --agent codex     # specific agents (repeatable)
ekctl init --agent all --scope project      # into the current project, to commit
ekctl init --dry-run                        # report what would change, write nothing
```

Without `--agent`, it installs for each agent whose config directory exists, and errors out with the valid `--agent` values if it finds none. It never prompts.

| `--agent` | User scope (default) | `--scope project` |
| ------ | --------- | ------------- |
| `codex` | `~/.agents/skills/ekctl/` | `.agents/skills/ekctl/` |
| `claude` | `~/.claude/skills/ekctl/` (honours `CLAUDE_CONFIG_DIR`) | `.claude/skills/ekctl/` |
| `pi` | `~/.pi/agent/skills/ekctl/` (honours `PI_CODING_AGENT_DIR`) | `.pi/skills/ekctl/` |
| `antigravity` | `~/.gemini/antigravity-cli/skills/ekctl/` | `.agents/skills/ekctl/` |
| `antigravity-ide` | `~/.gemini/config/skills/ekctl/` | `.agents/skills/ekctl/` |
| `opencode` | `~/.config/opencode/skills/ekctl/` (honours `XDG_CONFIG_HOME`) | `.opencode/skills/ekctl/` |

Each agent gets a row in `results` with an `action` of `installed`, `updated`, `unchanged`, `would-install`, `would-update`, or `failed`. Writes are atomic. An existing `SKILL.md` that differs is first copied to `SKILL.md.<timestamp>.bak` beside it (reported as `backupPath`), and an identical one is left untouched. A replaced file keeps its permissions. A `SKILL.md` that is itself a symlink is never replaced, and a project install won't follow a link that leads outside the project. Locations follow `$HOME`, as the agents themselves do, and an environment variable above set to a relative path is reported as a failure rather than quietly ignored. `--dry-run` runs the same checks as a real install, so it reports the same failures. If any agent fails, the others are still installed and the command exits `1`.

Some agents read more than their own directory. OpenCode also loads `.claude/skills` and `.agents/skills`, Pi also loads `.agents/skills`, and Codex still reads the deprecated `~/.codex/skills`. So installing for several agents can show one of them the skill twice. Install just for the agents you use, and remove any old `~/.codex/skills/ekctl` copy so it doesn't go stale. Pi only loads project skills from projects you've marked trusted.

Start a new agent session afterwards so it picks up the skill.

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
      "calendarType": "calDAV",
      "color": "#0088FF",
      "allowsModifications": true,
      "isDefault": true
    }
  ],
  "status": "success"
}
```

`calendarType` is the kind of account behind the calendar: `local` (On My Mac), `calDAV` (iCloud, Google, Fastmail…), `exchange`, `subscription` (a read-only feed such as public holidays) or `birthday` (generated from Contacts). `isDefault` marks the calendar that `add event` uses when you don't pass `--calendar` (and, among reminder lists, the default list in Reminders; `add reminder` still needs `--list`).

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

Every flag is optional. Leave out `--calendar` to list every calendar, `--from` to start at the beginning of today, and `--to` to stop `--days` days (default 7) after the start (`--days` and `--to` can't be combined). Ranges longer than four years work too; EventKit caps a single query at four years, so ekctl fetches them in pieces:

```bash
ekctl list events                          # every calendar, today and the next 6 days
ekctl list events --calendar work --days 14
ekctl list events --from 2026-03-01 --to 2026-04-01
```

A `--calendar` that was passed but names nothing (`--calendar "$UNSET"`) is an error, not a silent widening to every calendar.

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
      "startDate": "2026-01-15T09:00:00+11:00",
      "endDate": "2026-01-15T10:00:00+11:00",
      "location": "Conference Room A",
      "notes": null,
      "allDay": false,
      "hasAlarms": true,
      "alarms": [
        { "type": "relative", "minutesBeforeStart": 10 }
      ],
      "travelTimeMinutes": null,
      "hasRecurrenceRules": false,
      "recurrenceRules": [],
      "occurrenceDate": "2026-01-15T09:00:00+11:00",
      "isDetached": false,
      "availability": "busy",
      "attendees": []
    }
  ],
  "status": "success"
}
```

`url` appears only when the event has one; `location` and `notes` are always present, `null` when empty.

For a recurring event, `recurrenceRules` describes the rule in the same terms the `--recurrence-*` flags use, so it can be read off one event and handed to another:

```json
"recurrenceRules": [
  {
    "frequency": "weekly",
    "interval": 1,
    "daysOfTheWeek": ["mon", "wed", "fri"],
    "daysOfTheMonth": null,
    "monthsOfTheYear": null,
    "weeksOfTheYear": null,
    "daysOfTheYear": null,
    "setPositions": null,
    "endCount": 20,
    "endDate": null
  }
]
```

Every occurrence of a series is listed separately and they share one `id`, except occurrences edited on their own, whose `id` adds a `/RID=…` suffix. `occurrenceDate` says which occurrence each one is (see [Recurring events](#recurring-events)), and `isDetached` is `true` for an occurrence that was edited on its own.

### Quick date ranges: `today` / `tomorrow` / `next`

Three top-level shortcuts wrap the most common `list events` queries with a pre-computed local date range. No more `date -u -v+1d` shell prelude (which is BSD-only and breaks on Linux):

```bash
# Events occurring today (local time), across every calendar
ekctl today

# Just one calendar
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

All three accept the same filter / format flags as `list events` (`--search`, `--availability`, `--format`, and comma-separated `--calendar`, which can be left out for every calendar), so they compose:

```bash
ekctl today --calendar work,personal --availability busy --format csv
ekctl next --calendar work --search standup --count 3 --format text
```

`next` returns events sorted by start time ascending and includes events that are currently in progress (their `endDate` is still in the future).

### Show Event

**Command:**

```bash
ekctl show event EVENT_ID

# One occurrence of a recurring event
ekctl show event EVENT_ID --occurrence "2026-03-16T10:00:00+11:00"
```

### Add Event

Basic event:

```bash
ekctl add event --calendar work --title "Lunch" --start "2026-02-10T12:30:00Z" --end "2026-02-10T13:30:00Z"
```

Without `--calendar`, the event goes in your default calendar for new events (the one `list calendars` marks `isDefault`, set in Calendar → Settings → General):

```bash
ekctl add event --title "Dentist" --start "fri 3pm" --end "fri 4pm"
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
  --alarms "10m,1h"
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

The recurrence flags:

| Flag | Meaning |
| ---- | ------- |
| `--recurrence-frequency` | `daily`, `weekly`, `monthly` or `yearly` (and `none` on `update event`) |
| `--recurrence-interval` | Every N periods — `2` with `weekly` is fortnightly |
| `--recurrence-end-count` | Stop after N occurrences |
| `--recurrence-end-date` | Stop on this date, including it: a plain date such as `2026-12-01` keeps that day's occurrence (`none` on `update event` makes the series open-ended) |
| `--recurrence-days` | Days of the week: `mon,wed`; `1mon` is the first Monday, `-1fri` the last Friday (monthly and yearly rules) |
| `--recurrence-days-of-month` | `1,15`, or `-1` for the last day (monthly rules) |
| `--recurrence-months` | `1-12` or names: `jan,jul` (yearly rules) |
| `--recurrence-weeks-of-year` | `1-53`, or negative from the end (yearly rules) |
| `--recurrence-days-of-year` | `1-366`, or negative from the end (yearly rules) |
| `--recurrence-set-positions` | Picks among the days the other flags select: with `--recurrence-frequency monthly`, `--recurrence-days mon,tue,wed,thu,fri --recurrence-set-positions -1` is the last weekday of the month |

Values are checked before anything is saved: a typo, a zero, an out-of-range number, or a flag that doesn't apply to the frequency (say `--recurrence-months` on a weekly rule, which EventKit would silently ignore) is an error that names the problem. Negative values work with or without `=` (`--recurrence-days -1fri`).

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
    "startDate": "2026-02-10T12:30:00+11:00",
    "endDate": "2026-02-10T13:30:00+11:00",
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

Move an event to another calendar with `--calendar` (an ID or alias):

```bash
ekctl update event EVENT_ID --calendar personal
```

Updating a recurring event takes `--occurrence` and `--span`, and can change the recurrence itself; see [Recurring events](#recurring-events).

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
  },
  "span": "this"
}
```

### Recurring events

Every occurrence of a recurring series shares one event ID; `list events` shows each occurrence with that same `id` and its own `startDate`. So for a recurring event, an ID alone doesn't say *which* meeting you mean. Two flags on `update event` and `delete event` do:

- `--occurrence DATE` picks the occurrence: pass its `startDate` from `list events` (or its `occurrenceDate`, the slot it was originally scheduled in, if it has since been moved). Any [date format](#date-format) works.
- `--span this|future|all` says how far the change reaches: just that occurrence (the default), that occurrence and every later one, or the whole series.

```bash
# Rename just the 16 March standup
ekctl update event EVENT_ID --occurrence "2026-03-16T10:00:00+11:00" --title "Standup (demo day)"

# Move every standup from 16 March onwards to 10:30
ekctl update event EVENT_ID --occurrence "2026-03-16T10:00:00+11:00" --span future \
  --start "2026-03-16T10:30:00+11:00" --end "2026-03-16T10:45:00+11:00"

# Rename the whole series
ekctl update event EVENT_ID --span all --title "Daily sync"

# Cancel one occurrence, or the series from a date onwards, or all of it
ekctl delete event EVENT_ID --occurrence "2026-03-16T10:00:00+11:00"
ekctl delete event EVENT_ID --occurrence "2026-03-16T10:00:00+11:00" --span future
ekctl delete event EVENT_ID --span all
```

A recurring event's ID without `--occurrence` is refused unless the span is `all`. So is an `--occurrence` that matches two occurrences (one moved onto another's slot); the error lists both IDs to choose from. EventKit resolves a bare series ID to the series' *first* occurrence, so before this check, `delete event` on a listed weekly meeting silently deleted the first meeting of the series instead of the one you were looking at.

How the spans behave:

- **`this`** edits only the chosen occurrence. It becomes *detached*: it keeps its own changes, reports `isDetached: true`, and gets an ID of its own (the series ID plus `/RID=…`), which also works directly.
- **`future`** splits the series at the chosen occurrence. Earlier occurrences keep the old ID; the chosen occurrence and those after it become a new series with a new ID, reported in the output.
- **`all`** applies to the whole series. With `--occurrence`, new `--start` / `--end` times are measured against that occurrence and the same shift is applied to the whole series. So moving the 16 March meeting to 11:00 moves every occurrence to 11:00; it doesn't make the series start on 16 March. The shift is in clock time in the event's own time zone, so it lands at the same time of day either side of a daylight-saving change. Occurrences edited on their own keep their own times, except the one you addressed, which goes where you said.

Moving a series' times, or re-saving its rule with a new end, makes EventKit forget which occurrences had been deleted, so they reappear; ekctl notices and deletes them again, reporting `recancelledOccurrences`. A move onto a different weekday is refused for a rule pinned to particular days (`--recurrence-days mon`), since EventKit would keep repeating on the old days; pass the new `--recurrence-days` with it. The same goes for a different day of the month with `--recurrence-days-of-month`, and so on. Moving a Monday series a week later is fine.

Changing the recurrence itself uses the same `--recurrence-*` flags as `add event`, and needs `--span future` or `--span all` on an event that already repeats (with `this`, EventKit would just detach the occurrence). A `--recurrence-frequency` starts a fresh rule, keeping only the old end unless you give a new one. Without one, each flag replaces just that part of the existing rule, and a series ending after N occurrences still ends after N in total when split with `--span future`. Changing the rule discards occurrences that were edited or deleted individually, as Calendar does:

```bash
# End the series after 10 occurrences, keeping everything else
ekctl update event EVENT_ID --span all --recurrence-end-count 10

# From the 16 March occurrence on, switch to fortnightly
ekctl update event EVENT_ID --occurrence "2026-03-16T10:00:00+11:00" --span future \
  --recurrence-frequency weekly --recurrence-interval 2

# Stop repeating: keep only the first occurrence
ekctl update event EVENT_ID --span all --recurrence-frequency none

# Make a one-off event repeat
ekctl update event EVENT_ID --recurrence-frequency monthly --recurrence-days=-1fri
```

Moving a recurring event to another calendar needs `--span all`, because EventKit can only move a series as a whole. Saving a single occurrence into another calendar moves every occurrence anyway.

One EventKit quirk to know about: a series split with `--span future` stays linked to the series it came from, and some later `--span all` changes to the original reach into it. Deleting the original with `--span all` deletes the split-off series too, and moving the original's times can move it and drop some of its occurrences. EventKit offers no way to prevent this, so ekctl compares the calendar before and after every series-wide change and reports any other series that changed in `alsoAffected`, with a note in `warnings`:

```json
"alsoAffected": [
  { "id": "ABC123:SPLIT789", "title": "Standup", "change": "deleted", "occurrencesBefore": 6, "occurrencesAfter": 0 }
],
"warnings": ["EventKit also changed another series in this calendar: 'Standup', ..."]
```

### Alarms and travel time

`--alarms` takes comma-separated offsets from the start and **replaces** every
existing alarm on the event (it does not append). Each offset is a number with an
optional unit: `m` (minutes, the default), `h`, `d` or `w`, case-insensitive. The
longer spellings date offsets accept (`min`, `hr`, `day`, `week` and plurals) work
too. A bare or negative offset is *before* the start; a leading `+` means *after*:

```bash
ekctl update event EVENT_ID --alarms "10,60"        # 10 min and 1 hour before
ekctl update event EVENT_ID --alarms "15m,1h,1d"    # 15 min, 1 hour and 1 day before
ekctl update event EVENT_ID --alarms "+15m"         # 15 min after the start
ekctl update event EVENT_ID --alarms "1.5h"         # 90 min before
ekctl update event EVENT_ID --alarms "0"            # at the start
ekctl update event EVENT_ID --alarms none           # remove every alarm
```

A bare number is minutes, so lists written before units existed mean what they
always did. `none` or an empty string (`--alarms ""`) means no alarms. On `update
event` that clears them; on `add event` it just asks for none, and the calendar's
own default alarm may still apply (see below). An offset that starts with `-` works
with or without `=` (`--alarms -15` or `--alarms=-15`), though since `-15` and `15`
mean the same thing, it's simpler to leave the sign off.

To keep an event's alarms and add more, use `--add-alarms` on `update event`. It takes
the same format, and skips an alarm the event already has:

```bash
ekctl update event EVENT_ID --add-alarms 1d         # keep the existing alarms, add a day-before one
```

`--alarms` and `--add-alarms` can't be combined in one command.

Every entry has to be valid, or the command fails *before* touching the event and
names the entry it rejected (`Invalid --alarms value. "1hour30" is not an alarm
offset...`). Nothing is silently skipped. In particular:

- **Whole minutes only.** `1.5h` and `0.25h` are fine, but `1.5m` and `30s` are
  rejected: event output reports alarms in whole minutes, so a finer alarm wouldn't
  read back as what you set.
- **At most a year either side** (365 days, so `52w` and `365d` are fine). EventKit
  would accept more, but an offset that large is almost always the wrong unit, such
  as `10080h` typed where `10080m` (a week) was meant.
- Units can't be combined (`1h30m`); write `90m` or `1.5h`. Months and years are
  not units, for the same reason as in [date offsets](#shorthand).

Both fields are echoed back in the event JSON, in the same units the flags accept,
so output reads back as input (mind the sign for alarms after the start, below):

```json
"alarms": [
  { "type": "relative", "minutesBeforeStart": 10 },
  { "type": "relative", "minutesBeforeStart": -15 },
  { "type": "absolute", "date": "2026-02-15T08:00:00+11:00" }
],
"travelTimeMinutes": 20
```

`minutesBeforeStart` is negative for an alarm that fires *after* the start, and goes
back in with a `+`: a rendered `-15` is `--alarms "+15"`. Passing `-15` back as-is
means 15 minutes *before*, because a leading `-` has always meant before on this
flag. Alarms set outside ekctl may be absolute rather than relative, in
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

For a recurring event, add `--occurrence` and/or `--span` (see [Recurring events](#recurring-events)).

**Output:**

```json
{
  "status": "success",
  "message": "Event 'Team Meeting' deleted successfully",
  "deletedEventID": "ABC123:DEF456",
  "span": "this",
  "deletedEvent": {
    "id": "ABC123:DEF456",
    "title": "Team Meeting",
    "startDate": "2026-01-15T09:00:00+11:00"
  }
}
```

`deletedEvent` (abridged above) is the deleted event as it was just before deletion, with the same fields as `show event`.

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
| `--from` | now | Search start — ISO 8601 or shorthand (see [Date Format](#date-format)). |
| `--to` | `--days` after the start | Search end — ISO 8601 or shorthand (see [Date Format](#date-format)). |
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
      "dueDate": "2026-01-20T17:00:00+11:00",
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
    "dueDate": "2026-01-25T09:00:00+11:00",
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

All date **inputs** (`--from`, `--to`, `--start`, `--end`, `--due`, `--recurrence-end-date`, `--occurrence`) accept an ISO 8601 timestamp, with or without a UTC offset, or a shorthand. They are interchangeable everywhere:

```bash
ekctl add event --calendar work --title Standup --start "tomorrow 9am" --end "tomorrow 9:15am"
ekctl add event --calendar work --title Review --start 2026-02-23T14:00 --end 2026-02-23T15:00
ekctl list events --calendar work --from today --to +1w
ekctl add reminder --list personal --title "Call the dentist" --due "fri 5pm"
```

### Shorthand

| Form | Example | Means |
| ------ | --------- | ------- |
| Now | `now` | The current instant |
| Offset | `+90m`, `+3d`, `+1w` | From now. Units: `m`/`min`, `h`/`hr`, `d`/`day`, `w`/`week` |
| Negative offset | `--from=-2h` | Same, backwards. Needs the `=` form — a bare `-2h` looks like a flag |
| Named day | `today`, `tomorrow`, `yesterday` | Local midnight of that day |
| Weekday | `fri`, `friday` | The next Friday, **today included** |
| Qualified weekday | `next fri`, `last fri` | The next / previous Friday, **today excluded** |
| Week | `next week`, `last week` | Seven days either side of today |
| Plain date | `2026-02-01` | Local midnight |
| Time | `14:30`, `3pm`, `9:15am` | That time today |
| Named time | `noon`, `midnight` | |
| Day + time | `tomorrow 3pm`, `next fri at 09:00`, `2026-02-01 14:30` | Any day above with any time above |

Case doesn't matter, and `at` is optional filler.

A bare day resolves to the **start** of that day. That's what `--from tomorrow` should mean, but it applies just as much to the other flags: `--start tomorrow` creates a midnight event and `--due tomorrow` sets a midnight due date. Add a time — `--start "tomorrow 9am"` — whenever you mean a point in the day rather than its beginning.

A bare number like `9` is **rejected**, not guessed — it could be 9am or the 9th, and being wrong there books a meeting three weeks out. Write `9am` or `09:00`. Months and years are not offset units for the same reason: `+3m` is unambiguously 3 minutes.

Times are grafted onto days by wall clock, so `tomorrow 09:00` is 9am even on the day the clocks change. A time the clocks skip or repeat is resolved the same way as [ISO 8601 without an offset](#iso-8601).

### ISO 8601

Accepted with any of these timezone suffixes, with or without fractional seconds, or with none at all. ISO is matched before the shorthand, and a timestamp with an offset is matched before one without, so a timestamp always parses as itself:

| Format | Example | Description |
| -------- | --------- | ------------- |
| UTC | `2026-01-15T09:00:00Z` | 9:00 AM UTC |
| Offset with colon | `2026-01-15T09:00:00+10:00` | 9:00 AM AEST (RFC 3339) |
| Compact offset | `2026-01-15T09:00:00+1000` | Same instant, jq-style `%z` form |
| No offset | `2026-01-15T09:00`, `2026-01-15T09:00:00`, `2026-01-15T09:00:00.250` | 9:00 AM in your Mac's time zone |
| No offset, space | `2026-01-15 09:00:00` | Same, in the form `date '+%F %T'` and databases print |

Without an offset, a timestamp is local wall-clock time, read in the Gregorian calendar whatever your region's calendar is set to. Every field has a fixed width (`09`, not `9`) and must be in range: `24:00`, `09:60`, `09:00:60` and `2026-02-31T09:00` are rejected rather than rolled over into the next hour, day or month. (`2026-01-15 9:00`, with a one-digit hour, still works as [shorthand](#shorthand), which has no seconds.)

Around a daylight-saving change, a local time can name no instant or two:

- **Skipped** (spring forward): the time moves forward by the length of the gap. In New York, `2026-03-08T02:30` is 3:30 AM EDT.
- **Repeated** (fall back): the first occurrence wins. In New York, `2026-11-01T01:30` is 1:30 AM EDT (`-04:00`), not the EST hour that follows.

The shorthand resolves times the same way, so `--start "tomorrow 2:30am"` and `--start 2026-03-08T02:30` always agree. Add an offset when you need the other occurrence of a repeated hour.

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

All errors return JSON with `status: "error"` (or that object rendered as CSV or text under `--format`), except command lines the argument parser itself rejects; see the exit codes below:

```json
{
  "status": "error",
  "error": "Calendar not found with ID: invalid-id"
}
```

Common errors:

- `Permission denied`: Grant access in System Settings → Privacy & Security → Calendars/Reminders
- `Calendar not found`: Check calendar ID with `ekctl list calendars`
- `Invalid --<flag> date format`: the message echoes the value it rejected. Use an ISO 8601 timestamp (`2026-01-15T09:00:00Z`, `+10:00` or `+1000` offsets, or no offset for local time) or a shorthand such as `tomorrow 9am` or `+2h` — see [Date Format](#date-format)
- `Invalid --alarms value`: the message names the entry it rejected and why — see [Alarms and travel time](#alarms-and-travel-time)

Exit codes: `0` success, `1` failure (any `"status": "error"` output, including a refused or not-found event), `2` permission denied, `64` the argument parser rejected the command line (unknown flag, missing value, a value outside a flag's fixed choices such as `--span sideways`, or a non-number where a number is expected), with plain usage text rather than JSON. So `ekctl delete event "$ID" && echo done` only says done when something was deleted.

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
