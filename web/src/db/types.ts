export type Row = Record<string, unknown>;

export interface Db {
  exec(sql: string): Promise<void>;
  all(sql: string, binds: unknown[]): Promise<Row[]>;
}
