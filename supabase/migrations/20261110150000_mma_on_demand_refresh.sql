-- MMA ScoreCard: fewer Sherdog requests.
--
-- The hourly job now reads only the UFC organization page. It adds upcoming
-- events, and when an event moves from upcoming to recent it schedules its
-- card to be read (right away, and again two days after the event for late
-- results). Upcoming cards are read only when someone refreshes in the app,
-- through the same Edge Function, limited to once every 5 minutes per event
-- and to a total of 20 Sherdog fetches every 5 minutes.

alter table public.mma_events add column refresh_after timestamptz;

comment on column public.mma_events.refresh_after is
  'When the hourly job should read this event''s card again; null = not scheduled';

-- Events added since March 2026 that still have no card: read them once.
update public.mma_events e set refresh_after = now()
where e.status = 'past' and e.date >= date '2026-03-01'
  and not exists (select 1 from public.mma_fights f where f.event_id = e.id);

-- Last time each on-demand refresh ("events", "event:<sherdog id>") hit Sherdog.
create table public.mma_refresh_claims (
  key text primary key,
  claimed_at timestamptz not null
);

comment on table public.mma_refresh_claims is
  'Rate limit for app-triggered Sherdog refreshes; written by mma_claim_refresh only';

alter table public.mma_refresh_claims enable row level security;
revoke all on public.mma_refresh_claims from public, anon, authenticated;

-- True when the caller may fetch Sherdog for p_key now: the key wasn't
-- fetched within p_window, and fewer than p_cap fetches of any key happened
-- within p_window. Claiming is atomic, so two simultaneous refreshes of the
-- same event fetch Sherdog once.
create function public.mma_claim_refresh(p_key text, p_window interval, p_cap integer)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  if (select count(*) from public.mma_refresh_claims where claimed_at > now() - p_window) >= p_cap then
    return false;
  end if;
  insert into public.mma_refresh_claims as c (key, claimed_at) values (p_key, now())
  on conflict (key) do update set claimed_at = now()
  where c.claimed_at <= now() - p_window;
  return found;
end;
$$;

-- p_upcoming: the organization page's upcoming events, inserted or updated.
-- p_recent: its recent events; only events stored as upcoming are touched,
-- turning them past and scheduling their card. Returns rows changed.
create function public.mma_upsert_event_lists(p_upcoming jsonb, p_recent jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_changed integer := public.mma_upsert_events(p_upcoming);
  v_rows integer;
begin
  update public.mma_events e set
    name = r->>'name',
    matchup = nullif(btrim(r->>'matchup'), ''),
    date = (r->>'date')::date,
    link = r->>'link',
    status = 'past',
    location_id = public.mma_location_id(r->>'location'),
    refresh_after = now()
  from jsonb_array_elements(p_recent) r
  where e.sherdog_id = public.mma_sherdog_id(r->>'link') and e.status = 'upcoming';
  get diagnostics v_rows = row_count;
  return v_changed + v_rows;
end;
$$;

-- After a card is read: past events within two days of their date are read
-- once more at date + 2 days (late results); otherwise nothing is scheduled.
create or replace function public.mma_after_event_sync(p_event_link text)
returns void
language sql
set search_path = ''
as $$
  update public.mma_events set
    synced_at = now(),
    refresh_after = case
      when status = 'past' and now() < date + interval '2 days' then date + interval '2 days'
      else null
    end
  where sherdog_id = public.mma_sherdog_id(p_event_link)
$$;

-- What the hourly job reads: events whose card is due.
create or replace function public.mma_sync_plan(p_event_limit integer, p_fighter_limit integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(link order by refresh_after)
      from (
        select link, refresh_after from public.mma_events
        where refresh_after <= now()
        order by refresh_after
        limit p_event_limit
      ) due), '[]'::jsonb),
    'fighters', '[]'::jsonb)
$$;

revoke all on function public.mma_claim_refresh(text, interval, integer) from public, anon, authenticated;
revoke all on function public.mma_upsert_event_lists(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.mma_after_event_sync(text) from public, anon, authenticated;
grant execute on function public.mma_claim_refresh(text, interval, integer) to service_role;
grant execute on function public.mma_upsert_event_lists(jsonb, jsonb) to service_role;
grant execute on function public.mma_after_event_sync(text) to service_role;
