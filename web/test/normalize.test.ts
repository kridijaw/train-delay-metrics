import { describe, expect, it } from "vitest";
import { normalizeRow, normalizeValue } from "../src/db/normalize";

// Stand-in for an Arrow Vector as DuckDB-WASM returns for LIST columns.
class FakeVector<T> {
  constructor(private readonly items: T[]) {}
  toArray() {
    return this.items;
  }
  *[Symbol.iterator]() {
    yield* this.items;
  }
}

describe("normalize", () => {
  it("converts BigInt to Number", () => {
    expect(normalizeValue(42n)).toBe(42);
  });

  it("converts nested lists, typed arrays and Arrow-like vectors to plain arrays", () => {
    expect(normalizeValue([1n, 2n])).toEqual([1, 2]);
    expect(normalizeValue(new BigInt64Array([3n, 4n]))).toEqual([3, 4]);
    expect(normalizeValue(new FakeVector(["a", "b"]))).toEqual(["a", "b"]);
    expect(normalizeValue(new FakeVector([new FakeVector([5n])]))).toEqual([[5]]);
  });

  it("leaves strings, numbers, booleans, null and dates alone", () => {
    const date = new Date(0);
    expect(normalizeRow({ s: "x", n: 1.5, b: false, z: null, d: date })).toEqual({ s: "x", n: 1.5, b: false, z: null, d: date });
  });
});
