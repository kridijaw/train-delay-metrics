#!/usr/bin/env node
// usage: node scripts/check-assets.mjs DIR
// Cloudflare Workers static assets (free plan): files under 25 MiB, fewer than 20,000 files.
import { readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const MAX_FILE_BYTES = 25 * 1024 * 1024;
const MAX_FILES = 20_000;

const dir = process.argv[2];
if (!dir) {
  console.error("usage: node scripts/check-assets.mjs DIR");
  process.exit(2);
}
const root = resolve(dir);

const files = [];
for (const entry of readdirSync(root, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile()) continue;
  const path = join(entry.parentPath, entry.name);
  files.push({ path: relative(root, path), bytes: statSync(path).size });
}

const mib = (bytes) => `${(bytes / 1024 / 1024).toFixed(2)} MiB`;
const total = files.reduce((sum, f) => sum + f.bytes, 0);
const largest = files.reduce((max, f) => (max && max.bytes >= f.bytes ? max : f), null);

console.log(`${files.length} files, ${mib(total)} total in ${root}`);
if (largest) console.log(`largest: ${largest.path} (${mib(largest.bytes)})`);

const tooBig = files.filter((f) => f.bytes >= MAX_FILE_BYTES);
let failed = false;
for (const f of tooBig) {
  console.error(`too large: ${f.path} (${mib(f.bytes)}), limit is under ${mib(MAX_FILE_BYTES)}`);
  failed = true;
}
if (files.length >= MAX_FILES) {
  console.error(`too many files: ${files.length}, limit is under ${MAX_FILES}`);
  failed = true;
}
process.exit(failed ? 1 : 0);
