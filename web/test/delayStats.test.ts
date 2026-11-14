import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { delayOrCancelPercentage, run, runMany } from "../src/queries/delayStats";
import { withFixture, type NodeDb } from "./nodeDb";

// JS twins of the run / run_many examples in spec/query_spec.rb, on the same fixture.
const expectWithin = (actual: number | null, expected: number, delta = 0.001) => {
  expect(actual).not.toBeNull();
  expect(Math.abs((actual as number) - expected)).toBeLessThanOrEqual(delta);
};

describe("delay stats (spec/fixtures/query_events.sql)", () => {
  let db: NodeDb;
  let cleanup: () => void;

  beforeAll(async () => {
    ({ db, cleanup } = await withFixture("query_events"));
  });
  afterAll(() => cleanup());

  it("counts trips and delayed trips correctly", async () => {
    const result = await run(db, { trainName: "ICE 802", stationEva: "8000105", thresholdMinutes: 20, monthsBack: 36 });

    expect(result.totalTrips).toBe(5);
    expect(result.delayedTrips).toBe(3);
    expect(result.canceledTrips).toBe(1);
    expectWithin(result.delayPercentage, 60.0);
    expectWithin(delayOrCancelPercentage(result), 66.667);
  });

  it("returns zero counts and null percentage when no rows match", async () => {
    const result = await run(db, { trainName: "ICE 0000", stationEva: "8000105", thresholdMinutes: 20, monthsBack: 36 });

    expect(result.totalTrips).toBe(0);
    expect(result.canceledTrips).toBe(0);
    expect(result.delayedTrips).toBe(0);
    expect(result.delayPercentage).toBeNull();
    expect(delayOrCancelPercentage(result)).toBeNull();
  });

  it("reports canceled-only trains with totalTrips=0 and a non-zero canceledTrips", async () => {
    const result = await run(db, { trainName: "ICE 333", stationEva: "8000105", thresholdMinutes: 20, monthsBack: 36 });

    expect(result.totalTrips).toBe(0);
    expect(result.canceledTrips).toBe(2);
    expect(result.delayedTrips).toBe(0);
    expect(result.delayPercentage).toBeNull();
    expectWithin(delayOrCancelPercentage(result), 100.0);
  });

  it("destinationEvas dedupes to one row per (train, day) using the latest arrival", async () => {
    const [perStop] = await runMany(db, {
      trainNames: ["ICE 444"],
      stationEvas: ["8000900", "8000901"],
      thresholdMinutes: 20,
      monthsBack: 36,
    });
    const [deduped] = await runMany(db, {
      trainNames: ["ICE 444"],
      destinationEvas: ["8000900", "8000901"],
      thresholdMinutes: 20,
      monthsBack: 36,
    });

    expect(perStop.totalTrips).toBe(3);
    expect(perStop.delayedTrips).toBe(2);

    expect(deduped.totalTrips).toBe(2);
    expect(deduped.delayedTrips).toBe(2);
    expectWithin(deduped.delayPercentage, 100.0);
  });

  it("runMany returns multiple trains sorted by delay probability descending", async () => {
    const results = await runMany(db, {
      trainNames: ["ICE 802", "ICE 999", "ICE 555", "ICE 0000"],
      stationEva: "8000105",
      thresholdMinutes: 20,
      monthsBack: 36,
    });

    expect(results.map((r) => r.trainName)).toEqual(["ICE 999", "ICE 802", "ICE 555", "ICE 0000"]);
    expectWithin(results[0].delayPercentage, 100.0);
    expectWithin(results[1].delayPercentage, 60.0);
    expectWithin(results[2].delayPercentage, 0.0);
    expect(results[3].delayPercentage).toBeNull();
    expect(results[3].totalTrips).toBe(0);
  });

  it("rejects empty train names and missing stations like the Ruby preamble", async () => {
    await expect(runMany(db, { trainNames: [], stationEva: "8000105", thresholdMinutes: 20, monthsBack: 36 })).rejects.toThrow(
      /trainNames/,
    );
    await expect(runMany(db, { trainNames: ["ICE 802"], thresholdMinutes: 20, monthsBack: 36 })).rejects.toThrow(/stationEva/);
  });
});
