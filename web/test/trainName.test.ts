import { describe, expect, it } from "vitest";
import { compareTrainNames, sortKey, sortTrainNames } from "../src/lib/trainName";
import { readShared } from "./nodeDb";

interface Case {
  name: string;
  input: string[];
  expected: string[];
}

describe("train name sort (spec/shared/train_name_sort_cases.json)", () => {
  for (const c of readShared<Case[]>("train_name_sort_cases.json")) {
    it(`sorts shared case: ${c.name}`, () => {
      expect(sortTrainNames(c.input)).toEqual(c.expected);
    });
  }

  it("splits names into text and digit runs", () => {
    expect(sortKey("ICE 1052")).toEqual([
      [0, "ice "],
      [1, 4, "1052"],
    ]);
  });

  it("puts ICE 999 before ICE 1052", () => {
    expect(compareTrainNames("ICE 999", "ICE 1052")).toBeLessThan(0);
  });
});
