# Update requests

Codex cloud tasks and humans add data-only JSON files to `inbox`. A publisher run validates and publishes them, then moves successful requests to `processed`.

Use lowercase, sortable filenames:

- `2026-09-08-1745-aek-athens-lask.json`
- `2026-09-08-fixtures.json`

## Match request

Use match requests for full-time Discord graphics. The publisher renders the post-match standings image, applies the £5 settlement when applicable, updates the running side-bet counters, and records the match as posted only after Discord delivery succeeds.

```json
{
  "kind": "match",
  "kickoff": "2026-09-08T17:45:00+01:00",
  "matchDate": "2026-09-08",
  "stage": "LP",
  "homeTeam": "AEK Athens",
  "homeScore": 1,
  "awayTeam": "LASK",
  "awayScore": 0,
  "homeYellowCards": 2,
  "awayYellowCards": 3,
  "homeRedCards": 0,
  "awayRedCards": 0,
  "homeShootoutScore": null,
  "awayShootoutScore": null,
  "last16Teams": [],
  "eliminatedTeams": [],
  "sources": [
    {
      "url": "https://example.com/opened-final-report",
      "supports": ["final score", "cards"]
    },
    {
      "url": "https://example.org/opened-match-centre",
      "supports": ["final score", "cards"]
    }
  ]
}
```

For a shootout, `homeScore` and `awayScore` are the tied score after extra time. Put the shootout result in `homeShootoutScore` and `awayShootoutScore`. Shootout kicks do not count as goals.

Valid stages are `LP`, `PO`, `R16`, `QF`, `SF`, and `Final`/`F`. Use canonical club names from `teams.json`/`draft.json`.

Use `last16Teams` only when a club has officially reached the round of 16. That happens for the league-phase top 8 after matchday 8, plus knockout phase play-off winners.

## Fixtures request

For league-phase daily fixture posts, prefer:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\BuildDailyFixturesRequest.ps1
```

It uses `fixtures-calendar.json` and skips off-days by default.

```json
{
  "kind": "fixtures",
  "id": "fixtures-2026-09-08",
  "windowStart": "2026-09-08T08:00:00+01:00",
  "subtitle": "Next 24 hours - UK kickoff times",
  "fixtures": [
    {
      "Stage": "LP",
      "HomeTeam": "AEK Athens",
      "AwayTeam": "LASK",
      "UK": "Today, 5:45 PM",
      "LasVegas": "Today, 9:45 AM"
    }
  ],
  "sources": [
    {
      "url": "https://example.com/opened-fixture-list",
      "supports": ["fixtures", "kickoff times"]
    },
    {
      "url": "https://example.org/opened-schedule",
      "supports": ["fixtures", "kickoff times"]
    }
  ]
}
```

An empty `fixtures` array posts the standard “no Champions League Draft fixtures in the next 24 hours” message.
