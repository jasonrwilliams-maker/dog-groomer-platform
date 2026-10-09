// Gathers the schema and the demo dogs into one file for the browser demo:
// the same SQL files, in the same order, that api/load_demo.sh feeds psql.
//
//   node scripts/demo-sql.mjs ../sql public/demo/grooming.sql
//
// The browser's Postgres (PGlite) runs SQL, not psql, so psql's own commands
// (lines starting with a backslash, such as the style seed's optional
// "\if :{?reason}" block) are taken out. Nothing else is changed.
//
// Only files in the repository go in. The demo database on the shop's own
// computer, with its uploaded paperwork and photos, is never read.
import { readdirSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";

const [sqlDir, out] = process.argv.slice(2);
if (!sqlDir || !out) {
  console.error("usage: node scripts/demo-sql.mjs <sql dir> <output file>");
  process.exit(1);
}

const sections = readdirSync(sqlDir).filter((f) => /^\d\d_.*\.sql$/.test(f)).sort();
const files = ["grooming_platform_schema.sql", ...sections, "seed/demo.sql"];

function withoutPsqlCommands(sql) {
  const kept = [];
  let skipping = 0;
  for (const line of sql.split(/\r?\n/)) {
    const t = line.trim();
    if (t.startsWith("\\if")) { skipping++; continue; }
    if (t.startsWith("\\endif")) { skipping = Math.max(0, skipping - 1); continue; }
    if (skipping || t.startsWith("\\")) continue;
    kept.push(line);
  }
  return kept.join("\n");
}

const body = files.map((f) => `-- ===== ${f} =====\n${withoutPsqlCommands(readFileSync(join(sqlDir, f), "utf8"))}\n`).join("\n");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `-- Built by web/scripts/demo-sql.mjs from sql/ — do not edit.\n${body}`);
console.log(`${files.length} files, ${Math.round(body.length / 1024)} KB -> ${out}`);
