// The browser demo's backend: api/app/main.py, in the browser.
//
// The real backend is a thin layer: it reads the database's views and calls
// its functions, and turns a refusal (SQLSTATE GR0xx) into a 409 carrying the
// database's own words. This is the same layer for the routes the demo keeps,
// running the same SQL against PGlite: Postgres compiled to WebAssembly,
// loaded with the project's own schema (public/demo/grooming.sql, built from
// sql/ by scripts/demo-sql.mjs). Every rule a visitor runs into is the real
// one, enforced by the real database, in their own tab.
//
// Left out, because they need a server: Admin, photos of dogs and paperwork,
// and the AI reading a copy. Each visitor's database lives in memory and is
// gone when the tab closes.
import type { PGlite } from "@electric-sql/pglite";

const BASE = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

// --- What the database did ----------------------------------------------------
// Every change a visitor makes is a call to one of the database's functions;
// the banner lists them, and what the database said back.
export type DemoLogEntry = { at: Date; calls: string[]; outcome: "ok" | "refused"; detail?: string };
const log: DemoLogEntry[] = [];
const listeners = new Set<() => void>();
export const demoLog = () => log;
export function onDemoLog(f: () => void) { listeners.add(f); return () => { listeners.delete(f); }; }

// --- Starting the database ----------------------------------------------------
type Row = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
type Q = { query: PGlite["query"] };

let ready: Promise<PGlite> | null = null;
// Where starting up has got to, for the banner; "ready" once the shop is built.
let status = "Starting…";
export const demoStatus = () => status;
/** What was built: the schema's own tables and functions, counted by the database. */
let shop: { functions: number; tables: number } | null = null;
export const demoShop = () => shop;
function progress(step: string) { status = step; listeners.forEach((f) => f()); }

// Values as the real backend's JSON has them: dates "2026-10-08", shop times
// "2026-10-08T10:00:00", numbers as numbers.
const parsers = {
  1082: (v: string) => v,                                           // date
  1083: (v: string) => v,                                           // time
  1114: (v: string) => v.replace(" ", "T"),                         // timestamp (shop time)
  1184: (v: string) => v.replace(" ", "T").replace(/([+-]\d\d)$/, "$1:00"), // timestamptz
  1700: (v: string) => Number(v),                                   // numeric
  20: (v: string) => Number(v),                                     // bigint
};

export function startDemoDatabase(): Promise<PGlite> {
  ready ??= (async () => {
    progress("Loading Postgres into your browser…");
    // Served as plain files beside the page (scripts/demo-files.mjs), not
    // bundled: PGlite finds its WebAssembly next to its own script.
    const load = (path: string) => import(/* webpackIgnore: true */ `${BASE}/pglite/${path}`);
    const [{ PGlite }, { btree_gist }, { pg_trgm }, { pgcrypto }] = await Promise.all([
      load("index.js"), load("contrib/btree_gist.js"), load("contrib/pg_trgm.js"), load("contrib/pgcrypto.js"),
    ]);
    const db: PGlite = await PGlite.create({ extensions: { btree_gist, pg_trgm, pgcrypto }, parsers });
    progress("Building the shop: schema, rules and demo dogs…");
    const sql = await fetch(`${BASE}/demo/grooming.sql`).then((r) => r.text());
    await db.exec(sql);
    await db.exec("SET search_path = groom, public");
    const counts = await row(db, `SELECT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                           WHERE n.nspname = 'groom')::int AS functions,
                                         (SELECT count(*) FROM pg_tables WHERE schemaname = 'groom')::int AS tables`);
    shop = counts as { functions: number; tables: number };
    progress("ready");
    return db;
  })();
  return ready;
}

// --- Answers --------------------------------------------------------------------
class Answer {
  constructor(public status: number, public body: unknown) {}
}
const refusal = (code: string, message: string, hint: string | null = null) =>
  new Answer(409, { code, message, hint });
const notFound = (detail: string) => new Answer(404, { detail });

