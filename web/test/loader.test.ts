import { describe, expect, it } from "vitest";
import { coverage, filesForCutoff, filesForQuery, type Dataset, type ManifestFile } from "../src/data/loader";

const file = (quarter: string, min_date: string, max_date: string): ManifestFile => ({
  path: `long-distance/${quarter}.parquet`,
  quarter,
  min_date,
  max_date,
  rows: 1,
  bytes: 1,
});

const files = [
  file("2025Q4", "2025-09-30", "2025-12-31"),
  file("2026Q1", "2025-12-31", "2026-03-31"),
  file("2026Q2", "2026-03-31", "2026-04-30"),
];

describe("filesForCutoff", () => {
  it("keeps files whose max_date reaches the cutoff", () => {
    expect(filesForCutoff(files, "2026-03-31").map((f) => f.quarter)).toEqual(["2026Q1", "2026Q2"]);
    expect(filesForCutoff(files, "2026-04-01").map((f) => f.quarter)).toEqual(["2026Q2"]);
    expect(filesForCutoff(files, "2026-05-14")).toEqual([]);
  });

  it("keeps every file for the All window", () => {
    expect(filesForCutoff(files, null)).toEqual(files);
  });
});

describe("coverage", () => {
  it("spans the earliest min_date to the latest max_date", () => {
    expect(coverage(files)).toEqual({ minDate: "2025-09-30", maxDate: "2026-04-30" });
    expect(coverage([])).toBeNull();
  });
});

describe("filesForQuery", () => {
  const bucketFile = (quarter: string, bucket: number, max_date: string): ManifestFile => ({
    path: `all/${quarter}/bucket=${bucket}/part0.parquet`,
    quarter,
    bucket,
    min_date: "2000-01-01",
    max_date,
    rows: 1,
    bytes: 1,
  });
  const all: Dataset = {
    types: [],
    stations: "all/stations.json",
    bucket_count: 256,
    files: [
      bucketFile("2026Q1", 0, "2026-03-31"),
      bucketFile("2026Q1", 105, "2026-03-31"),
      bucketFile("2026Q1", 207, "2026-03-31"),
      bucketFile("2026Q2", 105, "2026-04-30"),
      bucketFile("2026Q2", 200, "2026-04-30"),
    ],
  };
  const paths = (fs: ManifestFile[]) => fs.map((f) => f.path);

  it("keeps only the buckets of the selected EVAs inside the window", () => {
    expect(paths(filesForQuery(all, "2026-01-01", ["08000105", "08000207"]))).toEqual([
      "all/2026Q1/bucket=105/part0.parquet",
      "all/2026Q1/bucket=207/part0.parquet",
      "all/2026Q2/bucket=105/part0.parquet",
    ]);
    expect(paths(filesForQuery(all, "2026-04-01", ["08000105"]))).toEqual(["all/2026Q2/bucket=105/part0.parquet"]);
    expect(paths(filesForQuery(all, null, ["8000200"]))).toEqual(["all/2026Q2/bucket=200/part0.parquet"]);
    expect(paths(filesForQuery(all, null, ["12ab"]))).toEqual(["all/2026Q1/bucket=0/part0.parquet"]);
  });

  it("ignores EVAs for a dataset without buckets", () => {
    const ld: Dataset = { types: [], stations: "long-distance/stations.json", files };
    expect(filesForQuery(ld, "2026-03-31", ["08000105"])).toEqual(filesForCutoff(files, "2026-03-31"));
  });
});
