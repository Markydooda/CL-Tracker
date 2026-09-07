# Champions League Tracker agent rules

This folder publishes UEFA Champions League draft updates to Discord.

## Routine update tasks

When asked to prepare an update from Codex Mobile or Codex web:

1. Read `tracker-state.json`, `draft.json`, `teams.json`, `requests/README.md`, and `update-format.md`.
2. Research and verify facts using official UEFA sources where possible.
3. Add data-only JSON files under `requests/inbox/`.
4. Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\PublishRequests.ps1 -DryRun`.
5. Open a PR containing only the new inbox request files if this tracker is connected to GitHub.

Do not modify publisher workflows, PowerShell scripts, `tracker-state.json`, or processed requests as part of a routine update task.

Never add a Discord webhook, API token, cookie, or other secret to this folder.

## Champions League-specific rules

- League phase stage code is `LP`.
- Knockout phase play-off stage code is `PO`.
- Round of 16, quarter-final, semi-final, and final stage codes are `R16`, `QF`, `SF`, and `F`.
- Two-leg ties should not mark a club eliminated until the tie is actually decided.
- Add clubs to `last16Teams` only when their round-of-16 place is official: top 8 after league phase, or knockout phase play-off winners.
- Use `fixtures-calendar.json` and `BuildDailyFixturesRequest.ps1` for daily fixture graphics during the league phase. Do not post anything on days where the generated result is `no-fixtures`.
- Update `fixtures-calendar.json` only from official UEFA sources, and extend it for knockout fixtures once UEFA confirms them.
- Use the `Phone: Post match result` workflow or data-only `kind: match` requests for concluded match posts. Verify final score and cards before publishing.
