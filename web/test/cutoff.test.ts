import { describe, expect, it } from "vitest";
import { cutoffDate } from "../src/lib/cutoff";
import { readShared } from "./nodeDb";

interface Case {
  today: string;
  months_back: number | null;
  expected: string | null;
}

const localDate = (iso: string) => {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(y, m - 1, d);
};

describe("cutoffDate (spec/shared/cutoff_cases.json)", () => {
  for (const c of readShared<Case[]>("cutoff_cases.json")) {
    it(`${c.today} minus ${c.months_back} months is ${c.expected}`, () => {
      expect(cutoffDate(localDate(c.today), c.months_back)).toBe(c.expected);
    });
  }

  it("uses the local calendar date, not UTC", () => {
    expect(cutoffDate(new Date(2026, 10, 14, 23, 59), 0)).toBe("2026-11-14");
    expect(cutoffDate(new Date(2026, 10, 15, 0, 1), 0)).toBe("2026-11-15");
  });
});