// A form answer the database turned down: a missing name, an email on file.
const FORM_PROBLEMS = new Set(["23505", "23514", "23503", "23502", "22007", "22008"]);

function refusalFrom(e: unknown, form = true): Answer | null {
  const err = e as { code?: string; message?: string; hint?: string };
  const code = err.code ?? "";
  if (code.startsWith("GR") || (form && FORM_PROBLEMS.has(code))) {
    let message = err.message ?? String(e);
    if (code === "23514" && message.includes("owner_contactable")) {
      message = "Add a phone number or an email, so the shop can reach the owner.";
    }
    return refusal(code, message, err.hint ?? null);
  }
  if ((err.message ?? "").includes("not an active client")) return notFound("No active dog with that id.");
  return null;
}

const rows = async (db: Q, sql: string, params: unknown[] = []) => (await db.query<Row>(sql, params)).rows;
const row = async (db: Q, sql: string, params: unknown[] = []) => (await rows(db, sql, params))[0] ?? null;
const nil = (v: unknown) => (v === undefined || v === "" ? null : v);

// --- Presentation words (as in main.py) -----------------------------------------
const ALLERGY_SEVERITY: Record<number, string> = { 1: "Mild", 2: "Moderate", 3: "Severe", 4: "Dangerous — never use" };
const HANDLING: Record<number, string> = { 1: "Easy", 2: "Some care", 3: "Needs care", 4: "Two people", 5: "Specialist only" };
const COAT_CONDITION: Record<number, string> = { 1: "Brushes out", 2: "A few tangles", 3: "Matted in places", 4: "Matted all over", 5: "Pelted" };
const COAT_DENSITY: Record<number, string> = { 1: "Thin", 2: "Light", 3: "Average", 4: "Thick", 5: "Very thick" };

function age(born: string | null): string | null {
  if (!born) return null;
  const days = Math.floor((Date.now() - new Date(`${born}T12:00:00`).getTime()) / 86_400_000);
  if (days < 7 * 26) return `${Math.floor(days / 7)} weeks`;
  const total = Math.floor((days * 12) / 365), years = Math.floor(total / 12), months = total % 12;
  return years ? `${years} yr ${months} mo` : `${months} months`;
}

// --- Routes ----------------------------------------------------------------------
type Db = Q & { transaction: <T>(f: (tx: Q) => Promise<T>) => Promise<T> };
type Ctx = { db: Db; params: string[]; query: URLSearchParams; body: Row };

