#!/usr/bin/env node
// usage: node scripts/build-data.mjs [--raw DIR] [--out DIR] [--quarters 2026Q1,2026Q2] [--dataset long-distance|all|both]
import { existsSync, readFileSync, readdirSync, mkdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { DuckDBInstance } from "@duckdb/node-api";

const SQL_DIR = join(dirname(fileURLToPath(import.meta.url)), "sql");
const LONG_DISTANCE = "long-distance";
const ALL = "all";
const DATASETS = [LONG_DISTANCE, ALL];
const RAW_FILE = /^data-(\d{4})-(\d{2})\.parquet$/;
const QUARTER = /^\d{4}Q[1-4]$/;
const QUARTER_FILE = /^(\d{4}Q[1-4])\.parquet$/;
const BUCKET_DIR = /^bucket=(\d+)$/;
const PART_FILE = /^part\d*\.parquet$/;

const { values: args } = parseArgs({
  options: {
    raw: { type: "string", default: "../data/deutsche_bahn" },
    out: { type: "string", default: "public/data" },
    quarters: { type: "string" },
    dataset: { type: "string", default: "both" },
  },
});

const selected = { both: DATASETS, [LONG_DISTANCE]: [LONG_DISTANCE], [ALL]: [ALL] }[args.dataset];
if (!selected) throw new Error(`bad --dataset ${args.dataset}, expected long-distance, all or both`);

const rawDir = resolve(args.raw);
const outDir = resolve(args.out);
const datasetDir = (name) => join(outDir, name);

const quote = (s) => `'${String(s).replaceAll("'", "''")}'`;
const sourceList = (files) => `[${files.map(quote).join(", ")}]`;
const readSql = (name) => readFileSync(join(SQL_DIR, name), "utf8");
const fill = (sql, tokens) =>
  Object.entries(tokens).reduce((text, [token, value]) => text.replaceAll(token, value), sql);
const mib = (bytes) => (bytes / 1024 / 1024).toFixed(1);

function rawMonthsByQuarter() {
  const byQuarter = new Map();
  for (const name of readdirSync(rawDir).sort()) {
    const m = RAW_FILE.exec(name);
    if (!m) continue;
    const quarter = `${m[1]}Q${Math.ceil(Number(m[2]) / 3)}`;
    if (!byQuarter.has(quarter)) byQuarter.set(quarter, []);
    byQuarter.get(quarter).push(join(rawDir, name));
  }
  return byQuarter;
}

function longDistanceTypes() {
  const m = /train_type IN \(([^)]*)\)/.exec(readSql("facts.sql"));
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}

function bucketCount() {
  return Number(/% (\d+) AS bucket/.exec(readSql("facts_all.sql"))[1]);
}

// [{ rel, quarter, bucket?, path }] for the data files of one dataset on disk.
function dataFiles(name) {
  const dir = datasetDir(name);
  if (!existsSync(dir)) return [];
  const files = [];
  for (const entry of readdirSync(dir).sort()) {
    if (name === LONG_DISTANCE) {
      const m = QUARTER_FILE.exec(entry);
      if (m) files.push({ rel: `${name}/${entry}`, quarter: m[1], path: join(dir, entry) });
      continue;
    }
    if (!QUARTER.test(entry)) continue;
    for (const bucketDir of readdirSync(join(dir, entry))) {
      const m = BUCKET_DIR.exec(bucketDir);
      if (!m) throw new Error(`unexpected entry ${join(dir, entry, bucketDir)}`);
      for (const part of readdirSync(join(dir, entry, bucketDir)).sort()) {
        if (!PART_FILE.test(part)) throw new Error(`unexpected file ${join(dir, entry, bucketDir, part)}`);
        const rel = `${name}/${entry}/${bucketDir}/${part}`;
        files.push({ rel, quarter: entry, bucket: Number(m[1]), path: join(outDir, rel) });
      }
    }
  }
  return files.sort((a, b) => (a.quarter < b.quarter ? -1 : a.quarter > b.quarter ? 1 : (a.bucket ?? 0) - (b.bucket ?? 0) || (a.rel < b.rel ? -1 : 1)));
}

async function buildLongDistance(conn, quarter, months) {
  const target = join(datasetDir(LONG_DISTANCE), `${quarter}.parquet`);
  const tmp = `${target}.tmp`;
  rmSync(tmp, { force: true });
  await conn.run(fill(readSql("facts.sql"), { __SOURCES__: sourceList(months), __OUT__: quote(tmp) }));
  renameSync(tmp, target);
  return `${target} (${mib(statSync(target).size)} MB)`;
}

