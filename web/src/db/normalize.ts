import type { Row } from "./types";

export function normalizeValue(value: unknown): unknown {
  if (typeof value === "bigint") return Number(value);
  if (value === null || typeof value !== "object") return value;
  if (Array.isArray(value)) return value.map(normalizeValue);
  if (ArrayBuffer.isView(value) && !(value instanceof DataView)) {
    return Array.from(value as unknown as ArrayLike<unknown>, normalizeValue);
  }
  // Arrow vectors (DuckDB-WASM list columns) are iterable and expose toArray().
  if (typeof (value as { toArray?: unknown }).toArray === "function" && Symbol.iterator in value) {
    return Array.from(value as Iterable<unknown>, normalizeValue);
  }
  return value;
}

export function normalizeRow(row: Record<string, unknown>): Row {
  const out: Row = {};
  for (const [key, value] of Object.entries(row)) out[key] = normalizeValue(value);
  return out;
}
