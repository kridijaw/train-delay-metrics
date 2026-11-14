import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { evaBucket } from "../src/lib/evaBucket";
import { createNodeDb, type NodeDb } from "./nodeDb";

const factsAll = readFileSync(new URL("../scripts/sql/facts_all.sql", import.meta.url), "utf8");
const bucketExpr = /\n\s*(.+) AS bucket/.exec(factsAll)![1];

const EVAS = [
  "08000105",
  "8000105",
  "08011160",
  "08098160",
  "08000256",
  "08000000",
  "00000255",
  "12ab",
  "",
  "2147483647",
  "2147483648",
  "99999999999",
];

describe("evaBucket", () => {
  let db: NodeDb;
  beforeAll(async () => {
    db = await createNodeDb();
  });
  afterAll(() => db.close());

  it("finds the bucket expression in facts_all.sql", () => {
    expect(bucketExpr).toBe("COALESCE(TRY_CAST(eva AS INTEGER), 0) % 256");
  });

  it("matches DuckDB's bucket expression", async () => {
    const values = EVAS.map((eva) => `('${eva}')`).join(", ");
    const rows = await db.all(`SELECT eva, ${bucketExpr} AS bucket FROM (VALUES ${values}) t(eva)`, []);
    expect(rows.map((r) => [r.eva, r.bucket])).toEqual(EVAS.map((eva) => [eva, evaBucket(eva)]));
  });
});
