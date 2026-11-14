import { describe, expect, it } from "vitest";
import { formatFixed, formatPercent, groupTitle, peakCell } from "../src/lib/format";

describe("formatFixed", () => {
  it("rounds exact binary ties to even like Ruby format('%.2f')", () => {
    expect(formatFixed(40.625, 2)).toBe("40.62");
    expect(formatFixed(0.125, 2)).toBe("0.12");
    expect(formatFixed(0.375, 2)).toBe("0.38");
    expect(formatFixed(2.5, 0)).toBe("2");
    expect(formatFixed(3.5, 0)).toBe("4");
  });

  it("rounds non-ties by the exact binary value", () => {
    expect(formatFixed(40.635, 2)).toBe("40.63");
    expect(formatFixed(1.005, 2)).toBe("1.00");
    expect(formatFixed(66.66666666666667, 2)).toBe("66.67");
    expect(formatFixed(100, 2)).toBe("100.00");
    expect(formatFixed(0, 2)).toBe("0.00");
  });

  it("carries through nines and keeps the sign", () => {
    expect(formatFixed(9.999, 2)).toBe("10.00");
    expect(formatFixed(99.995, 2)).toBe("100.00");
    expect(formatFixed(-1.234, 2)).toBe("-1.23");
    expect(formatFixed(-0.001, 2)).toBe("0.00");
  });

  it("prints a dash for a missing percentage", () => {
    expect(formatPercent(null)).toBe("-");
    expect(formatPercent(12.5)).toBe("12.50");
  });
});

describe("peakCell", () => {
  it("matches CLI.format_peak_cell", () => {
    expect(peakCell({ weekday: 0, centerMinute: 20 * 60 + 51, scheduled: 94, disrupted: 30, percentage: (100 * 30) / 94 })).toBe(
      "Sun 20:51  32%",
    );
    expect(peakCell({ weekday: 6, centerMinute: 21 * 60 + 31, scheduled: 2, disrupted: 2, percentage: 100 })).toBe("Sat 21:31 100%");
    expect(peakCell({ weekday: 1, centerMinute: 5, scheduled: 0, disrupted: 0, percentage: null })).toBe("-");
    expect(peakCell(undefined)).toBe("-");
  });
});

describe("groupTitle", () => {
  it("matches CLI.format_group_title", () => {
    const group = {
      evas: ["A", "B", "C"],
      from: ["A", "B"],
      to: ["C"],
      stations: { A: "Berlin Hbf", C: "Köln Hbf" },
      trains: ["ICE 1"],
    };
    expect(groupTitle(group)).toBe("Berlin Hbf (A), B -> Köln Hbf (C)");
    expect(groupTitle({ ...group, from: [], to: [] })).toBe("EVAs Berlin Hbf (A), B, Köln Hbf (C)");
    expect(groupTitle({ ...group, to: ["A"] })).toBe("Berlin Hbf (A), B");
  });
});
