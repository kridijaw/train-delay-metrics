# Web app

The web app in `web/` runs the same three-step workflow as the CLIs (find stations, find connecting trains, compute delay statistics) entirely in the visitor's browser. Every query runs in DuckDB-WASM against slim Parquet files that are served as static assets from a Cloudflare Worker with no code, so hosting costs nothing.

## Architecture

### Shared SQL

All queries live in `sql/*.sql` at the repo root. The Ruby CLI (`TrainDelayMetrics::Sql`) and the browser (`web/src/sql/`) load the same files, so `bundle exec rspec` and `npm test` both guard one source of truth.

Each file reads from a fixed relation `stop_events`. Each host creates it as a view over its Parquet files: Ruby over the `--data` glob, the browser over the files it fetched for the current query (`web/src/db/view.ts`).

Files use three markers, expanded left to right so bind order follows text order:

- `{{name}}` becomes `?` and binds `params[name]`. Missing or nil is an error.
- `{{name*}}` becomes `?, ?, ...`, one per element of `params[name]`. Anything but a non-empty array is an error.
- `{{#name}} ... {{/name}}` keeps its body only when `params[name]` is present (not nil, not an empty array). Sections do not nest.

Both implementations are checked against `spec/shared/sql_template_cases.json`. The lookback cutoff is computed by the caller as a local date (`spec/shared/cutoff_cases.json`) and passed in as `CAST({{cutoff}} AS DATE)`, because DuckDB-WASM runs in UTC while the data holds naive Berlin times.

### Data build

`npm run build:data` (`web/scripts/build-data.mjs`) turns the raw monthly archive in `data/deutsche_bahn/` into `web/public/data/`:

