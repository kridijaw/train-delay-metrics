#!/usr/bin/env node
// usage: node scripts/ci-quarters.mjs [--today YYYY-MM-DD]
// Appends from=YYYY-MM and quarters=YYYYQn,YYYYQn (previous and current quarter) to $GITHUB_OUTPUT,
// or prints them when it is unset.
import { appendFileSync } from "node:fs";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({ options: { today: { type: "string" } } });

let year;
let month;
if (args.today) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(args.today);
  if (!m || Number(m[2]) < 1 || Number(m[2]) > 12) {
    console.error(`bad --today ${args.today}, expected YYYY-MM-DD`);
    process.exit(2);
  }
  year = Number(m[1]);
  month = Number(m[2]);
} else {
  const now = new Date();
  year = now.getUTCFullYear();
  month = now.getUTCMonth() + 1;
}

const quarter = Math.ceil(month / 3);
const prevYear = quarter === 1 ? year - 1 : year;
const prevQuarter = quarter === 1 ? 4 : quarter - 1;
const fromMonth = (prevQuarter - 1) * 3 + 1;

const lines = [
  `from=${prevYear}-${String(fromMonth).padStart(2, "0")}`,
  `quarters=${prevYear}Q${prevQuarter},${year}Q${quarter}`,
].join("\n") + "\n";

if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, lines);
else process.stdout.write(lines);
