// mma-sync: scrapes Sherdog's UFC pages and keeps the mma_ tables current.
//
// Two callers:
//
// * pg_cron, hourly, with `x-sync-secret: $MMA_SYNC_SECRET` (the job). It
//   reads only the UFC organization page: upcoming events are inserted or
//   updated, and events that moved from upcoming to recent are marked past
//   and their card scheduled (`refresh_after`). It then reads the cards that
//   are due (at most EVENT_LIMIT), fetching fighters it doesn't have yet.
//
// * The app, on pull-to-refresh, without the secret:
//     POST ?refresh=events             re-read the organization page
//     POST ?refresh=event&link=<url>   re-read one stored event's card
//     POST ?refresh=fighter&link=<url> re-read a fighter page (stored with
//                                      the full profile the app shows)
//   Each key hits Sherdog at most once every REFRESH_WINDOW, and all app
//   refreshes together at most REFRESH_CAP times per window
//   (mma_claim_refresh). Finished events (all bouts have results and the
//   event is over a week old) are never re-read. The app then reads the
//   tables, which are public.
//
// The matching and writing happen in the mma_* SQL functions; this file only
// scrapes. With the secret, `?dry=1` parses the organization page, one event
// and one fighter and returns them without writing anything.

import { createClient } from "npm:@supabase/supabase-js@2";
import { parseHTML } from "npm:linkedom@0.18";

// linkedom's DOM objects, typed loosely: Deno doesn't ship the DOM lib.
// deno-lint-ignore no-explicit-any
type Element = any;
// deno-lint-ignore no-explicit-any
type HTMLDocument = any;

const BASE = "https://www.sherdog.com";
const ORG_URL = `${BASE}/organizations/Ultimate-Fighting-Championship-UFC-2`;
const USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36";

/** Cards the hourly job reads per run, and fighter pages fetched per request. */
const EVENT_LIMIT = 4;
const FIGHTER_FETCH_BUDGET = 15;
const DELAY_MS = 400;
/** App refreshes: one Sherdog fetch per key per window, REFRESH_CAP in total. */
const REFRESH_WINDOW = "5 minutes";
const REFRESH_CAP = 20;

type EventRow = { name: string; matchup: string | null; date: string; link: string; status: string; location: string };
type FightRow = {
  position: number;
  fighter_one_link: string | null;
  fighter_two_link: string | null;
  category: string | null;
  referee: string | null;
  main_event: boolean;
  title_fight: boolean;
  status: "done" | "pending";
  method: string | null;
  decision: string | null;
  round: number | null;
  time_seconds: number | null;
  winner: 1 | 2 | null;
};
type FighterRow = {
  name: string;
  nickname: string | null;
  city: string | null;
  country: string | null;
  birthday: string | null;
  died: string | null;
  height: number | null;
  weight: number | null;
  link: string;
  profile: Record<string, unknown>;
};

