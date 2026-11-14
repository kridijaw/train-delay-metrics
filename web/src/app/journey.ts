import type { Db } from "../db/types";
import { groupByStops, type JourneyGroup } from "../lib/groupByStops";
import { peakCell } from "../lib/format";
import { trainCoverage, trainsByStation } from "../queries/connections";
import { delayOrCancelPercentage, runMany, type DelayResult } from "../queries/delayStats";
import { peakWindows, type PeakWindow } from "../queries/peakWindows";

export interface FindRequest {
  from: string[];
  to: string[];
  monthsBack: number | null;
  exclude: string[];
  today: Date;
}

export interface ResultRow extends DelayResult {
  delayOrCancelPercentage: number | null;
  peak: PeakWindow | undefined;
  peakCell: string;
}

export interface GroupDelays {
  timeSource: "dep" | "arr";
  rows: ResultRow[];
}

// Months back from `today` far enough that the cutoff lands before `minDate`,
// so the "All" window covers every row for the queries that need a cutoff.
export function monthsCovering(today: Date, minDate: string): number {
  const [year, month] = minDate.split("-").map(Number);
  return Math.max(today.getFullYear() * 12 + today.getMonth() - (year * 12 + month - 1) + 1, 1);
}

// The `find-trains --group-by-stops --out` step.
export async function findGroups(db: Db, req: FindRequest): Promise<JourneyGroup[]> {
  const opts = {
    fromEva: req.from,
    toEva: req.to,
    monthsBack: req.monthsBack,
    excludeTypes: req.exclude,
    today: req.today,
  };
  const coverage = await trainCoverage(db, opts);
  if (coverage.length === 0) return [];
  const stationRows = await trainsByStation(db, opts);
  return groupByStops(coverage, stationRows, req.from, req.to);
}

// One group of `train-delay --input`: destination stats at `to`, peak window at the
// `from` departure, rows without any scheduled trip dropped.
export async function groupDelays(
  db: Db,
  group: JourneyGroup,
  opts: { thresholdMinutes: number; monthsBack: number; today: Date },
): Promise<GroupDelays> {
  const common = { trainNames: group.trains, ...opts };
  let runArgs, peakArgs, timeSource: "dep" | "arr";
  if (group.to.length > 0) {
    runArgs = { ...common, destinationEvas: group.to };
    peakArgs = { ...common, destinationEvas: group.to, originEvas: group.from };
    timeSource = group.from.length > 0 ? ("dep" as const) : ("arr" as const);
  } else {
    runArgs = { ...common, stationEvas: group.evas };
    peakArgs = runArgs;
    timeSource = "dep" as const;
  }

  const results = await runMany(db, runArgs);
  const peaks = await peakWindows(db, peakArgs);
  const rows = results
    .filter((r) => r.totalTrips !== 0 || r.canceledTrips !== 0)
    .map((r) => {
      const peak = peaks.get(r.trainName);
      return { ...r, delayOrCancelPercentage: delayOrCancelPercentage(r), peak, peakCell: peakCell(peak) };
    });
  return { timeSource, rows };
}