- `long-distance/<YYYY>Q<n>.parquet`: one file per calendar quarter, about 5 MB each, written by `web/scripts/sql/facts.sql`. It keeps only the columns the shared SQL reads and the long-distance train types `ICE, IC, EC, ECE, EN, NJ, RJ, RJX, FLX, TGV, EST, WB, ES, D`. `IRE` (regional express) and `DPF` (charter) are left out on purpose. The type list lives only in `facts.sql`.
- `long-distance/stations.json`: `[{ eva, name, types: { TYPE: rides } }]` for the station picker, built over all quarter files on disk.
- `all/<YYYY>Q<n>/bucket=<N>/part0.parquet`: every train type, same columns, written by `web/scripts/sql/facts_all.sql` and split by EVA bucket (see [All-trains dataset](#all-trains-dataset)).
- `all/stations.json`: the same shape, over every station.
- `manifest.json`: rebuilt from the files on disk after every build, for every dataset that has files.

Both `facts*.sql` files derive `train_name` and `is_canceled` from upstream's raw columns and drop rows with no `train_type`, the same mapping `TrainDelayMetrics::Sql.connect` applies for the CLI (see the README's schema reference). Change one, change the other. Upstream reprocesses its whole history when its schema changes, so after such a change re-run `ruby script/fetch_dataset.rb` (it re-downloads months whose size changed) and do a full rebuild.

```json
{
  "built_at": "2026-11-14T22:06:49.531Z",
  "datasets": {
    "long-distance": {
      "types": ["ICE", "IC", "..."],
      "stations": "long-distance/stations.json",
      "files": [
        { "path": "long-distance/2024Q3.parquet", "quarter": "2024Q3",
          "min_date": "2024-07-01", "max_date": "2024-09-30", "rows": 624409, "bytes": 4573721 }
      ]
    },
    "all": {
      "types": ["ICE", "IC", "...", "S", "RB", "RE", "..."],
      "bucket_count": 256,
      "stations": "all/stations.json",
      "files": [
        { "path": "all/2024Q3/bucket=105/part0.parquet", "quarter": "2024Q3", "bucket": 105,
          "min_date": "2024-07-01", "max_date": "2024-09-30", "rows": 174131, "bytes": 1345636 }
      ]
    }
  }
}
```

Flags: `--raw DIR` (default `../data/deutsche_bahn`), `--out DIR` (default `public/data`), `--quarters 2026Q3,2026Q4` (default: every quarter with raw months) and `--dataset long-distance|all|both` (default `both`). `--dataset` picks which quarter files are rebuilt; `stations.json` and the manifest entry are regenerated for every dataset found on disk. A long-distance quarter is written to a `.tmp` file and renamed, an all-trains quarter to a `.tmp` directory that replaces the old one whole, so a failed build never leaves a half-written file and a bucket that disappears leaves no stale file. `min_date` and `max_date` can spill one day past the quarter's edges, because raw monthly files hold a few rows from neighbouring days.

The browser fetches `manifest.json`, picks the files whose `max_date` is on or after the cutoff (for `all`, also only the buckets of the selected EVAs), downloads only the ones it does not have yet, registers them with DuckDB-WASM and rebuilds `stop_events` over the chosen set for every query.

### All-trains dataset

The "Include regional and S-Bahn trains" toggle (`&dataset=all` in the URL) switches to the `all` dataset: every train type, about 940 MB in total, far too much to download per visit. It is split per quarter into 256 buckets by EVA:

```sql
COALESCE(TRY_CAST(eva AS INTEGER), 0) % 256 AS bucket
```

DuckDB writes one `bucket=N/part0.parquet` per bucket that has rows (`PARTITION_BY (bucket)`). The browser computes the same bucket in `web/src/lib/evaBucket.ts` (digit-only EVAs, anything else is bucket 0, as TRY_CAST gives NULL) and fetches only the buckets of the selected from and to EVAs. Every shared query filters on `eva IN (...)`, so those buckets hold every row a query can read; rows of other stations in the same bucket are filtered out by the SQL. `evaBucket.test.ts` checks the JS function against DuckDB's expression taken from `facts_all.sql`. Every EVA in the raw archive today is a 7 or 8 digit number.

The 24-month query from Berlin Hbf and Gesundbrunnen to Köln Hbf and Frankfurt Hbf transfers about 36 MB of Parquet (four buckets over seven quarters), about the same as the whole long-distance dataset (36 MB). Station search switches to `all/stations.json` (5,388 stations, 400 KB), and the footer drops "Long-distance trains only".

Quarters before 2025Q4 hold only the upstream's top ~100 stations, so they have about 110 buckets each; later quarters fill all 256. Bucket files are 0.6 MB at the median and under 3 MB at most.

### DuckDB-WASM

The WASM binary is about 34 MiB, over the 25 MiB per-file asset limit, so it is not part of `dist/`. `web/src/db/wasm.ts` loads it from jsDelivr with `getJsDelivrBundles()`, which builds the URLs from the installed package version. `@duckdb/duckdb-wasm` is pinned exact in `package.json` (currently `1.33.1-dev115.0`, the `next` dist-tag, which is a newer engine build than `latest`), so the CDN binary is pinned too. `selectBundle` picks the bundle the browser supports; the page is not cross-origin isolated, so in practice that is the `base` bundle. Version 1.33.1-dev115.0 passed the browser smoke test, so the fallback to `1.33.1-dev57.0` was not needed.

### Hosting

`web/wrangler.jsonc` describes an assets-only Worker: it has no `main`, so no Worker code runs and every request is a free static asset request. `not_found_handling: "single-page-application"` answers unknown paths with `index.html` and status 200.

## Monthly refresh

`.github/workflows/deploy-web.yml` runs at 04:17 UTC on the 5th of every month and can be started by hand from the Actions tab.

A scheduled run rebuilds only the previous and the current quarter:

1. `scripts/ci-quarters.mjs` computes the first month of the previous quarter (`from`) and the two quarters (`quarters`) from the UTC date.
2. `script/fetch_dataset.rb` downloads the raw months from `from` onward. It exits 1 if any download fails, so a quarter is never rebuilt with a month missing. A month that is not published yet (404) is not an error.
3. `scripts/fetch-deployed-data.mjs "$SITE_URL/data" public/data` downloads the live site's manifest, every file it lists and each `stations.json`. It fails on any non-200 response, on a manifest that is not JSON (the SPA fallback answers missing paths with `index.html` and 200) and on any file whose size differs from the manifest. Without this check a run could deploy two quarters as the whole site.
4. `npm run build:data -- --quarters <prev>,<current>` overwrites those two quarters in both datasets and regenerates each `stations.json` and `manifest.json` over everything on disk.
5. `npm test`, `npm run build` and `npm run check:assets -- dist`, then `npx wrangler deploy`.

A manual run with the `full` input checked skips step 3, downloads the whole archive from 2024-07 and rebuilds every quarter. Use it after changing `facts.sql`, the type list or the manifest format, or when the live site is broken.

## CI and monitoring

- `.github/workflows/test.yml` runs `bundle exec rspec`, `npm test` and `npm run build` on every push and pull request. The Ruby job installs the DuckDB C library from the release tarball pinned in `DUCKDB_VERSION`, because Ubuntu does not package it. Bump that together with `brew upgrade duckdb` locally.
- `.github/dependabot.yml` opens weekly update PRs for npm (`web/`), bundler and GitHub Actions, with minor and patch bumps grouped into one PR per ecosystem. `@duckdb/duckdb-wasm` is ignored: it is pinned to a `next` build, and the test suite runs on `@duckdb/node-api`, so a WASM bump needs the browser smoke test by hand. Major bumps of `@types/node` are ignored too, since its major must match the Node version in `engines` and the workflows; raise it together with the runtime.
- `.github/workflows/uptime.yml` checks `$SITE_URL` every hour: the page loads, `data/manifest.json` parses as JSON with at least one dataset, `built_at` is at most 40 days old (so a monthly deploy that stopped running is caught too), and the first listed Parquet file is served at its manifest size. A failed run sends the usual GitHub Actions failure email.

## Free-tier limits

Cloudflare Workers static assets on the free plan:

- each file must be under 25 MiB;
- a version may hold at most 20,000 files;
- static asset requests are free and unlimited.

`npm run check:assets -- DIR` checks the first two and runs in CI before every deploy. With both datasets, `public/data/` holds 1,323 files, 972 MiB in total, and the largest file is a 5.5 MiB long-distance quarter.

The file count is the limit that grows: the all-trains dataset adds up to 256 files per quarter, about 1,024 files per year, against the 20,000 cap. That leaves room for about 18 more years of data at today's 1,330 files; drop old quarters or lower `bucket_count` in `facts_all.sql` (the build reads it from there) well before then. `wrangler deploy --dry-run` reports "Read 2650 files" for the same `dist/` because its count includes directories (one `bucket=N/` per file); if the limit ever turns out to count those too, the headroom is about half.

## Known limits

- jsDelivr is a runtime dependency: if it is down, the page loads but cannot run queries. This is accepted, because the WASM binary cannot be self-hosted under the 25 MiB cap.
- GitHub disables `schedule` triggers on public repositories after 60 days without repository activity. Re-enable the workflow from the Actions tab when that happens. This applies to the uptime check as well, and merging Dependabot PRs counts as activity.
- The site only covers what the upstream dataset publishes: monthly files start at 2024-07.

## Owner's first deploy

The workflow never makes the first deploy: a scheduled run expects a live site to fetch from. Do it once from your machine with the full raw archive in `data/deutsche_bahn/` (`ruby script/fetch_dataset.rb`):

1. `cd web && npx wrangler login`
2. `npm run build:data && npm run build && npx wrangler deploy`. The site is served only at the Custom Domain `bahn.kridi.dev` (`routes` in `web/wrangler.jsonc`); `workers_dev` is off. The `kridi.dev` zone must be active on the same Cloudflare account, and the hostname must not have a CNAME record. Wrangler creates the DNS record and certificate.
3. In the Cloudflare dashboard, create a custom API token with one permission, Account > Workers Scripts > Edit, limited to that account. That also covers attaching the Custom Domain. Leave IP filtering off, because GitHub-hosted runners have no fixed addresses.
4. In the GitHub repository settings, add the secrets `CLOUDFLARE_API_TOKEN` (the token) and `CLOUDFLARE_ACCOUNT_ID`, and the variable `SITE_URL` (the site's base URL with no trailing slash: `https://bahn.kridi.dev`).

After that, the monthly workflow keeps the site current. Run it once by hand to confirm the secrets work.
