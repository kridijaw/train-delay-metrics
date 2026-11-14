import type { Db } from "./types";

const quote = (s: string) => `'${s.replaceAll("'", "''")}'`;

export async function createStopEventsView(db: Db, files: string[]): Promise<void> {
  if (files.length === 0) throw new Error("createStopEventsView needs at least one Parquet file");
  await db.exec(`CREATE OR REPLACE VIEW stop_events AS SELECT * FROM read_parquet([${files.map(quote).join(", ")}])`);
}