// ---------------------------------------------------------------- fetching

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function fetchDoc(url: string): Promise<HTMLDocument> {
  const res = await fetch(url, { headers: { "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(15000) });
  if (res.status !== 200) throw new Error(`Sherdog returned HTTP ${res.status} for ${url}`);
  // deno-lint-ignore no-explicit-any
  const { document } = parseHTML(await res.text()) as any;
  await sleep(DELAY_MS);
  return document;
}

// ---------------------------------------------------------------- parsing

const clean = (s: string | null | undefined) => (s ?? "").replace(/\s+/g, " ").trim();
const absolute = (href: string) => (href.startsWith("http") ? href : BASE + href);
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "Dec 11, 1990" -> "1990-12-11"; anything else (e.g. "N/A") -> null. */
function isoDate(text: string | null | undefined): string | null {
  const m = clean(text).match(/^([A-Z][a-z]{2})\s+(\d{1,2}),\s*(\d{4})$/);
  if (!m) return null;
  const month = MONTHS.indexOf(m[1]) + 1;
  if (month === 0) return null;
  return `${m[3]}-${String(month).padStart(2, "0")}-${m[2].padStart(2, "0")}`;
}

/** "5:00" -> 300. */
function seconds(text: string | null | undefined): number | null {
  const m = clean(text).match(/^(\d+):(\d{2})$/);
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

function int(text: string | null | undefined): number | null {
  const n = parseInt(clean(text), 10);
  return Number.isFinite(n) ? n : null;
}

/** "TKO (Corner Stoppage)" -> decision "TKO", method "Corner Stoppage". */
function result(text: string | null | undefined): { decision: string | null; method: string | null } {
  const t = clean(text);
  if (!t) return { decision: null, method: null };
  const m = t.match(/^(.*?)\s*\((.*)\)\s*$/);
  return m ? { decision: m[1] || null, method: m[2] || null } : { decision: t, method: null };
}

/** win / loss / draw / no contest / yet to come, from a `.final_result` span. */
function outcome(el: Element | null): "win" | "loss" | "draw" | "nc" | "pending" {
  if (!el) return "pending";
  const cls = el.className;
  if (/\bwin\b/.test(cls)) return "win";
  if (/\bloss\b/.test(cls)) return "loss";
  if (/\bdraw\b/.test(cls)) return "draw";
  if (/no_contest/.test(cls) || /no contest/i.test(el.textContent)) return "nc";
  return "pending";
}

/** Fighter page link, or null for placeholders ("Unknown Fighter" links to javascript:void()). */
function fighterLink(cell: Element | null): string | null {
  const href = cell?.querySelector("a[itemprop=url]")?.getAttribute("href") ?? "";
  return /^(https?:\/\/www\.sherdog\.com)?\/fighter\/.+-\d+$/.test(href) ? absolute(href) : null;
}

/** Organization page: first `table.new_table.event` is upcoming, second recent. */
export function parseEvents(doc: HTMLDocument): EventRow[] {
  const out: EventRow[] = [];
  const tables = [...doc.querySelectorAll("table.new_table.event")] as Element[];
  tables.slice(0, 2).forEach((table, i) => {
    for (const row of [...table.querySelectorAll("tr[itemtype='http://schema.org/Event']")] as Element[]) {
      const date = row.querySelector("meta[itemprop=startDate]")?.getAttribute("content")?.slice(0, 10);
      const href = row.querySelector("a[itemprop=url]")?.getAttribute("href");
      const title = clean(row.querySelector("span[itemprop=name]")?.textContent);
      if (!date || !href || !title) continue;
      // "UFC 334 - Gane vs. Hokit": event name, then the headline bout.
      const [name, ...rest] = title.split(" - ");
      out.push({
        name: name.trim(),
        matchup: rest.length ? rest.join(" - ").trim() : null,
        date,
        link: absolute(href),
        status: i === 0 ? "upcoming" : "past",
        location: clean(row.querySelector("td[itemprop=location]")?.textContent),
      });
    }
  });
  return out;
}

/** Event page: the headliner `.fight_card` block, then `tr[itemprop=subEvent]` rows. */
export function parseFights(doc: HTMLDocument): FightRow[] {
  const fights: FightRow[] = [];

  for (const row of [...doc.querySelectorAll("table.new_table tr[itemprop=subEvent]")] as Element[]) {
    const cells = [...row.querySelectorAll("td")] as Element[];
    const left = row.querySelector("td.text_right");
    const right = row.querySelector("td.text_left");
    const center = row.querySelector("td.text_center");
    const position = int(cells[0]?.textContent);
    if (!left || !right || position === null) continue;
    const winby = row.querySelector("td.winby");
    const hasResult = cells.length >= 7;
    const leftResult = outcome(left.querySelector(".final_result"));
    fights.push(fight({
      position,
      left: fighterLink(left),
      right: fighterLink(right),
      category: clean(center?.querySelector(".weight_class")?.textContent) || null,
      title: !!center?.querySelector(".title_fight"),
      main: false,
      leftResult,
      resultText: clean(winby?.querySelector("b")?.textContent),
      referee: clean(winby?.querySelector(".sub_line")?.textContent) || null,
      round: hasResult ? int(cells[cells.length - 2].textContent) : null,
      time: hasResult ? seconds(cells[cells.length - 1].textContent) : null,
    }));
  }

  const card = doc.querySelector("div.fight_card");
  const left = card?.querySelector(".fighter.left_side") ?? null;
  const right = card?.querySelector(".fighter.right_side") ?? null;
  if (card && left && right) {
    const versus = card.querySelector(".versus");
    const resume = card.parentElement?.querySelector("table.fight_card_resume") ?? null;
    const field = (label: string) => {
      for (const td of [...(resume?.querySelectorAll("td") ?? [])] as Element[]) {
        const em = td.querySelector("em");
        if (clean(em?.textContent) === label) return clean(td.textContent).slice(label.length).trim() || null;
      }
      return null;
    };
    // Upcoming cards have no "Match" number for the headliner: it's the top of the card.
    const position = int(field("Match")) ?? Math.max(0, ...fights.map((f) => f.position)) + 1;
    fights.unshift(fight({
      position,
      left: fighterLink(left),
      right: fighterLink(right),
      category: clean(versus?.querySelector(".weight_class")?.textContent) || null,
      title: !!versus?.querySelector(".title_fight"),
      main: true,
      leftResult: outcome(left.querySelector(".final_result")),
      resultText: field("Method"),
      referee: field("Referee"),
      round: int(field("Round")),
      time: seconds(field("Time")),
    }));
  }
  return fights;
}

function fight(p: {
  position: number;
  left: string | null;
  right: string | null;
  category: string | null;
  title: boolean;
  main: boolean;
  leftResult: ReturnType<typeof outcome>;
  resultText: string | null;
  referee: string | null;
  round: number | null;
  time: number | null;
}): FightRow {
  const done = p.leftResult !== "pending";
  const { decision, method } = done ? result(p.resultText) : { decision: null, method: null };
  return {
    position: p.position,
    fighter_one_link: p.left,
    fighter_two_link: p.right,
    category: p.category,
    referee: done ? p.referee : null,
    main_event: p.main,
    title_fight: p.title,
    status: done ? "done" : "pending",
    method,
    decision,
    round: done ? p.round : null,
    time_seconds: done ? p.time : null,
    winner: p.leftResult === "win" ? 1 : p.leftResult === "loss" ? 2 : null,
  };
}

/** `<b itemprop="height">5'10"</b> <em>/</em> 177.8 cm` -> 177.8. */
function metric(doc: HTMLDocument, prop: string, unit: string): number | null {
  const text = clean(doc.querySelector(`b[itemprop=${prop}]`)?.parentElement?.textContent);
  const m = text.match(new RegExp(`([\\d.]+)\\s*${unit}\\b`));
  return m ? Number(m[1]) : null;
}

/** "<b itemprop=height>5'10"</b> <em>/</em> 177.8 cm" -> "5'10" (177.8 cm)", as the app shows it. */
function withMetric(doc: HTMLDocument, prop: string): string | null {
  const text = clean(doc.querySelector(`b[itemprop=${prop}]`)?.parentElement?.textContent);
  if (!text) return null;
  const parts = text.split("/");
  return parts.length === 2 ? `${parts[0].trim()} (${parts[1].trim()})` : text;
}

function breakdown(doc: HTMLDocument, scope: string) {
  const meters = [...doc.querySelectorAll(`${scope} .meter`)] as Element[];
  const meter = (i: number) => ({
    count: int(meters[i]?.querySelector(".pl")?.textContent) ?? 0,
    percent: int(clean(meters[i]?.querySelector(".pr")?.textContent).replace("%", "")) ?? 0,
  });
  return { koTko: meter(0), submissions: meter(1), decisions: meter(2) };
}

/** "May / 09 / 2026" as a sortable number, or null. */
function historyDate(text: string | null): number | null {
  const parts = (text ?? "").split("/").map((p) => p.trim());
  const m = MONTHS.indexOf(parts[0]);
  if (parts.length !== 3 || m < 0 || !/^\d+$/.test(parts[1]) || !/^\d+$/.test(parts[2])) return null;
  return Number(parts[2]) * 10000 + (m + 1) * 100 + Number(parts[1]);
}

const OUTCOME_JSON = { win: "win", loss: "loss", draw: "draw", nc: "noContest", pending: "pending" } as const;

/** Professional and amateur bouts, newest first (the app's FighterFightRecord shape). */
function history(doc: HTMLDocument) {
  const records: { date: number | null; i: number; r: Record<string, unknown> }[] = [];
  for (const table of [...doc.querySelectorAll("table.new_table.fighter")] as Element[]) {
    // The "Fight History - Amateur" title sits in the same <section> as its table.
    const scope = table.closest("section") ?? table.parentElement;
    const title = clean((scope?.querySelector(".slanted_title") ?? scope?.querySelector("h2") ?? scope)?.textContent)
      .toLowerCase();
    const isAmateur = title.includes("fight history") && title.includes("amateur");
    for (const row of [...table.querySelectorAll("tr")] as Element[]) {
      if (row.classList?.contains("table_head")) continue;
      const cells = [...row.querySelectorAll("td")] as Element[];
      if (cells.length < 4) continue;
      const opponent = cells[1].querySelector("a");
      const event = cells[2].querySelector("a");
      const eventDateText = clean(cells[2].querySelector(".sub_line")?.textContent) || null;
      records.push({
        date: historyDate(eventDateText),
        i: records.length,
        r: {
          outcome: OUTCOME_JSON[outcome(cells[0].querySelector(".final_result"))],
          opponentName: clean(opponent?.textContent),
          opponentUrl: opponent?.getAttribute("href") ? absolute(opponent.getAttribute("href")) : null,
          eventName: clean(event?.textContent),
          eventUrl: event?.getAttribute("href") ? absolute(event.getAttribute("href")) : null,
          eventDateText,
          method: clean(cells[3].querySelector("b")?.textContent) || null,
          referee: clean(cells[3].querySelector(".sub_line")?.textContent) || null,
          round: cells.length > 4 ? clean(cells[4].textContent) : null,
          time: cells.length > 5 ? clean(cells[5].textContent) : null,
          isAmateur,
        },
      });
    }
  }
  // Newest first; undated rows last; same-day rows keep page order.
  records.sort((a, b) => {
    if (a.date !== null && b.date !== null && a.date !== b.date) return b.date - a.date;
    if (a.date === null && b.date !== null) return 1;
    if (a.date !== null && b.date === null) return -1;
    return a.i - b.i;
  });
  return records.map((x) => x.r);
}

/**
 * Fighter page: the mma_fighters row plus `profile`, the full page in the
 * app's FighterProfile JSON shape (record, breakdowns, every bout).
 */
export function parseFighter(doc: HTMLDocument, link: string): FighterRow | null {
  const name = clean(doc.querySelector("h1 span.fn")?.textContent);
  if (!name) return null;
  const text = (css: string) => clean(doc.querySelector(css)?.textContent) || null;
  let age: number | null = null;
  for (const tr of [...doc.querySelectorAll("table tr")] as Element[]) {
    if (clean(tr.querySelector("td")?.textContent) === "AGE") {
      age = int(tr.querySelector("td b")?.textContent);
      break;
    }
  }
  return {
    name,
    nickname: text("span.nickname em"),
    city: text("span[itemprop=addressLocality]"),
    country: text("strong[itemprop=nationality]"),
    birthday: isoDate(doc.querySelector("span[itemprop=birthDate]")?.textContent),
    died: isoDate(doc.querySelector("span[itemprop=deathDate]")?.textContent),
    height: metric(doc, "height", "cm"),
    weight: metric(doc, "weight", "kg"),
    link,
    profile: {
      name,
      nationality: text("strong[itemprop=nationality]"),
      hometown: text("span[itemprop=addressLocality]"),
      age,
      birthDate: text("span[itemprop=birthDate]"),
      height: withMetric(doc, "height"),
      weight: withMetric(doc, "weight"),
      association: text("span[itemprop=memberOf] span[itemprop=name]"),
      weightClass: text(".association-class a[href*='weightclass=']"),
      wins: int(text(".wins .winloses span:last-child")) ?? 0,
      losses: int(text(".loses .winloses span:last-child")) ?? 0,
      winsBreakdown: breakdown(doc, ".wins"),
      lossesBreakdown: breakdown(doc, ".loses"),
      fightHistory: history(doc),
    },
  };
}

// ---------------------------------------------------------------- sync

// deno-lint-ignore no-explicit-any
type Db = any;

const rpcWith = (db: Db) => async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
};

/** Reads the organization page; upcoming events upserted, recent ones only to mark past. */
async function syncEventLists(db: Db): Promise<string> {
  const events = parseEvents(await fetchDoc(ORG_URL));
  const changed = await rpcWith(db)<number>("mma_upsert_event_lists", {
    p_upcoming: events.filter((e) => e.status === "upcoming"),
    p_recent: events.filter((e) => e.status === "past"),
  });
  return `org page: ${events.length} events, ${changed} inserted or changed`;
}

/** Reads one card, fetching up to `budget` new fighters. Returns a log line. */
async function syncEvent(db: Db, link: string, budget: { left: number }): Promise<string> {
  const rpc = rpcWith(db);
  const fights = parseFights(await fetchDoc(link));
  let res = await rpc<Record<string, unknown>>("mma_sync_event_fights", { p_event_link: link, p_fights: fights });
  const missing = (res.missing_fighters as string[] | undefined) ?? [];
  if (missing.length) {
    const fetchNow = missing.slice(0, Math.max(0, budget.left));
    for (const f of fetchNow) {
      budget.left--;
      const row = parseFighter(await fetchDoc(f), f);
      if (row) await rpc("mma_upsert_fighter", { p: row });
    }
    // A big new card finishes on a later run or refresh.
    if (fetchNow.length < missing.length) {
      return `${link}: ${missing.length - fetchNow.length} of ${missing.length} new fighters left for later`;
    }
    res = await rpc("mma_sync_event_fights", { p_event_link: link, p_fights: fights });
  }
  await rpc("mma_after_event_sync", { p_event_link: link });
  return `${link}: ${fights.length} fights ${JSON.stringify(res)}`;
}

async function runJob(db: Db): Promise<string[]> {
  const log = [await syncEventLists(db)];
  const plan = await rpcWith(db)<{ events: string[] }>("mma_sync_plan", { p_event_limit: EVENT_LIMIT, p_fighter_limit: 0 });
  const budget = { left: FIGHTER_FETCH_BUDGET };
  for (const link of plan.events) {
    try {
      log.push(await syncEvent(db, link, budget));
    } catch (e) {
      log.push(`${link}: ${(e as Error).message}`);
    }
  }
  return log;
}

/** App pull-to-refresh: `{refreshed, reason?}`; the app reads the tables afterwards. */
async function appRefresh(db: Db, params: URLSearchParams): Promise<Response> {
  const rpc = rpcWith(db);
  const claim = (key: string) =>
    rpc<boolean>("mma_claim_refresh", { p_key: key, p_window: REFRESH_WINDOW, p_cap: REFRESH_CAP });

  if (params.get("refresh") === "events") {
    if (!(await claim("events"))) return Response.json({ refreshed: false, reason: "recent" });
    await syncEventLists(db);
    return Response.json({ refreshed: true });
  }

  if (params.get("refresh") === "event") {
    const link = params.get("link") ?? "";
    const sherdogId = link.match(/-(\d+)$/)?.[1];
    if (!sherdogId) return Response.json({ error: "link must be a Sherdog event link" }, { status: 400 });
    // Only stored events, so this can't be used to fetch arbitrary pages.
    const { data: event, error } = await db
      .from("mma_events").select("id, link, date, status").eq("sherdog_id", sherdogId).maybeSingle();
    if (error) throw new Error(error.message);
    if (!event) return Response.json({ error: "unknown event" }, { status: 404 });

    const weekAgo = new Date(Date.now() - 7 * 86400_000).toISOString().slice(0, 10);
    if (event.status === "past" && event.date < weekAgo) {
      const { count } = await db.from("mma_fights").select("id", { count: "exact", head: true })
        .eq("event_id", event.id).eq("status", "pending");
      const { count: total } = await db.from("mma_fights").select("id", { count: "exact", head: true })
        .eq("event_id", event.id);
      if ((total ?? 0) > 0 && (count ?? 0) === 0) return Response.json({ refreshed: false, reason: "final" });
    }
    if (!(await claim(`event:${sherdogId}`))) return Response.json({ refreshed: false, reason: "recent" });
    console.log(await syncEvent(db, event.link, { left: FIGHTER_FETCH_BUDGET }));
    return Response.json({ refreshed: true });
  }

  if (params.get("refresh") === "fighter") {
    // Any Sherdog fighter page (opponents in a history may not be stored yet).
    const link = params.get("link") ?? "";
    const m = link.match(/^https:\/\/www\.sherdog\.com\/fighter\/[A-Za-z0-9-]+-(\d+)$/);
    if (!m) return Response.json({ error: "link must be a Sherdog fighter link" }, { status: 400 });
    if (!(await claim(`fighter:${m[1]}`))) return Response.json({ refreshed: false, reason: "recent" });
    const row = parseFighter(await fetchDoc(link), link);
    if (!row) return Response.json({ error: "not a fighter page" }, { status: 404 });
    await rpc("mma_upsert_fighter", { p: row });
    return Response.json({ refreshed: true });
  }

  return Response.json(
    { error: "use ?refresh=events, ?refresh=event&link=<event link> or ?refresh=fighter&link=<fighter link>" },
    { status: 400 },
  );
}

if (import.meta.main) Deno.serve(async (req) => {
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const params = new URL(req.url).searchParams;
  const secret = Deno.env.get("MMA_SYNC_SECRET");
  const isJob = !!secret && req.headers.get("x-sync-secret") === secret;

  try {
    if (!isJob) {
      if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
      return await appRefresh(db, params);
    }

    if (params.get("dry") === "1") {
      const events = parseEvents(await fetchDoc(ORG_URL));
      const sample = events.find((e) => e.status === "past") ?? events[0];
      const fights = sample ? parseFights(await fetchDoc(sample.link)) : [];
      const link = fights[0]?.fighter_one_link;
      const fighter = link ? parseFighter(await fetchDoc(link), link) : null;
      return Response.json({ events: events.length, sample, fights, fighter });
    }

    const started = Date.now();
    const log = await runJob(db);
    log.push(`${Date.now() - started} ms`);
    log.forEach((l) => console.log(l));
    return Response.json({ ok: true, log });
  } catch (e) {
    console.error(e);
    return Response.json({ ok: false, error: (e as Error).message }, { status: 500 });
  }
});
