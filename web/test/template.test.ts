import { describe, expect, it } from "vitest";
import { load, names } from "../src/sql/files";
import { expand, TemplateError, type Params } from "../src/sql/template";
import { readShared } from "./nodeDb";

type Case =
  | { name: string; text: string; params: Params; sql: string; binds: unknown[] }
  | { name: string; text: string; params: Params; error: true };

describe("expand (spec/shared/sql_template_cases.json)", () => {
  for (const c of readShared<Case[]>("sql_template_cases.json")) {
    if ("error" in c) {
      it(`raises for ${c.name}`, () => {
        expect(() => expand(c.text, c.params)).toThrow(TemplateError);
      });
    } else {
      it(`expands ${c.name}`, () => {
        expect(expand(c.text, c.params)).toEqual({ sql: c.sql, binds: c.binds });
      });
    }
  }
});

describe("load", () => {
  const allParams: Params = {
    train_names: ["ICE 1"],
    evas: ["1"],
    origin_evas: ["2"],
    cutoff: "2025-01-01",
    threshold: 20,
    all_evas: ["1", "2"],
    from_evas: ["1"],
    to_evas: ["2"],
    exclude_types: ["FLX"],
    name_pattern: "%x%",
    train_types: ["ICE"],
  };

  it("finds all 13 shared SQL files", () => {
    expect(names()).toHaveLength(13);
    expect(names()).toContain("delay_stats");
  });

  it("expands every shared SQL file with all params present", () => {
    for (const name of names()) {
      expect(expand(load(name), allParams).sql).not.toContain("{{");
    }
  });

  it("joins files with a newline", () => {
    expect(load("delay_base_per_stop", "delay_stats")).toBe(`${load("delay_base_per_stop")}\n${load("delay_stats")}`);
  });

  it("rejects unknown names", () => {
    expect(() => load("nope")).toThrow(/sql\/nope\.sql/);
  });
});
