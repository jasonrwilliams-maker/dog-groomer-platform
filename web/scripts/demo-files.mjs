// Copies PGlite (Postgres compiled to WebAssembly) beside the demo's pages,
// as plain files: the browser loads it from there (lib/demo/backend.ts), and
// PGlite finds its .wasm and .data next to its own script. Only the engine and
// the three extensions the schema uses: btree_gist (no double booking),
// pg_trgm ("did you mean"), pgcrypto (Admin PINs).
//
//   node scripts/demo-files.mjs
import { cpSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const from = "node_modules/@electric-sql/pglite/dist";
const to = "public/pglite";
const EXTENSIONS = ["btree_gist", "pg_trgm", "pgcrypto"];

rmSync(to, { recursive: true, force: true });
mkdirSync(join(to, "contrib"), { recursive: true });
let n = 0;
for (const f of readdirSync(from)) {
  const wanted = (f.endsWith(".js") && !f.endsWith(".d.js")) || f.endsWith(".wasm") || f.endsWith(".data")
    || EXTENSIONS.some((e) => f === `${e}.tar.gz`);
  if (wanted) { cpSync(join(from, f), join(to, f)); n++; }
}
for (const e of EXTENSIONS) { cpSync(join(from, "contrib", `${e}.js`), join(to, "contrib", `${e}.js`)); n++; }
console.log(`${n} PGlite files -> ${to}`);
