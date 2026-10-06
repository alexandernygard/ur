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

- **Start and end your day** with ⌘D. Both times are drawn in amber on the timeline, the week view and stats, and you can click them to adjust. Starting a timer also starts the day automatically (you can turn this off in Settings).
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
| ⌥⌘1 – ⌥⌘4 | Day, Week, Stats, Projects |
| ⌘/ | Shortcut list |

## Views

- **Day**: the running clock, the day's start and end, project chips, a 24-hour timeline, and totals with any unallocated gaps.
- **Week**: seven mini timelines, plus a timesheet of hours per project per day and time at work.
- **Stats**: week, month or year view of tracked hours, days worked, average day length, average start and end times, and how much of the work day was allocated. Charts show hours per day by project, the span of each work day, project share, and time of day. You can export entries or work days as CSV.
- **Projects**: rename, set colour and client, reorder (which sets the ⌘ numbers), archive or delete.

## Data

Everything is stored locally in `~/Library/Application Support/Ur/ur.json`, with a daily backup (the last 14 are kept) in `Backups/`. Settings → Show in Finder opens the folder.

## Development

```sh
swift build                 # debug build
./scripts/build-app.sh      # bundle build/Ur.app
swift scripts/make-icon.swift Resources/AppIcon.icns   # regenerate the icon
```

`UR_DATA_DIR=/tmp/ur-demo` runs the app against a different data folder. `UR_SNAPSHOT=/some/dir` renders each screen to PNG and then quits.
