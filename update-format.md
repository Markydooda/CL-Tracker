# Discord Match Update Format

Use this flow for each newly verified final Champions League match.

Routine match-result posts should be rendered with `NewMatchUpdateGraphic.ps1` and posted as an image.

The no-token path is the scheduled `Auto: Post finished match results` Action. It polls UEFA's public site-backed JSON feeds, creates match requests for newly finished league-phase games, publishes the graphics, updates `tracker-state.json`, and records Discord receipts.

The GitHub-mobile fallback is the `Phone: Post match result` Action, which does the same publishing work after a human enters the verified match facts.

The graphic shows:

- Final score, including penalty shootout score in brackets when relevant.
- Draft owners and pick numbers for both clubs.
- £5 match settlement, or draw/same-owner void.
- Running match-bet balances.
- Goals side-bet totals.
- Red-card totals, with yellow-card totals in brackets as the tiebreaker.
- Last-16 side-bet totals.
- Any newly official last-16 or elimination note.

Rules:

- Verify final score, yellow cards, and red cards from official UEFA match centres where possible.
- Automatic result posts use UEFA's match feed for score/status and UEFA's team-statistics feed for card totals.
- If final score or card totals are missing, skip and retry later instead of posting partial or guessed data.
- Use at least two HTTPS sources in each request.
- If two different owners' clubs play and one club wins, including on penalties, the losing owner pays the winning owner £5.
- League-phase draws are void.
- Same-owner matches are void.
- Goals and red cards are running owner totals across all drafted clubs.
- Goals scored during normal time or extra time count, including in-match penalty goals.
- Penalty shootout goals do not count toward the goals side bet.
- Yellow cards are tracked as the red-card side-bet tiebreaker and should be included for every match.
- Goals conceded are tracked quietly as the goals side-bet tiebreaker, but are not shown in routine match graphics unless needed at final settlement.
- League-phase team points are tracked: win = 3, draw = 1 each, loss = 0.
- Add clubs to `last16Teams` only when their round-of-16 place is official: top 8 after the league phase, or knockout phase play-off winners.
- Add `eliminatedTeams` only when a club is officially out. In two-leg knockout ties, wait until the tie is actually decided.
- Only add a match to `postedMatches` after its Discord post succeeds. If posting fails, leave it unposted so the next run can retry.

Side bets are tracked quietly during the tournament and should be paid into the final balance only at the end:

- Goals: each owner stakes £10; total pot £40.
- Red cards: each owner stakes £10; total pot £40.
- Most drafted clubs reaching the last 16: each owner stakes £10; total pot £40.
- Champions League winner: each owner stakes £25; total pot £100.

Side-bet tiebreaks:

- Most goals wins the goals side bet.
- If goals are tied, the tied owner with the fewest goals conceded wins.
- If goals and goals conceded are both tied, the tied owners split the goals side bet.
- Most red cards wins the red-cards side bet.
- If red cards are tied, the tied owner with the most yellow cards wins.
- If red cards and yellow cards are both tied, the tied owners split the red-cards side bet.
- Most drafted clubs reaching the last 16 wins the last-16 side bet.
- The owner of the club that wins the Champions League wins the Champions League winner side bet.
