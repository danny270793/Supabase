# MMA ScoreCard schema

UFC events, fight cards and fighters scraped from [Sherdog](https://www.sherdog.com). Migration: `supabase/migrations/20261110120000_mma_scorecard.sql`.

The app has no sign-in, so everyone (`anon` and `authenticated`) can read every `mma_` table. Nobody can write through the API: an importer must use the service role key.

## Tables

```
mma_countries ← mma_cities ← mma_locations ← mma_events ← mma_fights
                    ↑                                       │  │  │
                mma_fighters ←──────── fighter_one_id / two ┘  │  │
                mma_categories ←──────────────── category_id ──┘  │
                mma_referees ←────────────────── referee_id ──────┘
```

| Table | What it holds |
|---|---|
| `mma_countries` | Country names. |
| `mma_cities` | City or state as Sherdog writes it (Las Vegas venues are in "Nevada"), with its country. |
| `mma_locations` | Venues, e.g. "UFC Apex, Las Vegas", with their city. |
| `mma_categories` | Weight classes. `weight` is the limit in pounds; catchweights have no weight, so "Catchweight" appears many times. |
| `mma_referees` | Referee names. |
| `mma_fighters` | Name, nickname, hometown (`city_id`), `birthday`, `died`, `height` (cm) and `weight` (kg); 0 means unknown. `link` is the Sherdog page, plus `sherdog_id` and `synced_at`. |
| `mma_events` | Name, headline `matchup`, `date`, venue, Sherdog `link`, `status` (`upcoming` / `past`), `sherdog_id` and `synced_at`. |
| `mma_fights` | One bout: event and `position` on the card, both fighters, weight class, referee, `main_event`, `title_fight`, `status` (`done` / `pending`), `decision` (e.g. KO, Submission, Decision), `method` (e.g. Unanimous, Punches), `round`, `time_seconds` into that round, and `winner`. |

`winner` is 1 when fighter one won and 2 when fighter two won. It's null for draws, no contests and fights that haven't happened. Sherdog lists the winner first, so the imported data only uses 1.

## Data

The first rows (796 events, 8,641 fights, 2,760 fighters, from 1993-11-12 to 2026-03-28) were copied from the old standalone MMA project, keeping their ids. The only change was the old status spelling `uppcoming`, which became `upcoming`. Those 11 events are now in the past, because that data stopped updating in March 2026.

`sherdog_id` is the number at the end of the Sherdog link and is what rows are matched on. Sherdog renames addresses (a placeholder "UFC-Fight-Night-London-110783" becomes "UFC-Fight-Night-270-Evloev-vs-Murphy-110783") but keeps that number.

## Keeping it up to date

The app reads only these tables. Sherdog is fetched by the `mma-sync` Edge Function (`supabase/functions/mma-sync`), which writes through the `mma_*` SQL functions. It runs in two ways.

**Hourly job** (pg_cron, minute 17, with the `x-sync-secret` header):

1. Reads the UFC organization page (one request). Upcoming events are inserted or updated. From the recent list, only events stored as upcoming are touched: they become `past` and their card is scheduled (`refresh_after`).
2. Reads the cards that are due, at most 4 per run: right after an event moves to past, and once more two days after its date for late results. Fighters it doesn't have yet are fetched first (up to 15 pages per run, saving their full `profile`); a bigger card finishes on later runs.

Upcoming cards are not re-read by the job.

**App refresh** (pull-to-refresh, or the first time a card or profile is opened and isn't stored), `POST /functions/v1/mma-sync` without the secret:

| Query | Re-reads |
|---|---|
| `?refresh=events` | the organization page |
| `?refresh=event&link=<stored event link>` | that event's card (finished events are never re-read) |
| `?refresh=fighter&link=<Sherdog fighter link>` | that fighter page, stored with its full `profile` |

Each key hits Sherdog at most once every 5 minutes, and all app refreshes together at most 20 times every 5 minutes (`mma_claim_refresh`, `mma_refresh_claims`). A refresh that's skipped returns `{"refreshed": false, "reason": "recent"}`; the app reads the tables either way.

`mma_fighters.profile` is the whole fighter page in the app's `FighterProfile` JSON shape: record, KO/submission/decision breakdowns, team, and every professional and amateur bout, including non-UFC fights.

### Setup

The function only answers requests with the `x-sync-secret` header. The secret and the function URL are kept out of git:

```sh
supabase functions deploy mma-sync --use-api --no-verify-jwt
supabase secrets set MMA_SYNC_SECRET=<random secret>
```

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/mma-sync', 'mma_sync_url');
select vault.create_secret('<same random secret>', 'mma_sync_secret');
```

### Checking on it

```sql
-- Last runs of the cron job, and the function's responses.
select status, return_message, start_time from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'mma-sync') order by start_time desc limit 5;
select status_code, content::json->'log' as log, created from net._http_response order by created desc limit 5;
```

To run the job by hand, POST to the function URL with the `x-sync-secret` header. Add `?dry=1` to parse the organization page, one event and one fighter without writing anything.
