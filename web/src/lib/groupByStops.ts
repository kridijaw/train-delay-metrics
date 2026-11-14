import type { StationTrains, TrainCoverage } from "../queries/connections";
import { sortTrainNames } from "./trainName";

// Same shape as one entry of `find-trains --group-by-stops --out` JSON.
export interface JourneyGroup {
  evas: string[];
  from: string[];
  to: string[];
  stations: Record<string, string>;
  trains: string[];
}

function compareEvaLists(a: string[], b: string[]): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length - b.length;
}

// Port of FindTrainsCLI.print_grouped: trains grouped by the exact EVA set they cover,
// largest set first, then more from-EVAs, then more to-EVAs, then the EVA list.
export function groupByStops(
  coverage: readonly TrainCoverage[],
  stationRows: readonly StationTrains[],
  fromEvas: readonly string[],
  toEvas: readonly string[],
): JourneyGroup[] {
  const fromSet = new Set(fromEvas);
  const toSet = new Set(toEvas);
  const evaToName = new Map(stationRows.map((r) => [r.eva, r.stationName]));

  const groups = new Map<string, { evas: string[]; trains: string[] }>();
  for (const c of coverage) {
    const key = JSON.stringify(c.evas);
    let group = groups.get(key);
    if (!group) {
      group = { evas: [...c.evas], trains: [] };
      groups.set(key, group);
    }
    group.trains.push(c.trainName);
  }

  const counts = (evas: string[]) => ({
    size: evas.length,
    from: evas.filter((e) => fromSet.has(e)).length,
    to: evas.filter((e) => toSet.has(e)).length,
  });

  const sorted = [...groups.values()].sort((ga, gb) => {
    const a = counts(ga.evas);
    const b = counts(gb.evas);
    return b.size - a.size || b.from - a.from || b.to - a.to || compareEvaLists(ga.evas, gb.evas);
  });

  return sorted.map(({ evas, trains }) => {
    const stations: Record<string, string> = {};
    for (const e of evas) {
      const name = evaToName.get(e);
      if (name !== null && name !== undefined) stations[e] = name;
    }
    return {
      evas,
      from: evas.filter((e) => fromSet.has(e)),
      to: evas.filter((e) => toSet.has(e)),
      stations,
      trains: sortTrainNames(trains),
    };
  });
}
