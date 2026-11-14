import { describe, expect, it } from "vitest";
import { groupByStops } from "../src/lib/groupByStops";
import { trainCoverage, trainsByStation } from "../src/queries/connections";
import { withFixture } from "./nodeDb";

describe("groupByStops", () => {
  it("matches find-trains --group-by-stops --out on the coverage fixture", async () => {
    const { db, cleanup } = await withFixture("connections_coverage");
    try {
      const opts = { fromEva: ["08000001", "08000002"], toEva: ["08000003", "08000004"] };
      const groups = groupByStops(await trainCoverage(db, opts), await trainsByStation(db, opts), opts.fromEva, opts.toEva);

      expect(groups).toEqual([
        {
          evas: ["08000001", "08000002", "08000003"],
          from: ["08000001", "08000002"],
          to: ["08000003"],
          stations: { "08000001": "A", "08000002": "A", "08000003": "B" },
          trains: ["ICE 9"],
        },
        {
          evas: ["08000001", "08000004"],
          from: ["08000001"],
          to: ["08000004"],
          stations: { "08000001": "A", "08000004": "B" },
          trains: ["ICE 7"],
        },
      ]);
    } finally {
      cleanup();
    }
  });

  it("orders by size, then from count, then to count, then EVA list", () => {
    const from = ["F1", "F2"];
    const to = ["T1", "T2"];
    const coverage = [
      { trainName: "IC 1", evas: ["F1", "T1"] },
      { trainName: "IC 2", evas: ["F1", "T1", "T2"] },
      { trainName: "IC 3", evas: ["F1", "F2", "T1"] },
      { trainName: "IC 4", evas: ["F1", "T2"] },
      { trainName: "IC 5", evas: ["F1", "F2", "T1", "T2"] },
    ];
    const groups = groupByStops(coverage, [], from, to);
    expect(groups.map((g) => g.evas)).toEqual([
      ["F1", "F2", "T1", "T2"],
      ["F1", "F2", "T1"],
      ["F1", "T1", "T2"],
      ["F1", "T1"],
      ["F1", "T2"],
    ]);
    expect(groups.every((g) => Object.keys(g.stations).length === 0)).toBe(true);
  });

  it("collects every train with the same EVA set, sorted by train name, and skips unnamed stations", () => {
    const coverage = [
      { trainName: "ICE 1052", evas: ["F", "T"] },
      { trainName: "ICE 999", evas: ["F", "T"] },
      { trainName: "IC 50", evas: ["F", "T"] },
    ];
    const stations = [
      { eva: "F", stationName: "From Hbf", trains: [] },
      { eva: "T", stationName: null, trains: [] },
    ];
    expect(groupByStops(coverage, stations, ["F"], ["T"])).toEqual([
      { evas: ["F", "T"], from: ["F"], to: ["T"], stations: { F: "From Hbf" }, trains: ["IC 50", "ICE 999", "ICE 1052"] },
    ]);
  });
});
