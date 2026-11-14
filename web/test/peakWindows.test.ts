import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { centerHhmm, centerLabel, DAY_ABBR, peakWindows, weekdayAbbr } from "../src/queries/peakWindows";
import { withFixture, type NodeDb } from "./nodeDb";

// JS twins of the peak_windows examples in spec/query_spec.rb, on the same fixture.
// The fixture's rows sit 7, 14, 21 and 28 days before CURRENT_DATE, so their weekday is today's.
describe("peak windows (spec/fixtures/query_events.sql)", () => {
  let db: NodeDb;
  let cleanup: () => void;
  const todayWday = () => new Date().getDay();

  beforeAll(async () => {
    ({ db, cleanup } = await withFixture("query_events"));
  });
  afterAll(() => cleanup());

  it("finds the (weekday, +-30 min) bucket with the most disruptions", async () => {
    const peaks = await peakWindows(db, { trainNames: ["ICE 777"], stationEva: "8000105", thresholdMinutes: 20, monthsBack: 36 });

    const peak = peaks.get("ICE 777");
    expect(peak).toBeDefined();
    expect(peak!.centerMinute).toBe(9 * 60 + 14);
    expect(centerHhmm(peak!)).toBe("09:14");
    expect(peak!.weekday).toBe(todayWday());
    expect(weekdayAbbr(peak!)).toBe(DAY_ABBR[todayWday()]);
    expect(centerLabel(peak!)).toBe(`${DAY_ABBR[todayWday()]} 09:14`);
    expect(peak!.disrupted).toBe(4);
    expect(peak!.scheduled).toBe(4);
    expect(Math.abs(peak!.percentage! - 100.0)).toBeLessThanOrEqual(0.001);
  });

  it("omits trains with no rows that have departure_planned_time", async () => {
    const peaks = await peakWindows(db, { trainNames: ["ICE 0000"], stationEva: "8000105", thresholdMinutes: 20, monthsBack: 36 });
    expect(peaks.size).toBe(0);
  });

  it("in destination mode uses arrival_planned_time so terminus stops count", async () => {
    const peaks = await peakWindows(db, {
      trainNames: ["ICE 444"],
      destinationEvas: ["8000900", "8000901"],
      thresholdMinutes: 20,
      monthsBack: 36,
    });
    const peak = peaks.get("ICE 444");
    expect(peak).toBeDefined();
    expect(peak!.weekday).toBe(todayWday());
    expect(centerHhmm(peak!)).toBe("12:00");
    expect(peak!.scheduled).toBe(2);
    expect(peak!.disrupted).toBe(2);
  });

  it("uses origin departure_planned_time when originEvas is given", async () => {
    const peaks = await peakWindows(db, {
      trainNames: ["ICE 444"],
      destinationEvas: ["8000900", "8000901"],
      originEvas: ["8000800"],
      thresholdMinutes: 20,
      monthsBack: 36,
    });
    const peak = peaks.get("ICE 444");
    expect(peak).toBeDefined();
    expect(peak!.weekday).toBe(todayWday());
    expect(centerHhmm(peak!)).toBe("11:00");
    expect(peak!.scheduled).toBe(2);
    expect(peak!.disrupted).toBe(2);
  });
});
