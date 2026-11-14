import type { Db } from "../db/types";
import { cutoffDate } from "../lib/cutoff";
import { query } from "../sql/query";
import { toList, toNumber, type OneOrMany } from "./params";

// weekday is DuckDB's DOW: 0 = Sunday .. 6 = Saturday.
export const DAY_ABBR = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] as const;

export interface PeakWindow {
  weekday: number;
  centerMinute: number;
  scheduled: number;
  disrupted: number;
  percentage: number | null;
}

const pad2 = (n: number) => String(n).padStart(2, "0");

export const centerHhmm = (p: PeakWindow) => `${pad2(Math.floor(p.centerMinute / 60))}:${pad2(p.centerMinute % 60)}`;
export const weekdayAbbr = (p: PeakWindow) => DAY_ABBR[p.weekday];
export const centerLabel = (p: PeakWindow) => `${weekdayAbbr(p)} ${centerHhmm(p)}`;

export interface PeakWindowsOptions {
  trainNames: OneOrMany;
  stationEva?: string | null;
  stationEvas?: OneOrMany;
  destinationEvas?: OneOrMany;
  originEvas?: OneOrMany;
  thresholdMinutes: number;
  monthsBack: number;
  today?: Date;
}

// Modes as in Query#peak_windows: per_stop (station evas, departure time),
// dest_arr (destinationEvas, arrival time), origin_dep (destinationEvas plus
// originEvas, origin departure time). Trains with no rows are absent.
export async function peakWindows(db: Db, opts: PeakWindowsOptions): Promise<Map<string, PeakWindow>> {
  const names = toList(opts.trainNames);
  if (names.length === 0) throw new Error("trainNames must not be empty");

  const destEvas = toList(opts.destinationEvas);
  const originEvas = toList(opts.originEvas);
  const mode = destEvas.length > 0 ? (originEvas.length > 0 ? "origin_dep" : "dest_arr") : "per_stop";

  let evas = destEvas;
  if (mode === "per_stop") {
    evas = toList(opts.stationEvas);
    if (evas.length === 0 && opts.stationEva) evas = [String(opts.stationEva)];
    if (evas.length === 0) throw new Error("stationEva, stationEvas, or destinationEvas must be provided");
  }

  const rows = await query(db, [`peak_base_${mode}`, "peak_windows"], {
    train_names: names,
    evas,
    origin_evas: originEvas,
    cutoff: cutoffDate(opts.today ?? new Date(), opts.monthsBack),
    threshold: opts.thresholdMinutes,
  });

  const out = new Map<string, PeakWindow>();
  for (const row of rows) {
    const scheduled = toNumber(row.w_scheduled);
    const disrupted = toNumber(row.w_disrupted);
    out.set(String(row.train_name), {
      weekday: toNumber(row.weekday),
      centerMinute: toNumber(row.center_min),
      scheduled,
      disrupted,
      percentage: scheduled === 0 ? null : (100 * disrupted) / scheduled,
    });
  }
  return out;
}
