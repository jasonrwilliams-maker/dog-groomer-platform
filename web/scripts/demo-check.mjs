// Loads public/demo/grooming.sql into PGlite, the way the browser demo does,
// and checks a few things the screens rely on. Run after demo-sql.mjs:
//
//   node scripts/demo-check.mjs public/demo/grooming.sql
import { readFileSync } from "node:fs";
import { PGlite } from "@electric-sql/pglite";
import { btree_gist } from "@electric-sql/pglite/contrib/btree_gist";
import { pg_trgm } from "@electric-sql/pglite/contrib/pg_trgm";
import { pgcrypto } from "@electric-sql/pglite/contrib/pgcrypto";

const sql = readFileSync(process.argv[2], "utf8");
const t0 = Date.now();
const db = await PGlite.create({ extensions: { btree_gist, pg_trgm, pgcrypto } });
const t1 = Date.now();
await db.exec(sql);
const t2 = Date.now();
console.log(`started in ${t1 - t0} ms, schema and demo dogs loaded in ${t2 - t1} ms`);

await db.exec("SET search_path = groom, public");
const dogs = await db.query("SELECT count(*)::int AS n FROM dog");
console.log("dogs:", dogs.rows[0].n);
const card = await db.query("SELECT vaccine, label, blocks_service FROM v_check_in_vaccine c JOIN dog d ON d.id = c.dog_id WHERE d.name = 'Jaddi'");
console.log("Jaddi:", card.rows);
try {
  await db.query("SELECT start_visit((SELECT id FROM dog WHERE name = 'Jaddi'), (SELECT id FROM groomer WHERE display_name = 'Tanya'))");
  console.log("UNEXPECTED: Jaddi's groom started");
  process.exit(1);
} catch (e) {
  console.log("refused:", e.code, e.message);
}
const suggest = await db.query("SELECT name FROM suggest_breeds('shitzu', 2)");
console.log("did you mean:", suggest.rows.map((r) => r.name));
