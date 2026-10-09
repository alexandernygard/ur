# Ur

*Ur* is Norwegian for clock. It's a keyboard-first macOS app for tracking how your work day is spent: when it starts, when it ends, and which projects the hours in between go to.

![Icon](Resources/AppIcon.png)

## Install

You need macOS 14 or later and Swift (the Command Line Tools are enough; full Xcode isn't required).

```sh
xcode-select --install          # only if you don't have Swift yet
gh repo clone alexandernygard/ur
cd ur && ./install.sh
```

`install.sh` builds a release version, puts `Ur.app` in `/Applications` (or `~/Applications`), and opens it. To update later, run `git pull && ./install.sh`.

## How it works

- **Start and end your day** with ⌘D. Both times are drawn in amber on the calendar and in stats. Drag the amber line to change them, or right-click anywhere on a day to start or end it at that time. Starting a timer also starts the day automatically (you can turn this off in Settings).
- **Track the present** with ⌘1–⌘9, the project chips, or the menu bar. Switching projects stops the previous timer.
- **Fill in the past** by dragging on the timeline, clicking an unallocated gap, or pressing ⌘N. New time replaces whatever it overlaps.
- **Plan the future** by adding entries later in the day. They appear dashed and don't count as tracked until the time has passed.
- **Command bar** (⌘K, or ⌃⌥Space from any app):
  - `design` starts Design
  - `design 9-11:30 review` logs 09:00–11:30 with the note "review"
  - `design 1h30` logs the last hour and a half
  - an unknown name creates the project and starts it

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ⌘1 – ⌘9 | Start or stop project 1–9 (order set in Projects) |
| ⌘K / ⌃⌥Space | Command bar / command bar from anywhere |
| ⌘. | Stop timer |
| ⌘R | Resume last project |
| ⌘D | Start / end / resume the work day |
| ⌘N | Add time |
| ⌘E | Edit selected or running entry |
| ⌘⌫ | Delete selected entry |
| ⌘T, ⌘[, ⌘] | Today, previous, next |
| ⌥⌘1 – ⌥⌘4 | Calendar, Timesheet, Stats, Projects |
| ⌃⌘1 – ⌃⌘3 | Calendar shows one day, workdays, or the full week |
| ⌘/ | Shortcut list |

## Views

- **Calendar**: the running clock, the day's start and end, project chips, and an editable timeline. Switch between one day, the five workdays, or the full week; every column can be edited the same way, and blocks can be dragged from one day to another. Beside it are a month calendar (click a day or a week number to go there) and totals for what's on screen, with any unallocated gaps.
- **Timesheet**: hours per project per day for the week, with group subtotals and time at work.
- **Stats**: week, month or year view of tracked hours, days worked, average day length, average start and end times, and how much of the work day was allocated. Charts show hours per day by project, the span of each work day, project share, and time of day. You can export entries or work days as CSV.
- **Projects**: rename, set colour, reorder (which sets the ⌘ numbers), archive or delete. Archived projects leave the chips, shortcuts and command bar but keep their time; they sit in a folded Archived list where you can restore them. You can also archive from a project chip's right-click menu. Put projects in groups, such as a client, or leave them on their own. Each group shows the combined time of its projects, here and in the Day, Week and Stats breakdowns, where a group can be folded to show only its total.

## Data

Everything is stored locally in `~/Library/Application Support/Ur/ur.json`, with a daily backup (the last 14 are kept) in `Backups/`. Settings → Show in Finder opens the folder.

## Development

```sh
swift build                 # debug build
./scripts/build-app.sh      # bundle build/Ur.app
swift scripts/make-icon.swift Resources/AppIcon.icns   # regenerate the icon
```

`UR_DATA_DIR=/tmp/ur-demo` runs the app against a different data folder. `UR_SNAPSHOT=/some/dir` renders each screen to PNG and then quits.
