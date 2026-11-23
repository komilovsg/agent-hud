# Agent HUD

A small macOS heads-up display for Claude Code. It floats above your windows and shows what every session is
doing, lets you allow or deny a permission request without switching to the editor, and takes you back to the
right window in one click.

Based on [AgentHUD](https://github.com/vladilenm/agent-hud) by Vladilen Minin (MIT).

## What it does

- **Sessions at a glance.** One avatar per session with its state: working, waiting for you, done, idle. Click
  for the step feed and the subagent tree. Drag the HUD anywhere by an avatar.
- **Permission requests.** Allow, deny with a reason, or hand the request back to the terminal or VS Code.
- **Red flags.** Dangerous commands are shown in red with the reason, and "always allow" is never offered for
  them. Out of the box: pushing to `main` / `master` / `dev` / `develop`, `--force`, creating or merging a merge
  or pull request, `rm -rf`, database migrations. The rules live in a JSON file you can edit.
- **Background tasks.** Every background shell and background agent of a session with its age. Anything older
  than an hour is highlighted, so a forgotten dev server or a stuck agent is easy to spot.
- **Report for a period.** One click gives a Markdown report for any time range, grouped by project, with the
  branches and merge request links that appeared in commands.

The interface is in Russian for now. English is planned.

## Privacy

Everything stays on your Mac. The app has no network code. The hook talks to the app over a Unix socket that
only your user can open, and the activity log is a local file you can switch off in the settings.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (Xcode or Command Line Tools)
- Claude Code

## Install

```sh
git clone https://github.com/komilovsg/agent-hud.git
cd agent-hud
scripts/build-app.sh --install
open ~/Applications/AgentHUD.app
```

This builds the app, puts it in `~/Applications` and links the hook to `~/.local/bin/agenthud-hook`.

Then connect it to Claude Code from the app's control panel. The app shows exactly what it will add to
`~/.claude/settings.json`, keeps your existing hooks in place and in order, and saves a copy of the file as
`settings.json.agenthud-backup-<date>` before writing. Disconnecting removes only its own entries.

Sessions started before you connected do not report to the HUD. Start a new one.

When the app is not running, the hook steps aside and Claude Code behaves as if it was never installed.

## Red flag rules

The rules are in `~/Library/Application Support/AgentHUD/red-flags.json`. The control panel has a button that
opens the file. Changes apply on the next request, no restart needed.

```json
{
  "version": 1,
  "rules": [
    { "id": "prod-db", "title": "Production database", "pattern": "db\\.example\\.com" }
  ]
}
```

`pattern` is a case-insensitive regular expression searched in the whole Bash command. A rule with a broken
pattern is skipped and reported in the control panel. If the file cannot be read at all, the built-in rules are
used.

A red flag is a warning, not a block: you can still allow the command once.

What the default rules cannot see: a plain `git push` while you are on a protected branch (the command does not
name the branch), and connection strings hidden in environment variables.

## Report from the command line

```sh
~/Applications/AgentHUD.app/Contents/MacOS/AgentHUD --report "2026-11-22 15:00"
~/Applications/AgentHUD.app/Contents/MacOS/AgentHUD --report "2026-11-22 15:00" "2026-11-23 10:00"
```

The second date is optional and defaults to now.

## Development

```sh
swift build
swift run AgentHudCoreTests
```

Tests are an executable target, so they run without Xcode. The app icon is drawn by `scripts/make-icon.swift`.

## License

MIT. See [LICENSE](LICENSE). Fonts in `Resources/Fonts` are under the SIL Open Font License, with their license
texts next to them.
