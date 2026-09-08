# Champions League Draft Tracker

Fresh tracker for the 2026/27 UEFA Champions League draft.

Same players and core money rules as the World Cup game:

- Jack, Thomas, Mark, and Rory draft clubs.
- £5 moves from the losing owner to the winning owner for each match.
- Draws are void.
- Same-owner matches are void.
- Goals, red cards, and Champions League winner side pots remain the same.
- The old “qualified from groups” side pot is now “most drafted clubs reaching the last 16”.

## Before the first post

Fill `draft.json` after the draft. The official 36 league-phase clubs are listed in `teams.json`.

Once every club has an owner, this folder can publish match updates in the same style as the World Cup tracker.

## Daily fixture graphics

The tracker includes the league-phase fixture calendar in `fixtures-calendar.json`, built from UEFA's official published schedule.

To create the morning game-day post locally:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\BuildDailyFixturesRequest.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\PublishRequests.ps1 -DryRun
```

The GitHub Action `.github/workflows/daily-fixtures.yml` runs every morning at 08:17 Europe/London and posts the fixture graphic to Discord only when the next 24 hours contain Champions League draft fixtures. Off-days are skipped without posting.

For the Action to post, configure the repository secret `DISCORD_WEBHOOK_URL`.

## Full-time match update graphics

Concluded match posts are handled by the same image-publisher flow as the World Cup tracker.

The GitHub Action `.github/workflows/auto-post-results.yml` polls UEFA's public site-backed JSON feeds every 30 minutes from 18:15 to 23:45 Europe/London on Tuesday, Wednesday, and Thursday match nights. When UEFA marks a tracked league-phase match as finished and publishes official team card totals, the Action will:

- create a data-only request under `requests/inbox`;
- render the match update graphic;
- post it to Discord;
- update `tracker-state.json`;
- move the request to `requests/processed`;
- record the Discord message id in `requests/delivery-ledger.jsonl`.

If UEFA has the score but not card totals yet, the Action skips the match and retries on the next scheduled run. This keeps the yellow/red-card side pots from being guessed.

From GitHub mobile, `Phone: Post match result` remains available as a manual fallback: enter the verified match facts, optional shootout, optional last-16/elimination notes, and two source URLs.

See `update-format.md` for the match-post rules and side-bet handling.

## Source notes

Use official UEFA match centres when available, especially for fixtures, final score, cards, league table position, top-8/direct last-16 qualification, knockout play-off winners, and the final winner.

The 2026/27 league phase has 36 clubs, eight matchdays, and no fixed groups. Top 8 reach the round of 16 directly; 9th-24th enter knockout play-offs; play-off winners complete the last 16.

## Discord posting

Keep webhook files private. If this project gets its own GitHub repo, add the webhook as a repository secret rather than committing it.
