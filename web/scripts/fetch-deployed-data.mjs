#!/usr/bin/env node
// usage: node scripts/fetch-deployed-data.mjs BASE_URL OUT_DIR
// Downloads the deployed manifest.json, every file it lists and each dataset's stations.json.
// Any non-200, unparsable JSON or size mismatch exits 1: with single-page-application handling a
// missing path answers 200 with index.html, so a tolerant fetch would let CI deploy a partial site.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

const CONCURRENCY = 8;

const [baseArg, outArg] = process.argv.slice(2);
if (!baseArg || !outArg) {
  console.error("usage: node scripts/fetch-deployed-data.mjs BASE_URL OUT_DIR");
  process.exit(2);
}
const base = baseArg.replace(/\/+$/, "");
const outDir = resolve(outArg);

function safePath(path) {
  if (typeof path !== "string" || path === "" || isAbsolute(path) || path.split("/").includes("..")) {
    throw new Error(`manifest lists an unsafe path: ${JSON.stringify(path)}`);
  }
  return path;
}

async function get(path) {
  const url = `${base}/${path}`;
  const res = await fetch(url);
  if (res.status !== 200) throw new Error(`GET ${url}: HTTP ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

function parseJson(path, bytes) {
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new Error(`${base}/${path} is not JSON (an SPA fallback page?)`);
  }
}

function save(path, bytes) {
  const target = join(outDir, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, bytes);
}

async function main() {
  const manifestBytes = await get("manifest.json");
  const manifest = parseJson("manifest.json", manifestBytes);
  if (!manifest || typeof manifest.datasets !== "object" || manifest.datasets === null) {
    throw new Error(`${base}/manifest.json has no datasets`);
  }

  const files = [];
  const stations = [];
  for (const [name, ds] of Object.entries(manifest.datasets)) {
    if (!Array.isArray(ds.files)) throw new Error(`dataset ${name} has no files list`);
    stations.push(safePath(ds.stations));
    for (const f of ds.files) {
      if (!Number.isInteger(f.bytes)) throw new Error(`${f.path}: manifest has no bytes`);
      files.push({ path: safePath(f.path), bytes: f.bytes });
    }
  }

  for (const path of stations) {
    const bytes = await get(path);
    parseJson(path, bytes);
    save(path, bytes);
  }

  let next = 0;
  let total = 0;
  const worker = async () => {
    while (next < files.length) {
      const f = files[next++];
      const bytes = await get(f.path);
      if (bytes.byteLength !== f.bytes) {
        throw new Error(`${base}/${f.path}: got ${bytes.byteLength} bytes, manifest says ${f.bytes}`);
      }
      save(f.path, bytes);
      total += bytes.byteLength;
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));

  save("manifest.json", manifestBytes);
  const mb = (total / 1024 / 1024).toFixed(2);
  console.log(`fetched manifest.json, ${stations.length} stations files and ${files.length} data files (${mb} MiB) into ${outDir}`);
}

try {
  await main();
} catch (err) {
  console.error(`fetch-deployed-data: ${err.message}`);
  process.exit(1);
}
