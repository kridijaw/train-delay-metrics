# train-delay-metrics

Answer questions like *"In the last 6 months, how often did **ICE 821** arrive at **Frankfurt (Main) Hbf** with a delay of at least 20 minutes?"* against the open [piebro/deutsche-bahn-data](https://huggingface.co/datasets/piebro/deutsche-bahn-data) Parquet archive — no Postgres, no ETL, just DuckDB reading Parquet files directly.

Commercial sources (e.g. Zugfinder Pro) cap historical statistical lookback at ~2 years. This project queries the openly published Deutsche Bahn dataset locally, so any train + station combination can be analysed over the dataset's full history.

> **Coverage caveat.** The upstream dataset's monthly processed files start at **2024-07** (top ~100 stations) and broaden to all stations from **2025-11**. Asking for "3 years back" today still only returns rows that exist — the lookback flag is a ceiling, not a guarantee.

## Contents

- [Install](#install)
- [Get the dataset](#get-the-dataset)
- [Workflow](#workflow)
- [1. `find-stations` — find EVAs](#1-find-stations--find-evas)
- [2. `find-trains` — map trains to from/to EVAs](#2-find-trains--map-trains-to-fromto-evas)
- [3. `train-delay` — compute delay statistics](#3-train-delay--compute-delay-statistics)
- [Web app](#web-app)
- [Schema reference](#schema-reference)
- [Test](#test)
- [Attribution](#attribution)

## Install

```sh
brew install duckdb     # native lib required by the duckdb gem
bundle install
```

## Get the dataset

```sh
ruby script/fetch_dataset.rb                                        # all months from 2024-07 to today
BAHN_FROM=2025-01 BAHN_TO=2025-03 ruby script/fetch_dataset.rb      # range
BAHN_FILES=data-2025-01.parquet ruby script/fetch_dataset.rb        # explicit list
```

Files land in `data/deutsche_bahn/`. Re-runs are idempotent. Months that don't exist yet are reported as `miss` and skipped (not an error). Any other failed download is reported as `ERROR` and makes the script exit 1 after it has tried every month. An empty `BAHN_FROM` or `BAHN_TO` counts as unset.

## Workflow

The three CLIs are designed to compose. A typical session walks through the pipeline:

1. **`find-stations`** — given a city or pattern, list the EVAs (Deutsche Bahn station ids) that match.
2. **`find-trains`** — given from-EVAs and to-EVAs, list the trains that connect them and write an EVAs↔trains JSON file.
3. **`train-delay`** — read that JSON file (or matching EVAs/trains directly) and compute per-train delay/cancellation statistics.

Files written by each step land under `out/` (gitignored). The next step's flag picks them up by short name (`--from @berlin` resolves to `out/station_berlin.txt`; `--input berlin_to_regensburg` resolves to `out/tbs_berlin_to_regensburg.json`). Umlauts are auto-transliterated during lookup (`ü→ue`, `ö→oe`, `ä→ae`, `ß→ss`).

## 1. `find-stations` — find EVAs

```sh
bundle exec bin/find-stations frankfurt
bundle exec bin/find-stations "berlin sp%"                                     # SQL ILIKE pattern
bundle exec bin/find-stations frankfurt --types IC,ICE                         # only EVAs with IC/ICE service
bundle exec bin/find-stations frankfurt --types IC,ICE --out                   # writes out/station_frankfurt.txt
```

```
Station                                     EVA       Trains   Train types
-------------------------------------------------------------------------------------------------------
Frankfurt (Main) Flughafen Regionalbahnhof  08070004       26  IC, ICE
Frankfurt (Main) Hbf                        08000105     1656  IC, ICE
Frankfurt (Main) Niederrad                  08002050        1  ICE
Frankfurt (Main) Süd                        08002041      385  IC, ICE
...
```

`Trains` is `COUNT(DISTINCT train_line_ride_id)` — the number of unique scheduled services seen at that EVA. With `--types`, the type filter applies to the count too.

`PATTERN` is a SQL ILIKE pattern (`%` wildcards). A bare word is wrapped as `%word%`. The same physical station often has multiple EVAs — typically `08089xxx` / `08098xxx` for S-Bahn platforms and `0801xxxx` / `0800xxxx` for long-distance/regional.

`--out [FILE]` writes the matching EVAs to FILE, one per line. Without a value, derives FILE as `out/station_<slug>.txt`. Bare filenames also land under `out/`.

`--input FILE` replaces the positional `PATTERN` and processes one pattern per line (`#` comments and blank lines ignored). Bare filenames resolve under `out/`. Combine with `--out` (no value) so each pattern's EVA list lands in its own file:

```
# out/cities.txt
berlin
regensburg
köln
```

```sh
bundle exec bin/find-stations --input cities.txt --types ICE --out
# → out/station_berlin.txt, out/station_regensburg.txt, out/station_koeln.txt
```

## 2. `find-trains` — map trains to from/to EVAs

```sh
bundle exec bin/find-trains --from 08000105,08098105 --to 08000207,08098207
bundle exec bin/find-trains --from @berlin --to @regensburg --months 6 --out
```

```
Window: 2025-11-09 -> 2026-05-09 (--months 6)
EVA       Side     Station               Trains
----------------------------------------------------------------------------------------------------
08000105  from     Frankfurt (Main) Hbf  IC 2241, IC 2341, IC 2401, IC 2441, IC 60402, ICE 10, ...
08098105  from     Frankfurt (Main) Hbf  S 1, S 8
08000207  to       Köln Hbf              IC 2241, IC 2341, IC 2401, IC 2441, ICE 10, ICE 12, ...
08098207  to       Köln Hbf              S 1, S 8
```

For each EVA in the union of from/to, prints the alphabetically sorted list of trains that touch that EVA *and* connect at least one from-EVA to at least one to-EVA in the lookback window. The `Side` column shows whether the EVA came from `--from`, `--to`, or both — useful for figuring out which platform-group EVAs each train uses (S-Bahn `08098xxx` vs long-distance `08000xxx`).

### `--from` / `--to` syntax

Each side accepts one of:

- **Comma-separated EVA list** — `08000105,08098105`.
- **`@FILE`** — read newline-separated EVAs from FILE. Bare names resolve literally first, then under `out/`, then with the `station_` prefix and `.txt` extension applied (so `--from @berlin` → `out/station_berlin.txt`). Umlauts are transliterated.
- **`all`** — expands to every `out/station_*.txt` file. Combined with the other side it iterates the cartesian product, skipping pairs where from and to are the same file. With `--out` (auto), each pair writes its own JSON file:

  ```sh
  bundle exec bin/find-stations berlin     --types ICE --out
  bundle exec bin/find-stations regensburg --types ICE --out
  bundle exec bin/find-stations koeln      --types ICE --out
  bundle exec bin/find-trains --from all --to all --years 1 --group-by-stops --out
  # → out/tbs_berlin_to_regensburg.json, out/tbs_berlin_to_koeln.json, ...
  ```

### Lookback window

Set with either `--years N` or `--months N` (mutually exclusive). Without either, the full dataset is used. The first line of output prints the window and the flag form (e.g. `Window: 2025-11-09 -> 2026-05-09 (--months 6)`).

### `--input FILE`

Replaces `--from`/`--to` and reads pairs from FILE, one per line as `<from_spec>, <to_spec>` (or `<from_spec> -> <to_spec>` if a spec itself needs an internal comma, e.g. `08000105,08098105 -> 08000207`). Each spec is anything `--from`/`--to` accepts. Blank lines and `#` comments are ignored:

```
# out/journeys.txt
@berlin, @koeln
@berlin, @regensburg
08000105,08098105 -> 08000207
```

```sh
bundle exec bin/find-trains --input journeys.txt --years 1 --group-by-stops --out
```

### `--group-by-stops`

Flips the layout: instead of one row per EVA, prints one block per *coverage set* — the exact subset of from/to EVAs each train touches. Each train appears in exactly one group (the largest subset that fully matches its observed stops). Useful for separating trains that stop at, say, both Berlin Hbf and Berlin Gesundbrunnen from those that only stop at one.

```
Side  EVA        Station               Trains
----------------------------------------------------------------------------------------------------
from  08011160,  Berlin Hauptbahnhof   ICE 1148
to    08000105,  Frankfurt (Main) Hbf
to    08000207   Köln Hbf

from  08011102,  Berlin Gesundbrunnen  ICE 593, ICE 595, ICE 597, ICE 599, ICE 687, ICE 691, ...
to    08000105   Frankfurt (Main) Hbf
```

Groups are sorted by coverage size (largest first), then by from-EVA count, then by EVA list.

### `--out [FILE]` (JSON)

Serialises the EVAs↔trains mapping to JSON for `train-delay --input`. Bare filenames land under `out/`. Pass `--out` without a value to auto-derive the filename as `tbs_<from-spec>_to_<to-spec>.json` (the `station_` prefix on `@station_*.txt` specs is dropped, so `@station_berlin.txt → @station_regensburg.txt` becomes `tbs_berlin_to_regensburg.json`).

Each entry has the shape:

```json
{
  "evas": ["08011160", "08000105", "08000207"],
  "from": ["08011160"],
  "to":   ["08000105", "08000207"],
  "stations": {
    "08011160": "Berlin Hauptbahnhof",
    "08000105": "Frankfurt (Main) Hbf",
    "08000207": "Köln Hbf"
  },
  "trains": ["ICE 1148"]
}
```

The `from`/`to`/`stations` keys let `train-delay --input` print group titles like `Berlin Hauptbahnhof (08011160) -> Frankfurt (Main) Hbf (08000105)` and measure delay specifically at the destination side.

### `--exclude-types LIST`

Drops train types like `FLX` (FlixTrain) or `DPF` (charter) before grouping, e.g. `--exclude-types FLX,DPF`. Case-insensitive.

## 3. `train-delay` — compute delay statistics

```sh
bundle exec bin/train-delay --train "ICE 821" --station 08000105 --threshold-minutes 20 --years 3
# Multiple trains, sorted by delay probability (high to low):
bundle exec bin/train-delay --train "ICE 821,ICE 825,ICE 824" --station 08000105 --threshold-minutes 20
# Driven by a JSON file written by find-trains --out:
bundle exec bin/train-delay --input berlin_to_regensburg --months 6 --threshold-minutes 20
```

Single-train output:

```
Total trips:                     621
Trips canceled:                  35
Trips delayed >= 20 min:         146
Delay probability:               23.51%
Delay-or-cancel probability:     27.59%
Peak dep window (±30m):          Sun 20:51 (31.91%, 30 of 94)
```

Multi-train output (also used per group in `--input` mode):

```
Train      Trips   Cancel  Delay20+    Prob%  Prob%+C    Dep Peak D+C
--------------------------------------------------------------------
ICE 825       12        2        3    25.00    35.71  Mon 03:26 100%
ICE 821      621       35      146    23.51    27.59  Sun 20:51  32%
ICE 824      201        6       16     7.96    10.63  Wed 07:08  15%
```

### Headline metrics

- **`Total trips`** — trips that actually ran (`is_canceled = FALSE`).
- **`Trips canceled`** — separate failure mode; reported alongside but *not* folded into `Delay probability`.
- **`Trips delayed ≥ N min`** — of trips that ran, how many arrived at least N minutes late.
- **`Delay probability`** = `delayed / total`. The probability that the train, *given it ran*, was at least N minutes late.
- **`Delay-or-cancel probability`** = `(delayed + canceled) / (total + canceled)`. Share of *scheduled* trips that either ran late or didn't run at all — the passenger-relevant disruption rate.

### Peak window

`Peak <kind> window (±30m)` is the `(weekday, time-of-day)` bucket where the train accumulated the most disruptions (delayed ≥ threshold OR canceled), summed over a ±30 minute span centered on an observed minute *on that same weekday*. Ranking is by absolute disruption count (not rate), so a single 100%-disrupted run at an off-hour can't win. The reported percentage is `disrupted / scheduled` inside that bucket. Windows do not wrap across midnight or weekdays.

`<kind>` reflects the time source for the queried row set:

| mode | when it applies | time source |
| --- | --- | --- |
| `dep` per-stop | `--station EVA`, or `--input` against a legacy JSON without a `to` array | `departure_planned_time` at the queried stop |
| `arr` destination arrival | `--input` with a `to` array but no `from` | `arrival_planned_time` at the destination EVA |
| `dep` origin departure | `--input` with both `from` and `to` (default for any JSON written by current `find-trains --out`) | the train's *latest* `departure_planned_time` from any from-EVA on the same calendar day |

In origin-departure mode the trip count and disruption flag still come from the destination side — only the time-of-day on display switches to the passenger's boarding time.

### Destination de-duplication (`--input` with `to`)

When a group has a `to` array, `train-delay` measures delay at the destination and de-dupes to one row per `(train, calendar day)`, keeping the train's *latest* arrival among the destination EVAs that day. So a service that stops at both Köln Messe/Deutz and Köln Hbf on the same run is scored at Köln Hbf (the final stop), modelling a passenger journey rather than station throughput. Older JSON files without a `to` array fall back to per-stop counting against the union of EVAs.

### Argument syntax

| flag | example | meaning |
| --- | --- | --- |
| `--train` | `"ICE 821"`, `"ICE 821,ICE 825"`, or `@FILE` | train name(s); exact `train_name` as in the dataset (with prefix). `@FILE` reads newline-separated names; bare names resolve against the cwd then `out/`. |
| `--station` | `08000105` | EVA, **zero-padded to 8 digits, as a string** |
| `--input` | `berlin_to_regensburg` | JSON file from `find-trains --out`. Resolved literally → `out/<name>` → `out/<name>.json` → `out/tbs_<name>` → `out/tbs_<name>.json` (umlauts transliterated). `--input all` iterates every `out/tbs_*.json`. |
| `--threshold-minutes` | `20` | minimum delay (inclusive) to count |
| `--years` | `3` | lookback window from today, in years (default `3`). Mutually exclusive with `--months`. |
| `--months` | `6` | lookback window from today, in months. Mutually exclusive with `--years`. |
| `--data` | `path/*.parquet` | override the Parquet glob |

## Web app

`web/` holds a browser version of the same workflow: pick stations, see the connecting trains grouped by stops, and get the delay table, with every query running locally in DuckDB-WASM on slim quarterly Parquet files. It is deployed as static files to Cloudflare and refreshed monthly by GitHub Actions.

```sh
cd web && npm ci
npm run build:data -- --raw ../data/deutsche_bahn   # writes public/data/
npm run dev
```

See [docs/web-app.md](docs/web-app.md) for the architecture, the data build, the refresh workflow and the first-deploy runbook.

## Schema reference

Each row in `monthly_processed_data/` is one *stop event* — one (train, calendar day, station) triple. Columns the queries care about:

| column | type | notes |
| --- | --- | --- |
| `train_name` | string | e.g. `"ICE 821"`, `"RE 5"` |
| `eva` | string | EVA station id, zero-padded (e.g. `"08000105"`) |
| `train_type` | string | e.g. `"ICE"`, `"FLX"`, `"S"` |
| `delay_in_min` | integer | already in **minutes** (not seconds) |
| `arrival_planned_time` | timestamp | NULL for stops with no arrival (origin) |
| `departure_planned_time` | timestamp | NULL for stops with no departure (terminus) |
| `is_canceled` | boolean | reported as `Cancel` count; excluded from `Trips` and the delay percentage |
| `train_line_ride_id` | string | identifies a *scheduled service* (reused across days), not a unique daily run |

Queries filter `arrival_planned_time IS NOT NULL` (or `departure_planned_time IS NOT NULL` for origin-side time-of-day). Canceled rows are kept and counted separately so a frequently-canceled train doesn't masquerade as a punctual one — `Trips` and `Delay probability` are computed over rows that actually ran (`is_canceled = FALSE`); `Cancel` is the count of `is_canceled = TRUE` rows in the same window.

## Test

```sh
bundle exec rspec
(cd web && npm test)
```

Both suites run the shared `sql/` files, so a query change is checked from Ruby and from JavaScript.

The test suite builds tiny synthetic Parquet fixtures via DuckDB and asserts the queries return the expected counts — no network, no real dataset required.

## Attribution

Data: [piebro/deutsche-bahn-data](https://huggingface.co/datasets/piebro/deutsche-bahn-data) — CC BY 4.0 (Deutsche Bahn).
