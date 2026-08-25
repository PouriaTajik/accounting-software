#!/usr/bin/env node
/**
 * Regenerate db/schema.sql from a fully migrated database.
 *
 *   DATABASE_URL=... node scripts/snapshot-schema.mjs
 *   DATABASE_URL=... node scripts/snapshot-schema.mjs --check
 *
 * `--check` writes nothing and exits non-zero if the committed snapshot does
 * not match the database. That is the CI form: it catches a migration that
 * landed without its snapshot, so the file in the repo is never stale.
 *
 * Node rather than a shell one-liner so it behaves the same on Windows, which
 * is a supported development platform for the desktop app.
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const target = join(repoRoot, "db", "schema.sql");

const HEADER = `-- =============================================================================
-- GENERATED FILE -- DO NOT EDIT.
--
-- A snapshot of the schema as produced by applying every migration in
-- db/migrations/ in order, dumped with pg_dump --schema-only. It exists to be
-- read and to be diffed in review: one file showing the current shape of the
-- database, without replaying the migration history in your head.
--
-- Nothing applies this file. Databases are built by the migration runner:
--
--     python -m accounting_api.migrate
--
-- Regenerate after adding a migration:
--
--     npm run db:snapshot
--
-- The hand-written, commented DDL lives in db/migrations/. Read those for the
-- reasoning; read this for the current state.
-- =============================================================================

`;

const databaseUrl = process.env.DATABASE_URL ?? process.env.ACCOUNTING_DATABASE_URL;
if (!databaseUrl) {
  console.error("DATABASE_URL (or ACCOUNTING_DATABASE_URL) must be set.");
  process.exit(2);
}

let dump;
try {
  dump = execFileSync(
    "pg_dump",
    ["--schema-only", "--no-owner", "--no-privileges", "--dbname", databaseUrl],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
} catch (error) {
  console.error(`pg_dump failed: ${error.message}`);
  process.exit(2);
}

// Recent pg_dump wraps its output in `\restrict <token>` / `\unrestrict
// <token>` psql meta-commands, where the token is randomly generated per run.
// Left in, every snapshot would differ from the last and --check could never
// pass. They are a guard for restoring untrusted dumps through psql; nothing
// restores this file, so dropping them costs nothing and makes the artifact
// reproducible -- which is the only reason it is worth committing.
const normalized = dump
  .split("\n")
  .filter((line) => !/^\\(un)?restrict\s/.test(line))
  .join("\n");

const snapshot = HEADER + normalized;

if (process.argv.includes("--check")) {
  let committed;
  try {
    committed = readFileSync(target, "utf8");
  } catch {
    console.error(`db/schema.sql is missing. Run: npm run db:snapshot`);
    process.exit(1);
  }
  if (committed !== snapshot) {
    console.error(
      "db/schema.sql is out of date with db/migrations/.\n" +
        "Apply migrations to a fresh database and run: npm run db:snapshot",
    );
    process.exit(1);
  }
  console.log("db/schema.sql matches the migrated schema");
  process.exit(0);
}

writeFileSync(target, snapshot);
console.log(`wrote ${target}`);
