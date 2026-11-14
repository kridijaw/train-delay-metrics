import type { Db } from "../db/types";
import { cutoffDate } from "../lib/cutoff";
import { sortTrainNames } from "../lib/trainName";
import { query } from "../sql/query";
import { toList, type OneOrMany } from "./params";

export interface StationTrains {
  eva: string;
  stationName: string | null;
  trains: string[];
}

export interface TrainCoverage {
  trainName: string;
  evas: string[];
}

export interface ConnectionOptions {
  fromEva: OneOrMany;
  toEva: OneOrMany;
  monthsBack?: number | null;
  excludeTypes?: OneOrMany;
  today?: Date;
}

function connectionParams(opts: ConnectionOptions) {
  const fromEvas = toList(opts.fromEva);
  const toEvas = toList(opts.toEva);
  const excluded = toList(opts.excludeTypes)
    .map((t) => t.trim())
    .filter((t) => t !== "")
    .map((t) => t.toUpperCase());
  if (fromEvas.length === 0) throw new Error("fromEva must not be empty");
  if (toEvas.length === 0) throw new Error("toEva must not be empty");

  return {
    all_evas: [...fromEvas, ...toEvas],
    cutoff: cutoffDate(opts.today ?? new Date(), opts.monthsBack ?? null),
    exclude_types: excluded,
    from_evas: fromEvas,
    to_evas: toEvas,
  };
}

const stringList = (value: unknown): string[] => (Array.isArray(value) ? value.map(String) : []);

// Per EVA in from + to, the trains touching it that connect any from-EVA to any to-EVA.
export async function trainsByStation(db: Db, opts: ConnectionOptions): Promise<StationTrains[]> {
  const rows = await query(db, ["connections_stops", "connections_matching_rides", "connections_by_station"], connectionParams(opts));
  return rows.map((row) => ({
    eva: String(row.eva),
    stationName: row.station_name === null || row.station_name === undefined ? null : String(row.station_name),
    trains: sortTrainNames(stringList(row.trains)),
  }));
}

// Per connecting train, the sorted from/to EVAs it stops at in the window.
export async function trainCoverage(db: Db, opts: ConnectionOptions): Promise<TrainCoverage[]> {
  const rows = await query(db, ["connections_stops", "connections_matching_rides", "connections_coverage"], connectionParams(opts));
  return rows.map((row) => ({ trainName: String(row.train_name), evas: stringList(row.evas) }));
}

export async function dataDateRange(db: Db): Promise<[string | null, string | null]> {
  const [row] = await query(db, ["data_date_range"], {});
  const asDate = (v: unknown) => (v === null || v === undefined ? null : String(v));
  return [asDate(row?.min_d), asDate(row?.max_d)];
}
