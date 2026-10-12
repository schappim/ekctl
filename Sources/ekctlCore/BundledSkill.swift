// The agent skill installed by `ekctl init`, embedded so a standalone binary
// copied to /usr/local/bin needs no resource bundle.
//
// KEEP THIS IDENTICAL TO skills/ekctl/SKILL.md. Edit that file, then paste its
// full contents between the delimiters below (the blank line before the
// closing delimiter is the file's trailing newline).
// SkillInstallerTests.testEmbeddedSkillMatchesRepositoryFile fails if the two
// differ by even a byte.

public enum BundledSkill {
    public static let content = #"""
---
name: ekctl
description: Read and manage macOS Calendar events and Reminders with the ekctl CLI (EventKit). Use when the user asks about their schedule or agenda, wants to find free time, create, move, reschedule or delete events (including recurring ones), or list, add, complete or delete reminders on a Mac.
license: MIT
---

# ekctl

`ekctl` drives the local Calendar and Reminders stores through EventKit on macOS. Output is JSON by default. Every success has `"status": "success"`; every failure prints `{"status": "error", "error": "..."}` and exits non-zero, except when the argument parser itself rejects the command line (unknown flag, missing value, a value outside a flag's fixed choices such as `--span sideways`, or a non-number where a number is expected), which prints plain usage text and exits `64`.

**Always take IDs from ekctl's own output** (`id`, `calendar.id`, `list.id`, `occurrenceDate`). Never guess or construct an ID, and never assume a calendar name maps to an ID without listing.

## Discovery

```bash
ekctl --help                # all commands
ekctl add event --help      # every flag for one command; the installed binary is authoritative
ekctl --version
```

## Permissions

The first command that touches Calendars or Reminders triggers a macOS privacy (TCC) prompt. Commands ask only for what they need, so reminders-only work never prompts for Calendars. macOS attributes the request to the app that launched ekctl (Terminal, iTerm, or your agent's desktop app), so that app is what appears in **System Settings → Privacy & Security → Calendars / Reminders**.

Exit code `2` means permission denied. A background, sandboxed or remote (SSH) session often cannot show the prompt at all. Don't retry in a loop: ask the user to run `ekctl list calendars` once from a local terminal and approve the prompt, or to grant access in System Settings.

## Calendars and aliases

```bash
ekctl list calendars        # event calendars AND reminder lists
```

Each entry has `id`, `title`, `type` (`event` or `reminder`), `source`, `color`, `allowsModifications`, `calendarType` and `isDefault`. Only write to calendars with `allowsModifications: true`. `isDefault` marks the system default calendar, which `add event` uses when `--calendar` is omitted.

Aliases are friendly names usable anywhere a calendar or list ID is accepted:

```bash
ekctl alias list
ekctl alias set work CA513B39-1659-4359-8FE9-0C2A3DCEF153
ekctl alias remove work
```

`ekctl calendar create --title "Project X" --color "#FF5500"`, `calendar update ID` and `calendar delete ID` manage calendars themselves. Deleting a calendar deletes its events; confirm with the user first.

## Reading events

```bash
ekctl today                               # today, all event calendars
ekctl tomorrow --calendar work
ekctl next --count 5 --days 30            # upcoming, incl. in-progress; 90-day lookahead by default
ekctl list events                         # all event calendars, start of today, next 7 days
ekctl list events --calendar work,personal --from 2026-03-01 --to 2026-04-01
ekctl list events --from today --to +2w --search standup --availability busy
ekctl show event EVENT_ID
```

`--calendar` takes one or more comma-separated IDs or aliases. `--search` is a case-insensitive substring match on title, location and notes; `--availability` is one of `busy`, `free`, `tentative`, `unavailable`, `notSupported`. For a whole day, use the next day's midnight as `--to`. Prefer a narrow range when looking for a particular event.

Event fields include `id`, `title`, `calendar` (`id`, `title`), `startDate`, `endDate`, `allDay`, `location`, `notes`, `url` (omitted when unset), `availability`, `alarms`, `travelTimeMinutes`, `attendees`, `hasRecurrenceRules`, `recurrenceRules`, `occurrenceDate` and `isDetached`. Don't rely on `hasAlarms`: calendars add default alarms, so read `alarms`.

## Creating events

```bash
ekctl add event --title "Lunch" --start "tomorrow 12:30" --end "tomorrow 13:30"
ekctl add event --calendar work --title "Review" \
  --start 2026-02-15T14:00 --end 2026-02-15T15:30 \
  --location "Room 301" --notes "Bring Q1 reports" --alarms "10m,1h" \
  --url https://example.com --availability busy --travel-time 30
```

Add `--all-day` for an all-day event. Without `--calendar` the event goes to the system default calendar. Adding is **not idempotent**: if a create's outcome is unclear, list the time range before retrying so you don't make a duplicate. Report the result from the returned `event` rather than assuming.

## Updating and deleting events

```bash
ekctl update event EVENT_ID --title "New title"
ekctl update event EVENT_ID --start "fri 10am" --end "fri 11am"
ekctl update event EVENT_ID --calendar personal          # move to another calendar
ekctl update event EVENT_ID --alarms 15m                 # replace all alarms
ekctl update event EVENT_ID --add-alarms 1d              # keep existing alarms, add one
ekctl update event EVENT_ID --alarms none                # remove all alarms
ekctl delete event EVENT_ID
```

Only the flags you pass change. When moving an event in time, pass both `--start` and `--end` so the duration is what you intend. Other update flags: `--location`, `--notes`, `--url`, `--all-day true|false`, `--availability`, `--travel-time`. Confirm deletions with the user, and quote the event's title and time when you do.

## Recurring events

Every occurrence of a recurring series shares **one** event ID. `--occurrence <date>` picks which occurrence the ID means: pass that occurrence's `startDate` (or its `occurrenceDate`) from `list events` / `today` / `next` output. `update event` and `delete event` refuse a recurring event's bare ID unless `--span all`; `show event` without `--occurrence` shows the first occurrence.

`update event` and `delete event` take `--span`:

- `this` (default): only the selected occurrence.
- `future`: the selected occurrence and every later one.
- `all`: the whole series.

```bash
ekctl show event EVENT_ID --occurrence 2026-03-10T09:00:00+11:00
ekctl update event EVENT_ID --occurrence 2026-03-10T09:00:00+11:00 --start "2026-03-10T10:00" --end "2026-03-10T10:30"
ekctl delete event EVENT_ID --occurrence 2026-03-17T09:00:00+11:00              # skip one week
ekctl delete event EVENT_ID --occurrence 2026-06-02T09:00:00+10:00 --span future  # end the series
```

If `--occurrence` matches two occurrences, the error lists both IDs; use the one meant. `isDetached: true` marks an occurrence that was edited individually; its `id` gains a `/RID=…` suffix and works on its own. `--span future` splits the series: the output's `event.id` is the new series' ID. With `--span all`, `--start`/`--end` are measured against the chosen occurrence and the same shift applies to every occurrence. Moving a recurring event to another calendar needs `--span all`. Series-wide changes can cascade into a series previously split off with `--span future` (EventKit links them); ekctl reports that in `alsoAffected` and `warnings`. Always read `warnings` in the output and tell the user about them.

Recurrence flags work on `add event` and `update event`: `--recurrence-frequency daily|weekly|monthly|yearly` (`none` on update removes recurrence), `--recurrence-interval N`, `--recurrence-end-count N` or `--recurrence-end-date DATE`, `--recurrence-days mon,wed,fri` (`1mon` first Monday, `-1fri` last Friday; week numbers only on monthly and yearly rules), `--recurrence-months`, `--recurrence-days-of-month`, `--recurrence-weeks-of-year`, `--recurrence-days-of-year`, `--recurrence-set-positions`. On update, a `--recurrence-frequency` replaces the whole rule (keeping its end unless a new one is given), while other recurrence flags change just that part of the existing rule (`--recurrence-end-date none` makes it open-ended). Values a rule can't use (e.g. `--recurrence-months` on a weekly rule) are rejected.

```bash
ekctl add event --title Gym --start "mon 18:00" --end "mon 19:00" \
  --recurrence-frequency weekly --recurrence-days mon,wed,fri --recurrence-end-count 20
ekctl update event EVENT_ID --span all --recurrence-frequency none
```

Changing a recurring event's recurrence requires `--span future` (with `--occurrence`) or `--span all`. Ask the user which occurrences they mean before any series-wide change. `recurrenceRules` in the output describes the series as it now stands.

## Reminders

```bash
ekctl list reminders --list personal                  # --list is required
ekctl list reminders --list personal --completed false --search milk
ekctl show reminder REMINDER_ID
ekctl add reminder --list personal --title "Call dentist" --due "fri 5pm" --priority 1 --notes "..."
ekctl update reminder REMINDER_ID --due "2026-03-10T09:00" --priority 5
ekctl complete reminder REMINDER_ID
ekctl delete reminder REMINDER_ID
```

Priority: `0` none, `1` high, `5` medium, `9` low. Reminder list IDs come from `list calendars` entries with `type: "reminder"`.

## Finding free time

```bash
ekctl free --calendar work,personal --duration 60 --days 14 --buffer 15
ekctl free --calendar work --working-hours 08:00-16:00 --weekdays mon-thu --round 15 --limit 1
```

`--calendar` is required. Returns `slots` (`startDate`, `endDate`, `durationMinutes`, `date`, `weekday`); each slot is a maximal gap, at least `--duration` minutes. Defaults: now to 7 days ahead, `09:00-17:00`, weekdays. Events marked `free`, cancelled or declined don't block time. A slot's `startDate` can be passed straight to `add event --start`.

## Dates

Every date flag accepts:

- ISO 8601 with an offset: `2026-02-23T14:00:00Z`, `2026-02-23T14:00:00+11:00`, `2026-02-23T14:00:00+1100`.
- Local time with no offset: `2026-02-23T14:00` or `2026-02-23T14:00:00`.
- A date: `2026-02-23` (local midnight).
- Shorthand: `now`, `today`, `tomorrow`, `yesterday`, `fri`, `next fri` (the coming Friday, skipping today: the same as `fri` except on a Friday; for the week after, give a date), `next week`, `3pm`, `14:30`, `noon`, `tomorrow 9am`, `next fri at 09:00`, offsets `+90m`, `+3d`, `+1w` (use `--from=-2h` for a negative offset).

A bare day means midnight, so add a time when you mean a point in the day. A bare number like `9` is rejected; write `9am` or `09:00`. Output timestamps are in the Mac's local zone and are valid input, so pass them back unchanged.

`--alarms` takes comma-separated offsets before the start: `15m`, `1h`, `2d`, `1w`, a bare number of minutes, or `none`. A leading `+` fires after the start. Output reports `alarms[].minutesBeforeStart`, which is negative for an alarm after the start: write `-15` back as `--alarms +15`, never `-15` (that means 15 minutes before). Alarms set elsewhere may be absolute, with a `date` instead.

## Output

- `--format json` (default), `--format csv`, `--format text` on every command. CSV and text render the main list (events, reminders, calendars, slots, ...) one row per item.
- `--time-format compact` renders offsets as `+1100` (parseable by jq's `strptime %z`) instead of `+11:00`.
- Exit codes: `0` success, `1` failure (a JSON error), `2` permission denied, `64` the argument parser rejected the command line (plain text; see the top of this file).

## Workflow: find and reschedule

1. Find candidates in a narrow range: `ekctl list events --from DATE --to DATE --search WORDS`.
2. If several match, show the user titles and times and ask. Note `id` and, for a recurring event, `occurrenceDate`.
3. Update with both `--start` and `--end`, plus `--occurrence` and the agreed `--span` for a recurring event.
4. Report the new time and calendar from the returned `event`.

"""#
}
