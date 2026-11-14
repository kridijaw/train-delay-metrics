import type { Db } from "../db/types";
import { cutoffDate } from "../lib/cutoff";
import { compareTrainNames } from "../lib/trainName";
import { query } from "../sql/query";
import { toList, toNumber, type OneOrMany } from "./params";

export interface DelayResult {
  trainName: string;
  totalTrips: number;
  canceledTrips: number;
  delayedTrips: number;
  delayPercentage: number | null;
}

export interface RunManyOptions {
  trainNames: OneOrMany;
  stationEva?: string | null;
  stationEvas?: OneOrMany;
  destinationEvas?: OneOrMany;
  thresholdMinutes: number;
  monthsBack: number;
  today?: Date;
}

const emptyResult = (trainName: string): DelayResult => ({
  trainName,
  totalTrips: 0,
  canceledTrips: 0,
  delayedTrips: 0,
  delayPercentage: null,
});

// Share of scheduled trips (ran or canceled) that ran late or were canceled.
export function delayOrCancelPercentage(r: DelayResult): number | null {
  const scheduled = r.totalTrips + r.canceledTrips;
  if (scheduled === 0) return null;
  return (100 * (r.delayedTrips + r.canceledTrips)) / scheduled;
}

// Per-stop mode with stationEva(s); destination-deduplicated mode (latest arrival
// per train and day) with destinationEvas. Sorted by delayPercentage desc, null last.
export async function runMany(db: Db, opts: RunManyOptions): Promise<DelayResult[]> {
  const names = toList(opts.trainNames);
  if (names.length === 0) throw new Error("trainNames must not be empty");

  const destEvas = toList(opts.destinationEvas);
  let evas: string[];
  if (destEvas.length > 0) {
    evas = destEvas;
  } else {
    evas = toList(opts.stationEvas);
    if (evas.length === 0 && opts.stationEva) evas = [String(opts.stationEva)];
  }
  if (evas.length === 0) throw new Error("stationEva, stationEvas, or destinationEvas must be provided");

  const base = destEvas.length > 0 ? "delay_base_destination" : "delay_base_per_stop";
  const rows = await query(db, [base, "delay_stats"], {
    train_names: names,
    evas,
    cutoff: cutoffDate(opts.today ?? new Date(), opts.monthsBack),
    threshold: opts.thresholdMinutes,
  });

  const seen = new Map<string, DelayResult>();
  for (const row of rows) {
    const trainName = String(row.train_name);
    seen.set(trainName, {
      trainName,
      totalTrips: toNumber(row.total_trips),
      canceledTrips: toNumber(row.canceled_trips),
      delayedTrips: toNumber(row.delayed_trips),
      delayPercentage: row.delay_percentage === null || row.delay_percentage === undefined ? null : Number(row.delay_percentage),
    });
  }
  for (const name of names) if (!seen.has(name)) seen.set(name, emptyResult(name));

  const rank = (r: DelayResult) => (r.delayPercentage === null ? Infinity : -r.delayPercentage);
  return [...seen.values()].sort((a, b) => {
    const ra = rank(a);
    const rb = rank(b);
    return ra < rb ? -1 : ra > rb ? 1 : compareTrainNames(a.trainName, b.trainName);
  });
}

export async function run(
  db: Db,
  opts: { trainName: string; stationEva: string; thresholdMinutes: number; monthsBack: number; today?: Date },
): Promise<DelayResult> {
  const results = await runMany(db, {
    trainNames: [opts.trainName],
    stationEvas: [opts.stationEva],
    thresholdMinutes: opts.thresholdMinutes,
    monthsBack: opts.monthsBack,
    today: opts.today,
  });
  return results[0] ?? emptyResult(String(opts.trainName));
}