// The database as a handler sees it, noting each of the database's own
// functions a change actually calls, for the log.
function tracking(db: Q & Partial<Pick<PGlite, "transaction">>, calls: string[]): Db {
  const note = (sql: string) => {
    for (const m of sql.matchAll(/SELECT\s+([a-z_]+)\(/g)) calls.push(`${m[1]}()`);
  };
  return {
    query: ((sql: string, params?: unknown[]) => { note(sql); return db.query(sql, params); }) as Q["query"],
    transaction: (f) => db.transaction!((tx) => f(tracking(tx, calls))),
  };
}
type Handler = (c: Ctx) => Promise<unknown>;
const routes: { method: string; pattern: RegExp; handler: Handler }[] = [];
const route = (method: string, path: string, handler: Handler) =>
  routes.push({ method, pattern: new RegExp(`^${path.replace(/\{[^}]+\}/g, "([^/]+)")}$`), handler });

const SEARCH_IN: Record<string, string> = {
  dog: "d.name ILIKE $1",
  owner: "(o.first_name ILIKE $1 OR o.last_name ILIKE $1 OR (o.first_name || ' ' || o.last_name) ILIKE $1)",
};
SEARCH_IN.any = `(${SEARCH_IN.dog} OR ${SEARCH_IN.owner})`;

route("GET", "/groomers", ({ db }) =>
  rows(db, "SELECT id, display_name AS name, role::text AS role FROM groomer WHERE is_active ORDER BY display_name"));

route("GET", "/dogs", async ({ db, query }) => {
  const by = query.get("by") ?? "any";
  if (!SEARCH_IN[by]) return new Answer(422, { detail: "Search by 'dog', 'owner' or 'any'." });
  return rows(db, `
    SELECT d.id, d.name, breed_label(d.breed_id, d.is_mixed, d.second_breed_id) AS breed,
           o.first_name || ' ' || o.last_name AS owner,
           c.state::text AS state, c.plain_language_label AS label,
           COALESCE(c.blocks_service, false) AS blocks_service,
           vaccines_all_current(d.id) AS in_good_standing,
           NULL::uuid AS photo,
           (SELECT l.vaccine || ': ' || lower(l.label) FROM v_check_in_vaccine l
             WHERE l.dog_id = d.id AND l.state NOT IN ('current', 'not_yet_due')
             ORDER BY l.blocks_service DESC, l.sort_order, l.vaccine LIMIT 1) AS attention
      FROM dog d
      JOIN owner o ON o.id = d.owner_id
      LEFT JOIN v_compliance_dashboard c ON c.dog_id = d.id
     WHERE d.is_active AND ${SEARCH_IN[by]}
     ORDER BY COALESCE(c.blocks_service, false) DESC, d.name
     LIMIT 200`, [`%${(query.get("q") ?? "").trim()}%`]);
});

route("GET", "/dogs/{id}", async ({ db, params: [id] }) => {
  const dog = await row(db, `
    SELECT d.id, d.name, d.sex::text AS sex, d.date_of_birth, d.is_altered,
           breed_label(d.breed_id, d.is_mixed, d.second_breed_id) AS breed, ct.name AS coat,
           o.first_name || ' ' || o.last_name AS owner, o.phone, o.email
      FROM dog d JOIN owner o ON o.id = d.owner_id JOIN coat_type ct ON ct.id = d.coat_type_id
     WHERE d.id = $1 AND d.is_active`, [id]);
  if (!dog) return notFound("No active dog with that id.");
  const profile = await row(db, `
    SELECT o.first_name, o.last_name, o.phone, o.email,
           d.name, b.name AS breed, d.is_mixed, b2.name AS second_breed, ct.code AS coat,
           d.sex::text AS sex, d.date_of_birth
      FROM dog d JOIN owner o ON o.id = d.owner_id JOIN coat_type ct ON ct.id = d.coat_type_id
      LEFT JOIN breed b ON b.id = d.breed_id LEFT JOIN breed b2 ON b2.id = d.second_breed_id
     WHERE d.id = $1`, [id]);
  const household = await row(db, `
    SELECT o.id AS owner_id,
           ARRAY(SELECT d2.name FROM dog d2 WHERE d2.owner_id = o.id AND d2.is_active
                   AND d2.id <> $1 ORDER BY d2.name) AS other_dogs
      FROM dog d JOIN owner o ON o.id = d.owner_id WHERE d.id = $1`, [id]);
  const vaccines = await rows(db, `
    SELECT vaccine_code AS code, vaccine, state::text AS state, label, expires_on,
           days_until_expiry, blocks_service, regulatory_required
      FROM v_check_in_vaccine WHERE dog_id = $1 ORDER BY sort_order, vaccine`, [id]);
  const allergies = await rows(db, `
    SELECT a.id, al.name AS allergen, al.allergy_type AS type, a.severity_ordinal AS severity,
           a.source::text AS source, a.note
      FROM allergy a JOIN allergen al ON al.id = a.allergen_id
     WHERE a.dog_id = $1 AND a.removed_at IS NULL
     ORDER BY allergy_type_order(al.allergy_type), a.severity_ordinal DESC, al.name`, [id]);
  const behaviour = await rows(db, `
    SELECT n.id, n.handling_difficulty_ordinal AS difficulty, spot_label(n.body_zone_id, n.side) AS zone,
           bz.code || COALESCE(':' || n.side, '') AS zone_code, n.trigger_kind AS trigger, n.note,
           n.observed_at::date AS observed_on, g.display_name AS observed_by
      FROM behavior_note n LEFT JOIN body_zone bz ON bz.id = n.body_zone_id
      LEFT JOIN groomer g ON g.id = n.observed_by
     WHERE n.dog_id = $1 ORDER BY n.observed_at DESC LIMIT 5`, [id]);
  const lastVisit = await row(db, `
    SELECT v.visit_date, g.display_name AS groomer, v.overall_note AS note,
           (SELECT h.style || COALESCE(', ' || h.length, '') FROM v_haircut h WHERE h.visit_id = v.id) AS haircut,
           (SELECT h.changes FROM v_haircut h WHERE h.visit_id = v.id) AS haircut_changes
      FROM visit v JOIN groomer g ON g.id = v.performed_by
     WHERE v.dog_id = $1 AND v.check_out IS NOT NULL
     ORDER BY v.visit_date DESC, v.check_in DESC NULLS LAST LIMIT 1`, [id]);
  const openVisit = await row(db, `
    SELECT v.id, v.check_in, g.display_name AS groomer
      FROM visit v JOIN groomer g ON g.id = v.performed_by
     WHERE v.dog_id = $1 AND v.check_out IS NULL AND v.visit_date = shop_now()::date
     ORDER BY v.created_at DESC LIMIT 1`, [id]);
  const requests = await rows(db, `
    SELECT vt.name AS vaccine, rr.status::text AS status, rr.channel::text AS channel, rr.next_reminder_on
      FROM record_request rr JOIN vaccine_type vt ON vt.id = rr.vaccine_type_id
     WHERE rr.dog_id = $1 AND rr.status IN ('queued', 'sent', 'responded', 'insufficient')
     ORDER BY vt.name`, [id]);
  const upcoming = await rows(db, `
    SELECT id, groomer, starts_at, ends_at, minutes, service, note FROM v_appointment
     WHERE dog_id = $1 AND status = 'booked' AND starts_at >= shop_now()::date ORDER BY starts_at`, [id]);
  const usual = await row(db, "SELECT g.id, g.display_name AS name FROM groomer g WHERE g.id = regular_groomer($1)", [id]);
  const blocking = vaccines.filter((v) => v.blocks_service);
  return {
    dog: { ...dog, age: age(dog.date_of_birth) },
    household, profile,
    can_start: blocking.length === 0,
    blocking: blocking.map((v) => `${v.vaccine}: ${String(v.label).toLowerCase()}`),
    vaccines: vaccines.map((v) => ({ ...v, hand_checked: null })),
    allergies: allergies.map((a) => ({ ...a, severity_label: ALLERGY_SEVERITY[a.severity] })),
    behaviour: behaviour.map((b) => ({ ...b, difficulty_label: HANDLING[b.difficulty] })),
    last_visit: lastVisit,
    open_visit: openVisit,
    paperwork_requests: requests,
    paperwork_waiting: [],
    appointments: upcoming,
    usual_groomer: usual,
    in_good_standing: (await row(db, "SELECT vaccines_all_current($1) AS ok", [id]))?.ok,
    photo: null,
  };
});

route("GET", "/breeds/suggest", async ({ db, query }) => {
  const q = query.get("q") ?? "";
  if (await row(db, "SELECT 1 AS ok FROM breed WHERE lower(name) = lower(btrim($1))", [q])) return [];
  return rows(db, "SELECT name, coat FROM suggest_breeds($1, 4)", [q]);
});

route("GET", "/allergens/suggest", async ({ db, query }) => {
  const q = query.get("q") ?? "";
  if (await row(db, "SELECT 1 AS ok FROM allergen WHERE lower(name) = lower(btrim($1))", [q])) return [];
  return rows(db, "SELECT name, allergy_type AS type FROM suggest_allergens($1, 4)", [q]);
});

route("GET", "/walk-in/options", async ({ db }) => ({
  coats: await rows(db, "SELECT code, name FROM coat_type ORDER BY name"),
  breeds: await rows(db, `SELECT b.name, ct.code AS coat FROM breed b
                            JOIN coat_type ct ON ct.id = b.default_coat_type_id ORDER BY b.name`),
  vaccines: await rows(db, `SELECT code, name, regulatory_required AS required FROM vaccine_type
                             WHERE regulatory_required OR required_by_policy ORDER BY regulatory_required DESC, name`),
  allergens: await rows(db, "SELECT name, allergy_type AS type FROM allergen ORDER BY allergy_type_order(allergy_type), name"),
  zones: await rows(db, "SELECT code, label AS name FROM v_handling_spot ORDER BY sort_order"),
}));

// --- Writes: each one the database's own function, refusals passed back ----------

route("POST", "/dogs/{id}/visits", async ({ db, params: [id], body }) => {
  const v = await row(db, "SELECT start_visit($1, $2) AS id", [id, body.groomer_id]);
  return row(db, `SELECT v.id, v.visit_date, v.check_in, g.display_name AS groomer
                    FROM visit v JOIN groomer g ON g.id = v.performed_by WHERE v.id = $1`, [v!.id]);
});

route("POST", "/walk-ins", ({ db, body }) => db.transaction(async (tx) => {
  let ownerId = body.owner_id ?? null;
  if (!ownerId) {
    const o = body.owner;
    ownerId = (await row(tx, "SELECT add_client($1, $2, $3, $4, $5) AS id",
      [o.first_name, o.last_name, nil(o.phone), nil(o.email), body.groomer_id]))!.id;
  }
  const d = body.dog;
  const dog = await row(tx, "SELECT add_dog($1, $2, $3, $4, $5::dog_sex, $6, $7, $8, $9, $10) AS id",
    [ownerId, d.name, nil(d.breed), nil(d.coat), d.sex ?? "unknown", nil(d.date_of_birth), body.groomer_id,
     !!d.is_mixed, nil(d.second_breed), !!d.new_breed]);
  return { owner_id: ownerId, dog_id: dog!.id };
}));

route("POST", "/dogs/{id}/shots", ({ db, params: [id], body }) =>
  row(db, "SELECT record_counter_shot($1, $2, $3, $4, $5) AS id",
    [id, body.vaccine, nil(body.administered_on), nil(body.expires_on), body.groomer_id]));

route("POST", "/dogs/{id}/ask-owner", ({ db, params: [id], body }) =>
  row(db, "SELECT ask_owner_at_counter($1, $2, $3) AS id", [id, body.vaccine, body.groomer_id]));

route("PUT", "/owners/{id}", ({ db, params: [id], body }) =>
  row(db, "SELECT update_client($1, $2, $3, $4, $5, $6) AS changed",
    [id, body.first_name, body.last_name, nil(body.phone), nil(body.email), body.groomer_id]));

route("PUT", "/dogs/{id}", ({ db, params: [id], body }) =>
  row(db, "SELECT update_dog($1, $2, $3, $4, $5::dog_sex, $6, $7, $8, $9, $10) AS changed",
    [id, body.name, nil(body.breed), nil(body.coat), body.sex ?? "unknown", nil(body.date_of_birth),
     body.groomer_id, !!body.is_mixed, nil(body.second_breed), !!body.new_breed]));

route("POST", "/dogs/{id}/allergies", ({ db, params: [id], body }) =>
  row(db, "SELECT add_allergy($1, $2, $3, $4::allergy_source, $5, $6, $7, $8) AS id",
    [id, body.allergen, body.severity, body.source ?? "owner_reported", nil(body.note), body.groomer_id,
     !!body.new_allergen, nil(body.type)]));

route("PUT", "/allergies/{id}", ({ db, params: [id], body }) =>
  row(db, "SELECT update_allergy($1, $2, $3::allergy_source, $4, $5, $6) AS changed",
    [id, body.severity, body.source, nil(body.note), body.groomer_id, nil(body.reason)]));

route("POST", "/allergies/{id}/remove", async ({ db, params: [id], body }) => {
  await row(db, "SELECT remove_allergy($1, $2, $3) AS ok", [id, body.reason, body.groomer_id]);
  return { removed: true };
});

route("POST", "/dogs/{id}/behaviour", ({ db, params: [id], body }) =>
  row(db, "SELECT add_behavior_note($1, $2, $3, $4, $5, $6) AS id",
    [id, body.difficulty, nil(body.trigger), nil(body.zone), nil(body.note), body.groomer_id]));

route("PUT", "/behaviour/{id}", ({ db, params: [id], body }) =>
  row(db, "SELECT correct_behavior_note($1, $2, $3, $4, $5, $6) AS changed",
    [id, body.difficulty, nil(body.trigger), nil(body.zone), nil(body.note), body.groomer_id]));

// --- The calendar and booking ----------------------------------------------------

route("GET", "/calendar", async ({ db, query }) => {
  const start = query.get("start"), end = query.get("end"), dog = query.get("dog_id");
  if (!dog && (!start || !end)) return new Answer(422, { detail: "Give a span of dates (start and end), or a dog." });
  return rows(db, `
    SELECT on_date, kind, dog_id, dog, owner, vaccine, groomer, note, stops_grooms, in_progress,
           appointment_id, starts_at, minutes, service, breed, vaccines_all_current(dog_id) AS in_good_standing
      FROM v_calendar_event
     WHERE ($1::date IS NULL OR on_date >= $1) AND ($2::date IS NULL OR on_date <= $2)
       AND ($3::uuid IS NULL OR dog_id = $3)
     ORDER BY on_date, starts_at NULLS LAST, kind DESC, stops_grooms DESC, dog, vaccine`, [start, end, dog]);
});

route("GET", "/services", ({ db }) =>
  rows(db, "SELECT code, name, default_minutes FROM service_type ORDER BY display_order"));

route("GET", "/booking/hours", ({ db }) =>
  row(db, `SELECT shop_opens() AS opens, shop_closes() AS closes, shop_now()::date AS today,
                  shop_policy_int('booking_step_minutes') AS step`));

route("GET", "/booking/choices", async ({ db, query }) => {
  const dog = query.get("dog_id"), at = query.get("starts_at"), minutes = Number(query.get("minutes"));
  const ignore = query.get("ignore");
  const choices = await rows(db, "SELECT * FROM booking_choices($1, $2::timestamp, $3, $4)", [dog, at, minutes, ignore]);
  for (const c of choices) {
    c.free_starts = (await rows(db, "SELECT s FROM free_starts($1, $2::date, $3, $4) AS s",
      [c.groomer_id, at, minutes, ignore])).map((r) => r.s);
  }
  const warnings = await rows(db, "SELECT * FROM appointment_warnings($1, $2::date)", [dog, at]);
  return { choices, warnings };
});

route("GET", "/appointments", ({ db, query }) =>
  rows(db, `SELECT *, vaccines_all_current(dog_id) AS in_good_standing FROM v_appointment
             WHERE status = 'booked' AND starts_at::date = $1 ORDER BY starts_at, groomer`, [query.get("day")]));

route("POST", "/appointments", ({ db, body }) =>
  row(db, "SELECT book_appointment($1, $2, $3::timestamp, $4, $5, $6, $7, $8) AS id",
    [body.dog_id, body.groomer_id, body.starts_at, body.minutes, body.service ?? "full_groom", nil(body.note),
     nil(body.other_groomer_reason), body.booked_by]));

route("PUT", "/appointments/{id}", async ({ db, params: [id], body }) => {
  await row(db, "SELECT change_appointment($1, $2, $3::timestamp, $4, $5, $6, $7) AS ok",
    [id, body.groomer_id, body.starts_at, body.minutes, nil(body.note), nil(body.other_groomer_reason), body.booked_by]);
  return { changed: true };
});

route("POST", "/appointments/{id}/cancel", async ({ db, params: [id], body }) => {
  await row(db, "SELECT cancel_appointment($1, $2, $3) AS ok", [id, nil(body.reason), body.groomer_id]);
  return { cancelled: true };
});

// --- Recording the haircut ------------------------------------------------------

route("GET", "/haircut/options", async ({ db }) => {
  const cuts = await rows(db, `
    SELECT 'clipper' AS tool, b.id AS blade_id, NULL::uuid AS comb_id,
           describe_tooling('clipper', b.id, NULL) AS label, b.length_in, 'Blade' AS kind
      FROM blade b
    UNION ALL
    SELECT 'clipper', b.id, c.id, describe_tooling('clipper', b.id, c.id), c.length_in, 'Comb'
      FROM comb c CROSS JOIN blade b WHERE b.number = 30 AND NOT b.is_finish
     ORDER BY kind, length_in DESC, label`);
  cuts.push({ tool: "scissors", blade_id: null, comb_id: null, label: "Scissors", length_in: null, kind: "Other" },
            { tool: "hand_strip", blade_id: null, comb_id: null, label: "Hand strip", length_in: null, kind: "Other" });
  return {
    services: await rows(db, "SELECT code, name, carries_cut_spec AS haircut FROM service_type ORDER BY display_order"),
    styles: await rows(db, `SELECT code, name, plain_language_description AS description, is_remedial AS shave_down,
                                   min_coat_ordinal_required AS min_coat FROM style_template ORDER BY is_remedial, name`),
    lengths: (await rows(db, "SELECT code FROM length_tier ORDER BY sort_order")).map((r) => r.code),
    cuts,
    coat_condition: Object.entries(COAT_CONDITION).map(([level, label]) => ({ level: Number(level), label })),
    coat_density: Object.entries(COAT_DENSITY).map(([level, label]) => ({ level: Number(level), label })),
    pelted_level: (await row(db, "SELECT shop_policy_int('pelted_coat_level') AS n"))!.n,
    managers: await rows(db, `SELECT id, display_name AS name FROM groomer
                               WHERE is_active AND role = 'manager' ORDER BY display_name`),
  };
});

route("GET", "/dogs/{id}/haircut", async ({ db, params: [id] }) => {
  const visit = await row(db, `SELECT v.id, v.check_in, g.display_name AS groomer FROM visit v
                                 JOIN groomer g ON g.id = v.performed_by
                                WHERE v.dog_id = $1 AND v.check_out IS NULL AND v.visit_date = shop_now()::date
                                ORDER BY v.created_at DESC LIMIT 1`, [id]);
  const usual = await row(db, `SELECT t.code AS style_code, lt.code AS length, usual_style_summary(p.id) AS summary
                                 FROM dog_style_profile p JOIN style_template t ON t.id = p.style_template_id
                                 LEFT JOIN length_tier lt ON lt.id = p.length_tier_id
                                WHERE p.id = usual_style_id($1)`, [id]);
  const last = await row(db, "SELECT * FROM v_haircut WHERE dog_id = $1 ORDER BY visit_date DESC LIMIT 1", [id]);
  const booked = await row(db, `SELECT st.code FROM appointment a JOIN service_type st ON st.id = a.service_type_id
                                 WHERE a.dog_id = $1 AND a.status = 'booked' AND a.starts_at::date = shop_now()::date
                                 ORDER BY a.starts_at LIMIT 1`, [id]);
  const start = usual ? { style: usual.style_code, length: usual.length }
    : last && last.coat_ordinal_applied == null ? { style: last.style_code, length: last.length } : null;
  return {
    visit,
    usual: usual && { style_code: usual.style_code, ...usual.summary },
    last: last && {
      visit_date: last.visit_date, groomer: last.groomer, style_code: last.style_code, style: last.style,
      length: last.length, changes: last.changes, deviation_reason: last.deviation_reason,
      override_reason: last.override_reason, approved_by: last.approved_by, coat: COAT_CONDITION[last.coat_condition] ?? null,
    },
    start,
    under_age: (await row(db, "SELECT under_groom_age($1, shop_now()::date) AS u", [id]))!.u,
    booked_service: booked?.code ?? null,
  };
});

route("GET", "/dogs/{id}/haircut/plan", ({ db, params: [id], query }) =>
  rows(db, `SELECT zone_code, zone, is_hygiene, tool::text AS tool, blade_id, comb_id, cut, source
              FROM haircut_plan($1, $2, $3, $4::smallint)`,
    [id, query.get("style"), query.get("length"), query.get("coat")]));

route("POST", "/visits/{id}/finish", async ({ db, params: [id], body }) => {
  if (!body.services?.length) return refusal("form", "Tick what was done today.");
  return db.transaction(async (tx) => {
    await tx.query("SELECT record_visit_services($1, $2::text[])", [id, `{${body.services.join(",")}}`]);
    if (body.coat) {
      await tx.query("SELECT record_coat($1, $2, $3::smallint, $4::smallint, $5)",
        [id, body.groomer_id, body.coat.condition, body.coat.density, nil(body.coat.note)]);
    }
    if (body.haircut) {
      const h = body.haircut;
      const spec = await row(tx, "SELECT record_haircut($1, $2, $3, $4, $5::jsonb, $6, $7, $8, $9) AS id",
        [id, body.groomer_id, h.style, nil(h.length), JSON.stringify(h.changes ?? []), nil(h.why_different),
         nil(h.override_reason), nil(h.approved_by), !!h.shave_acknowledged]);
      if (h.keep_as_usual) {
        await tx.query("SELECT save_usual_style($1, $2, $3)", [spec!.id, body.groomer_id, nil(h.why_different)]);
      }
    }
    await tx.query("SELECT finish_visit($1, $2, $3)", [id, body.groomer_id, nil(body.note)]);
    return { finished: true };
  });
});

// --- The way in ------------------------------------------------------------------

/** Answer one request from the screens, as the real backend would. */
export async function demoFetch(method: string, path: string, body: unknown): Promise<Response> {
  const url = new URL(path, "http://demo");
  const found = routes.find((r) => r.method === method && r.pattern.test(url.pathname));
  const reply = (a: Answer) => new Response(JSON.stringify(a.body ?? null), {
    status: a.status, headers: { "Content-Type": "application/json" },
  });
  if (!found) return reply(notFound("That part of the shop isn't in the browser demo."));
  const db = await startDemoDatabase();
  const params = url.pathname.match(found.pattern)!.slice(1).map(decodeURIComponent);
  const write = method !== "GET";
  const calls: string[] = [];
  try {
    const result = await found.handler({ db: tracking(db, calls), params, query: url.searchParams, body: (body ?? {}) as Row });
    if (result instanceof Answer) {
      if (write && result.status === 409) record(calls, "refused", (result.body as Row).message);
      return reply(result);
    }
    // Reading back what was saved isn't a change; only the database's functions are listed.
    if (write) record(calls, "ok");
    return reply(new Answer(method === "POST" && /\/(visits|walk-ins|shots|allergies|behaviour|appointments)$/.test(url.pathname) ? 201 : 200, result));
  } catch (e) {
    const r = refusalFrom(e);
    if (r) {
      if (write) record(calls, "refused", `${(r.body as Row).code}: ${(r.body as Row).message}`);
      return reply(r);
    }
    console.error(e);
    return reply(new Answer(500, { detail: e instanceof Error ? e.message : String(e) }));
  }
}

function record(calls: string[], outcome: "ok" | "refused", detail?: string) {
  log.unshift({ at: new Date(), calls: [...new Set(calls)], outcome, detail });
  log.splice(25);
  listeners.forEach((f) => f());
}
