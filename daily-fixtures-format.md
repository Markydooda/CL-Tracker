# Upcoming Fixtures Graphic

The daily morning Discord post should use `NewFixturesGraphic.ps1`, not a plain text fixture list.

Create a JSON file containing the next 24 hours of fixtures, then render and post the image.

For league-phase game days, prefer `BuildDailyFixturesRequest.ps1`; it reads `fixtures-calendar.json`, formats UK and Las Vegas kickoff labels, and writes the request into `requests/inbox`.

Fixture JSON shape:

```json
[
  {
    "Stage": "LP",
    "HomeTeam": "AEK Athens",
    "AwayTeam": "LASK",
    "UK": "Today, 5:45 PM",
    "LasVegas": "Today, 9:45 AM"
  }
]
```

Rules:

- Post fixtures scheduled in the next 24 hours from the automation run time.
- Include both UK local time and Las Vegas local time.
- Use UK time zone Europe/London.
- Use Las Vegas time zone America/Los_Angeles.
- Use owner tags from `draft.json`; `NewFixturesGraphic.ps1` resolves owners.
- If both teams have the same owner, show that same owner tag on both sides.
- Do not include betting settlements in the morning fixtures post.
- If there are no fixtures in the next 24 hours, do not post from the scheduled GitHub workflow.
- Codex automations should queue the post with `QueueDiscordPost.ps1`; an outbox sender scheduled task can send it to Discord.
- Direct Discord posting should use `PostDiscordUpdate.ps1`; treat the post as confirmed only when it outputs a Discord message id.
