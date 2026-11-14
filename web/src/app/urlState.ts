import type { DatasetName } from "../data/loader";

export const WINDOW_OPTIONS = [3, 6, 12, 24, "all"] as const;
export type WindowMonths = (typeof WINDOW_OPTIONS)[number];

export interface UrlState {
  from: string[];
  to: string[];
  months: WindowMonths;
  threshold: number;
  exclude: string[];
  dataset: DatasetName;
}

export const DEFAULT_STATE: UrlState = { from: [], to: [], months: 12, threshold: 20, exclude: [], dataset: "long-distance" };

const list = (value: string | null, transform: (s: string) => string = (s) => s) =>
  [...new Set((value ?? "").split(",").map((s) => transform(s.trim())).filter((s) => s !== ""))];

export function parseMonths(value: string | null): WindowMonths {
  if (value === null) return DEFAULT_STATE.months;
  if (value.toLowerCase() === "all") return "all";
  const n = Number(value);
  return (WINDOW_OPTIONS as readonly unknown[]).includes(n) ? (n as WindowMonths) : DEFAULT_STATE.months;
}

export function parseThreshold(value: string | null): number {
  if (value === null || value.trim() === "") return DEFAULT_STATE.threshold;
  const n = Number(value);
  return Number.isInteger(n) && n >= 0 ? n : DEFAULT_STATE.threshold;
}

export function parseUrlState(search: string): UrlState {
  const params = new URLSearchParams(search);
  return {
    from: list(params.get("from")),
    to: list(params.get("to")),
    months: parseMonths(params.get("months")),
    threshold: parseThreshold(params.get("threshold")),
    exclude: list(params.get("exclude"), (s) => s.toUpperCase()),
    dataset: params.get("dataset")?.trim().toLowerCase() === "all" ? "all" : "long-distance",
  };
}

// Commas stay literal so the URL reads ?from=08011160,08011102 as documented.
export function serializeUrlState(state: UrlState): string {
  const parts: string[] = [];
  const add = (key: string, value: string) => parts.push(`${key}=${encodeURIComponent(value).replaceAll("%2C", ",")}`);
  if (state.from.length > 0) add("from", state.from.join(","));
  if (state.to.length > 0) add("to", state.to.join(","));
  add("months", String(state.months));
  add("threshold", String(state.threshold));
  if (state.exclude.length > 0) add("exclude", state.exclude.join(","));
  if (state.dataset === "all") add("dataset", "all");
  return `?${parts.join("&")}`;
}
