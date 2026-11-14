import { describe, expect, it } from "vitest";
import { DEFAULT_STATE, parseUrlState, serializeUrlState } from "../src/app/urlState";

describe("urlState", () => {
  it("parses the documented query string", () => {
    expect(parseUrlState("?from=08011160,08011102&to=08000207,08000105&months=24&threshold=20&exclude=flx,EC")).toEqual({
      from: ["08011160", "08011102"],
      to: ["08000207", "08000105"],
      months: 24,
      threshold: 20,
      exclude: ["FLX", "EC"],
      dataset: "long-distance",
    });
  });

  it("reads dataset=all and ignores other dataset values", () => {
    expect(parseUrlState("?dataset=all").dataset).toBe("all");
    expect(parseUrlState("?dataset=ALL").dataset).toBe("all");
    expect(parseUrlState("?dataset=regional").dataset).toBe("long-distance");
  });

  it("falls back to defaults for missing or invalid values", () => {
    expect(parseUrlState("")).toEqual(DEFAULT_STATE);
    expect(parseUrlState("?months=7&threshold=-3").months).toBe(12);
    expect(parseUrlState("?months=7&threshold=-3").threshold).toBe(20);
    expect(parseUrlState("?threshold=2.5").threshold).toBe(20);
    expect(parseUrlState("?months=ALL").months).toBe("all");
    expect(parseUrlState("?from=,a,,a,b").from).toEqual(["a", "b"]);
  });

  it("round-trips with literal commas and months=all", () => {
    const state = {
      ...DEFAULT_STATE,
      from: ["08011160", "08011102"],
      to: ["08000207"],
      months: "all" as const,
      threshold: 15,
      exclude: ["FLX"],
    };
    const search = serializeUrlState(state);
    expect(search).toBe("?from=08011160,08011102&to=08000207&months=all&threshold=15&exclude=FLX");
    expect(parseUrlState(search)).toEqual(state);

    const all = { ...state, dataset: "all" as const };
    expect(serializeUrlState(all)).toBe("?from=08011160,08011102&to=08000207&months=all&threshold=15&exclude=FLX&dataset=all");
    expect(parseUrlState(serializeUrlState(all))).toEqual(all);
    expect(serializeUrlState(DEFAULT_STATE)).toBe("?months=12&threshold=20");
  });
});
