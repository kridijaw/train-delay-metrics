import * as duckdb from "@duckdb/duckdb-wasm";
import { normalizeRow } from "./normalize";
import type { Db, Row } from "./types";

export interface WasmDb extends Db {
  registerFileBuffer(name: string, buffer: Uint8Array): Promise<void>;
}

// duckdb-base.wasm is over the 25 MiB static asset limit, so the engine comes from
// jsDelivr at the installed package version.
export async function createWasmDb(): Promise<WasmDb> {
  const bundle = await duckdb.selectBundle(duckdb.getJsDelivrBundles());
  if (!bundle.mainWorker) throw new Error("DuckDB-WASM bundle has no worker script");

  // A cross-origin worker script cannot be started directly, only imported from a same-origin one.
  const workerUrl = URL.createObjectURL(
    new Blob([`importScripts(${JSON.stringify(bundle.mainWorker)});`], { type: "text/javascript" }),
  );
  const worker = new Worker(workerUrl);
  const db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), worker);
  try {
    await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  } finally {
    URL.revokeObjectURL(workerUrl);
  }
  const conn = await db.connect();

  return {
    async exec(sql: string) {
      await conn.query(sql);
    },
    async all(sql: string, binds: unknown[]): Promise<Row[]> {
      const stmt = await conn.prepare(sql);
      try {
        const table = await stmt.query(...binds);
        return table.toArray().map((row) => normalizeRow(row.toJSON() as Record<string, unknown>));
      } finally {
        await stmt.close();
      }
    },
    registerFileBuffer: (name, buffer) => db.registerFileBuffer(name, buffer),
  };
}
