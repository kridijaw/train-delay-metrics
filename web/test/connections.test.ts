import { afterEach, describe, expect, it } from "vitest";
import { dataDateRange, trainCoverage, trainsByStation } from "../src/queries/connections";
import { withFixture } from "./nodeDb";

// JS twins of spec/connections_spec.rb, on the same fixtures.
describe("connections", () => {
  let cleanup: (() => void) | undefined;
  afterEach(() => {
    cleanup?.();
    cleanup = undefined;
  });

  it("trainsByStation lists trains per EVA, alphabetically, with excludeTypes respected", async () => {
    const fixture = await withFixture("connections_by_station");
    cleanup = fixture.cleanup;

    const rows = await trainsByStation(fixture.db, {
      fromEva: ["08000105", "08098105"],
      toEva: ["08000207", "08098207"],
      excludeTypes: ["FLX"],
    });

    const byEva = new Map(rows.map((r) => [r.eva, r]));
    expect([...byEva.keys()].sort()).toEqual(["08000105", "08000207", "08098105", "08098207"]);
    expect(byEva.get("08000105")!.stationName).toBe("Frankfurt Hbf");
    expect(byEva.get("08000105")!.trains).toEqual(["ICE 9"]);
    expect(byEva.get("08098105")!.trains).toEqual(["S 8"]);
    expect(byEva.get("08000207")!.trains).toEqual(["ICE 9"]);
    expect(byEva.get("08098207")!.trains).toEqual(["S 8"]);
  });

  it("trainCoverage returns the set of from/to EVAs each train touches", async () => {
    const fixture = await withFixture("connections_coverage");
    cleanup = fixture.cleanup;

    const rows = await trainCoverage(fixture.db, {
      fromEva: ["08000001", "08000002"],
      toEva: ["08000003", "08000004"],
    });

    const byTrain = new Map(rows.map((r) => [r.trainName, r.evas]));
    expect([...byTrain.get("ICE 9")!].sort()).toEqual(["08000001", "08000002", "08000003"]);
    expect([...byTrain.get("ICE 7")!].sort()).toEqual(["08000001", "08000004"]);
  });

  it("excludeTypes is trimmed and case-insensitive, and an empty list keeps every type", async () => {
    const fixture = await withFixture("connections_by_station");
    cleanup = fixture.cleanup;
    const opts = { fromEva: "08000105", toEva: "08000207" };

    const all = await trainsByStation(fixture.db, opts);
    expect(all.find((r) => r.eva === "08000105")!.trains).toEqual(["FLX 1", "ICE 9"]);

    const filtered = await trainsByStation(fixture.db, { ...opts, excludeTypes: [" flx ", ""] });
    expect(filtered.find((r) => r.eva === "08000105")!.trains).toEqual(["ICE 9"]);
  });

  it("drops the window when monthsBack is null and applies it otherwise", async () => {
    const fixture = await withFixture("connections_by_station");
    cleanup = fixture.cleanup;
    const opts = { fromEva: "08000105", toEva: "08000207" };

    expect(await trainsByStation(fixture.db, { ...opts, monthsBack: null })).toHaveLength(2);
    expect(await trainsByStation(fixture.db, { ...opts, monthsBack: 1, today: new Date(2025, 1, 2) })).toHaveLength(2);
    expect(await trainsByStation(fixture.db, { ...opts, monthsBack: 1, today: new Date(2026, 0, 1) })).toEqual([]);
  });

  it("rejects empty from/to like the Ruby preamble", async () => {
    const fixture = await withFixture("connections_coverage");
    cleanup = fixture.cleanup;
    await expect(trainCoverage(fixture.db, { fromEva: [], toEva: "08000003" })).rejects.toThrow(/fromEva/);
    await expect(trainCoverage(fixture.db, { fromEva: "08000001", toEva: [""] })).rejects.toThrow(/toEva/);
  });

  it("dataDateRange returns the planned-date span as YYYY-MM-DD strings", async () => {
    const fixture = await withFixture("connections_coverage");
    cleanup = fixture.cleanup;
    expect(await dataDateRange(fixture.db)).toEqual(["2025-03-01", "2025-03-02"]);
  });
});
