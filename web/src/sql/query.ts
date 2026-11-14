import type { Db, Row } from "../db/types";
import { load } from "./files";
import { expand, type Params } from "./template";

export function query(db: Db, names: string[], params: Params): Promise<Row[]> {
  const { sql, binds } = expand(load(...names), params);
  return db.all(sql, binds);
}