// Written to a temp directory and swapped in whole, so a bucket that vanished leaves no stale file.
async function buildAll(conn, quarter, months) {
  const target = join(datasetDir(ALL), quarter);
  const tmp = `${target}.tmp`;
  rmSync(tmp, { recursive: true, force: true });
  await conn.run(fill(readSql("facts_all.sql"), { __SOURCES__: sourceList(months), __OUT__: quote(tmp) }));
  rmSync(target, { recursive: true, force: true });
  renameSync(tmp, target);
  const files = dataFiles(ALL).filter((f) => f.quarter === quarter);
  const bytes = files.reduce((n, f) => n + statSync(f.path).size, 0);
  return `${target}/ (${files.length} files, ${mib(bytes)} MB)`;
}

async function writeStations(conn, name, files) {
  const rows = (
    await conn.runAndReadAll(fill(readSql("stations.sql"), { __SOURCES__: sourceList(files.map((f) => f.path)) }))
  ).getRowObjectsJS();
  const stations = [];
  for (const row of rows) {
    let entry = stations.at(-1);
    if (!entry || entry.eva !== row.eva || entry.name !== row.station_name) {
      entry = { eva: row.eva, name: row.station_name, types: {} };
      stations.push(entry);
    }
    entry.types[row.train_type ?? ""] = Number(row.rides);
  }
  writeFileSync(join(datasetDir(name), "stations.json"), JSON.stringify(stations));
  console.log(`${name}/stations.json: ${stations.length} stations`);
  return stations;
}

async function fileStats(conn, files) {
  const rows = (
    await conn.runAndReadAll(
      `SELECT filename,
              CAST(MIN(DATE(COALESCE(departure_planned_time, arrival_planned_time))) AS VARCHAR) AS min_date,
              CAST(MAX(DATE(COALESCE(departure_planned_time, arrival_planned_time))) AS VARCHAR) AS max_date,
              COUNT(*) AS rows
       FROM read_parquet(${sourceList(files.map((f) => f.path))}, filename = true, hive_partitioning = false)
       GROUP BY filename`,
    )
  ).getRowObjectsJS();
  const byPath = new Map(rows.map((r) => [r.filename, r]));
  return files.map((f) => {
    const stats = byPath.get(f.path);
    if (!stats) throw new Error(`${f.path} has no rows`);
    return {
      path: f.rel,
      quarter: f.quarter,
      ...(f.bucket === undefined ? {} : { bucket: f.bucket }),
      min_date: stats.min_date,
      max_date: stats.max_date,
      rows: Number(stats.rows),
      bytes: statSync(f.path).size,
    };
  });
}

// Long-distance types first, in facts.sql order, then the rest by ride count.
function allTypes(stations) {
  const rides = new Map();
  for (const s of stations) {
    for (const [type, n] of Object.entries(s.types)) if (type !== "") rides.set(type, (rides.get(type) ?? 0) + n);
  }
  const first = longDistanceTypes().filter((t) => rides.has(t));
  const rest = [...rides.keys()].filter((t) => !first.includes(t)).sort((a, b) => rides.get(b) - rides.get(a) || (a < b ? -1 : 1));
  return [...first, ...rest];
}

async function main() {
  const byQuarter = rawMonthsByQuarter();
  const wanted = args.quarters ? args.quarters.split(",").map((q) => q.trim()).filter(Boolean) : [...byQuarter.keys()];
  for (const q of wanted) {
    if (!QUARTER.test(q)) throw new Error(`bad quarter ${q}, expected YYYYQn`);
  }

  for (const name of selected) mkdirSync(datasetDir(name), { recursive: true });
  const instance = await DuckDBInstance.create(":memory:");
  const conn = await instance.connect();

  try {
    for (const quarter of wanted) {
      const months = byQuarter.get(quarter);
      if (!months) {
        console.log(`${quarter}: no raw months in ${rawDir}, skipped`);
        continue;
      }
      for (const name of selected) {
        const started = Date.now();
        const wrote = await (name === ALL ? buildAll : buildLongDistance)(conn, quarter, months);
        console.log(`${quarter} ${name}: ${months.length} months -> ${wrote}, ${((Date.now() - started) / 1000).toFixed(1)}s`);
      }
    }

    const datasets = {};
    for (const name of DATASETS) {
      const files = dataFiles(name);
      if (files.length === 0) {
        if (selected.includes(name)) throw new Error(`no data files in ${datasetDir(name)}`);
        continue;
      }
      const stations = await writeStations(conn, name, files);
      const manifestFiles = await fileStats(conn, files);
      datasets[name] =
        name === ALL
          ? { types: allTypes(stations), bucket_count: bucketCount(), stations: `${name}/stations.json`, files: manifestFiles }
          : { types: longDistanceTypes(), stations: `${name}/stations.json`, files: manifestFiles };
      console.log(`${name}: ${manifestFiles.length} files in the manifest`);
    }

    const manifest = { built_at: new Date().toISOString(), datasets };
    writeFileSync(join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
    console.log(`manifest.json: ${Object.keys(datasets).join(", ")}`);
  } finally {
    conn.closeSync();
    instance.closeSync();
  }
}

await main();
