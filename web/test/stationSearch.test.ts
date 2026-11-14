import { describe, expect, it } from "vitest";
import { fold } from "../src/lib/fold";
import { searchStations, type StationEntry } from "../src/lib/stationSearch";

const stations: StationEntry[] = [
  { eva: "08000207", name: "Köln Hbf", types: { ICE: 120, IC: 40 } },
  { eva: "08003368", name: "Köln Messe/Deutz", types: { ICE: 30 } },
  { eva: "08000105", name: "Frankfurt(Main)Hbf", types: { ICE: 300 } },
  { eva: "08002549", name: "Hamburg Hbf", types: { ICE: 200 } },
  { eva: "08000261", name: "München Hbf", types: { ICE: 250 } },
  { eva: "08010255", name: "Gießen", types: { IC: 12 } },
];

const evas = (q: string) => searchStations(stations, q).map((s) => s.eva);

describe("fold", () => {
  it("lowercases and transliterates umlauts like Slug::TRANSLIT", () => {
    expect(fold("Köln")).toBe("koeln");
    expect(fold("ÄÖÜäöüß")).toBe("aeoeueaeoeuess");
  });

  it("treats decomposed umlauts like precomposed ones", () => {
    expect(fold("Köln")).toBe("koeln");
  });
});

describe("searchStations", () => {
  it("matches Köln Hbf for both koeln and köln", () => {
    expect(evas("koeln")).toContain("08000207");
    expect(evas("köln")).toContain("08000207");
    expect(evas("KÖLN HBF")).toEqual(["08000207"]);
  });

  it("matches substrings anywhere in the name", () => {
    expect(evas("hbf")).toEqual(["08000207", "08000105", "08002549", "08000261"]);
    expect(evas("muenchen")).toEqual(["08000261"]);
    expect(evas("giessen")).toEqual(["08010255"]);
  });

  it("treats % as a wildcard, like ILIKE", () => {
    expect(evas("köln%deutz")).toEqual(["08003368"]);
    expect(evas("frank%hbf")).toEqual(["08000105"]);
    expect(evas("%")).toHaveLength(stations.length);
  });

  it("treats regex characters literally", () => {
    expect(evas("(main)")).toEqual(["08000105"]);
    expect(evas("messe/")).toEqual(["08003368"]);
    expect(evas(".")).toEqual([]);
  });

  it("returns nothing for a blank query", () => {
    expect(evas("")).toEqual([]);
    expect(evas("   ")).toEqual([]);
  });
});
