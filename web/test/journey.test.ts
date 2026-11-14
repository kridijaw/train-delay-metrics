import { describe, expect, it } from "vitest";
import { findGroups, groupDelays, monthsCovering } from "../src/app/journey";
import { cutoffDate } from "../src/lib/cutoff";
import { withFixture } from "./nodeDb";

describe("monthsCovering", () => {
  it("reaches back past the first data day", () => {
    const today = new Date(2026, 10, 14);
    const n = monthsCovering(today, "2024-07-01");
    expect(n).toBe(29);
    expect(cutoffDate(today, n)! < "2024-07-01").toBe(true);
    expect(monthsCovering(today, "2026-11-01")).toBe(1);
  });
});

describe("findGroups", () => {
  it("returns the find-trains --group-by-stops groups", async () => {
    const { db, cleanup } = await withFixture("connections_coverage");
    try {
      const groups = await findGroups(db, {
        from: ["08000001", "08000002"],
        to: ["08000003", "08000004"],
        monthsBack: null,
        exclude: [],
        today: new Date(),
      });
      expect(groups.map((g) => [g.evas, g.trains])).toEqual([
        [["08000001", "08000002", "08000003"], ["ICE 9"]],
        [["08000001", "08000004"], ["ICE 7"]],
      ]);
    } finally {
      cleanup();
    }
  });
});

describe("groupDelays", () => {
  it("measures at the destination, peaks at the origin departure, and drops trains without trips", async () => {
    const { db, cleanup } = await withFixture("query_events");
    try {
      const group = {
        evas: ["8000800", "8000900", "8000901"],
        from: ["8000800"],
        to: ["8000900", "8000901"],
        stations: {},
        trains: ["ICE 444", "ICE 0000"],
      };
      const { timeSource, rows } = await groupDelays(db, group, { thresholdMinutes: 20, monthsBack: 36, today: new Date() });

      expect(timeSource).toBe("dep");
      expect(rows.map((r) => r.trainName)).toEqual(["ICE 444"]);
      expect(rows[0]).toMatchObject({ totalTrips: 2, canceledTrips: 0, delayedTrips: 2, delayOrCancelPercentage: 100 });
      expect(rows[0].peakCell).toMatch(/^\w{3} 11:00 100%$/);
    } finally {
      cleanup();
    }
  });
});
