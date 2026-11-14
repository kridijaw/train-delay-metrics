import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DuckDBInstance, type DuckDBValue } from "@duckdb/node-api";
import { normalizeRow } from "../src/db/normalize";
import type { Db } from "../src/db/types";
import { createStopEventsView } from "../src/db/view";

export interface NodeDb extends Db {
  close(): void;
}

export async function createNodeDb(): Promise<NodeDb> {
  const instance = await DuckDBInstance.create(":memory:");
  const conn = await instance.connect();
  return {
    async exec(sql) {
      await conn.run(sql);
    },
    async all(sql, binds) {
      const reader = await conn.runAndReadAll(sql, binds as DuckDBValue[]);
      return reader.getRowObjectsJS().map((row) => normalizeRow(row as Record<string, unknown>));
    },
    close() {
      conn.closeSync();
      instance.closeSync();
    },
  };
}

const FIXTURE_DIR = new URL("../../spec/fixtures/", import.meta.url);

// Writes spec/fixtures/<name>.sql to a temp Parquet file and points stop_events at it,
// the same fixture rspec writes through FixtureHelper#write_fixture.
export async function withFixture(name: string): Promise<{ db: NodeDb; cleanup(): void }> {
  const dir = mkdtempSync(join(tmpdir(), "train-delay-web-"));
  const out = join(dir, `${name}.parquet`);
  const db = await createNodeDb();
  const sql = readFileSync(new URL(`${name}.sql`, FIXTURE_DIR), "utf8").replaceAll("__OUT__", out.replaceAll("'", "''"));
  await db.exec(sql);
  await createStopEventsView(db, [out]);
  return {
    db,
    cleanup() {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

export function readShared<T>(name: string): T {
  return JSON.parse(readFileSync(new URL(`../../spec/shared/${name}`, import.meta.url), "utf8")) as T;
}
