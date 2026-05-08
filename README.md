# train-delay-metrics

Answer questions like *"In the last N years, how often did **ICE 821** arrive at **Frankfurt (Main) Hbf** with a delay of at least 20 minutes?"* against the open [piebro/deutsche-bahn-data](https://huggingface.co/datasets/piebro/deutsche-bahn-data) Parquet archive — no Postgres, no ETL, just DuckDB reading Parquet files directly.

## Why this exists

Commercial sources (e.g. Zugfinder Pro) cap historical statistical lookback at ~2 years. This project queries the openly published Deutsche Bahn dataset locally, so any train + station combination can be analysed over the dataset's full history.

> Coverage caveat: the upstream dataset's monthly processed files start at **2024-07** (top ~100 stations) and broaden to all stations from **2025-11**. Asking for "3 years back" today still only returns rows that exist — the query filter is a ceiling, not a guarantee.

## Install

```sh
brew install duckdb     # native lib required by the duckdb gem
bundle install
```

## Get the dataset

```sh
ruby script/fetch_dataset.rb                              # all months from 2024-07 to today
BAHN_FROM=2025-01 BAHN_TO=2025-03 ruby script/fetch_dataset.rb   # range
BAHN_FILES=data-2025-01.parquet ruby script/fetch_dataset.rb     # explicit list
```

Files land in `data/deutsche_bahn/`. Re-runs are idempotent. Months that don't exist yet are reported as `miss` and skipped (not an error).

## Run

### Delay frequency for one train at one station

```sh
bundle exec bin/train-delay --train "ICE 821" --station 08000105 --threshold-minutes 20 --years 3
# Multiple trains, sorted by delay probability (high to low):
bundle exec bin/train-delay --train "ICE 821,ICE 825,ICE 824" --station 08000105 --threshold-minutes 20
```

```
Total trips:                     621
Trips canceled:                  29
Trips delayed >= 20 min:         146
Delay probability:               23.51%
Delay-or-cancel probability:     27.08%
Peak window (±30m):              20:51 (27.48%, 180 of 655)
```

`Total trips` counts only trips that actually ran. `Trips canceled` is reported alongside as a separate failure mode (it is not folded into `Delay probability`). `Delay-or-cancel probability` is `(delayed + canceled) / (total + canceled)` — the share of *scheduled* trips that either ran late or didn't run at all.

`Peak window (±30m)` is the time-of-day (centered on an observed `departure_planned_time` minute) where the train accumulated the most disruptions (delayed ≥ threshold OR canceled), summed over a ±30 minute span. Ranking is by absolute disruption count (not rate), so a single 100%-disrupted run at an off-hour can't win. The reported percentage is `disrupted / scheduled` inside that window. The window does not wrap across midnight.

The multi-train table adds matching `Cancel`, `Prob%+C`, and `Peak D+C` columns (the table cell is the compact `HH:MM NN%` form).

With multiple `--train` values the output switches to a compact table sorted by delay probability descending. Trains with no observed trips in the window are omitted.

`--input FILE` replaces both `--train` and `--station`: it reads a JSON file written by `trains-by-station --out` and runs the delay query once per group. When a group has a `to` array (the default for any JSON written by current `trains-by-station --out`), the query measures delay **at the destination** and de-dupes to one row per `(train, calendar day)`, so a service that stops at multiple destination EVAs (e.g. Köln Hbf + Köln Messe/Deutz) is counted once per run — modelling a passenger journey rather than station throughput. Older JSON files without a `to` array fall back to per-stop counting against the union of EVAs. Bare names are resolved literally first, then against `out/`, then with the `tbs_` prefix and `.json` extension applied — so `--input berlin_to_regensburg` resolves to `out/tbs_berlin_to_regensburg.json`. Umlauts are transliterated on the way in (`ü→ue`, `ö→oe`, `ä→ae`, `ß→ss`), so `--input düsseldorf_to_berlin` resolves to `out/tbs_duesseldorf_to_berlin.json`. Pass `--input all` to iterate every `out/tbs_*.json` file (the auto-derived names from `trains-by-station --out`), printing a header per file.

`--train` also accepts `@FILE` to read newline-separated train names from a file — for example a list produced by `bin/get-trains --out`. Bare filenames are resolved against the current directory first, then against `out/`, so a file written by `get-trains` round-trips without retyping the path:

```sh
bundle exec bin/get-trains --from 08000105 --to 08000207 --out trains.txt   # writes out/trains.txt
bundle exec bin/train-delay --train @trains.txt --station 08000207 --threshold-minutes 20
```

### Look up a station's EVA(s) and train types

```sh
bundle exec bin/find-train-stations frankfurt
bundle exec bin/find-train-stations "berlin sp%"
bundle exec bin/find-train-stations frankfurt --types IC,ICE   # only EVAs with IC/ICE service
bundle exec bin/find-train-stations frankfurt --types IC,ICE --out frankfurt-evas.txt   # save EVAs to out/
bundle exec bin/find-train-stations frankfurt --types IC,ICE --out                       # derives out/station_frankfurt.txt
```

```
Station                  EVA       Trains   Train types
Frankfurt (Main) Hbf     08000105     2870  Bus, EC, ECE, EN, HLB, IC, ICE, NJ, RB, RE, S, …
Frankfurt (Main) Hbf     08098105      210  S
...
```

`Trains` is `COUNT(DISTINCT train_line_ride_id)` — the number of unique scheduled services seen at that EVA in the dataset. With `--types`, the type filter applies to the count too (e.g. `--types IC,ICE` shows the number of distinct IC/ICE services).

`PATTERN` is a SQL ILIKE pattern (`%` wildcards). A bare word is wrapped as `%word%`. The same physical station often has multiple EVAs — typically `08089xxx` / `08098xxx` for S-Bahn platforms and `0801xxxx` / `0800xxxx` for long-distance/regional.

### Connections between two stations

```sh
bundle exec bin/train-connections --from 08000105 --to 08000207
# With explicit window:
bundle exec bin/train-connections --from 08000105 --to 08000207 --years 3
# Multiple EVAs (long-distance + S-Bahn platform groups, both ends):
bundle exec bin/train-connections --from 08000105,08098105 --to 08000207,08098207
```

If `--years` is omitted, the full dataset is used. The first line of output shows the actual window (e.g. `Window: 2024-07-01 -> 2026-04-30 (full dataset)`).

`--exclude-types LIST` drops rides whose `train_type` matches any of the listed values, case-insensitive (e.g. `--exclude-types FLX,DPF` to ignore FlixTrain and charter services).

```
Train       Dep    Arr    Days                         Obs
----------------------------------------------------------
ICE 222     04:31  06:38  Mon Tue Wed Thu Fri          5
NJ          03:13  05:57  Mon Tue Wed Thu Fri Sat Sun  211
ICE 824     07:09  09:43  Wed Sat                      2
...
```

Each row is a unique `(train_name, planned departure, planned arrival)` triple. `Days` lists the weekdays it was observed running; `Obs` counts observed runs in the window. Real-world planned-time edits across months can produce multiple rows for what is logically the same service.

### List trains running between two stations

```sh
bundle exec bin/get-trains --from 08000105 --to 08000207
bundle exec bin/get-trains --from 08000105,08098105 --to 08000207,08098207 --exclude-types FLX
bundle exec bin/get-trains --from 08000105 --to 08000207 --out trains.txt
```

Prints an alphabetically sorted, deduplicated list of `train_name` values that connect the stations — no times, days, or counts. Accepts the same `--from`, `--to`, `--years`, `--exclude-types`, and `--data` options as `train-connections`. With `--out FILE` the list is written one-per-line; bare filenames land under `out/` (which is tracked but its contents are gitignored), paths with a directory component are used as-is. Without `--out`, names go to stdout below the `Window:` summary. Output files are consumable by `train-delay --train @FILE`.

### List trains per station for a from/to journey

```sh
bundle exec bin/trains-by-station --from 08000105,08098105 --to 08000207,08098207
bundle exec bin/trains-by-station --from 08000105,08098105 --to 08000207,08098207 --exclude-types FLX
```

`--from` / `--to` accept either a comma-separated EVA list or `@FILE` to read newline-separated EVAs from a file. Inside `@FILE`, bare names are resolved literally first, then against `out/`, then with the `station_` prefix and `.txt` extension applied — so `--from @berlin` resolves to `out/station_berlin.txt`. Umlauts are transliterated on the way in (`ü→ue`, `ö→oe`, `ä→ae`, `ß→ss`), so `--from @düsseldorf` resolves to `out/station_duesseldorf.txt`. `--to @frankfurt-evas.txt` still consumes a list produced by `find-train-stations --out`.

Either side can also be the literal `all`, which expands to every `out/station_*.txt` file. Combined with the other side it iterates the cartesian product, skipping pairs where from and to are the same file. With `--out` (auto-derived), each pair writes its own JSON file. Useful for batch-generating delay queries across many station combinations.

```sh
bundle exec bin/find-train-stations berlin --types ICE --out
bundle exec bin/find-train-stations regensburg --types ICE --out
bundle exec bin/find-train-stations koeln --types ICE --out
bundle exec bin/trains-by-station --from all --to all --years 1 --group-by-stops --out
# → out/tbs_berlin_to_regensburg.json, out/tbs_berlin_to_koeln.json, ...
```

For each EVA in the union of `--from` / `--to`, prints the alphabetically sorted list of trains that touch that EVA *and* connect any from-EVA to any to-EVA in the window. The `Side` column shows whether the EVA came from `--from`, `--to`, or both. Useful for figuring out which platform-group EVAs (e.g. S-Bahn `08098xxx` vs long-distance `08000xxx`) each train uses. `--exclude-types` drops train types like `FLX` (FlixTrain) before grouping.

`--group-by-stops` flips the layout: instead of one row per EVA, prints one block per *coverage set* — the exact subset of from/to EVAs each train touches. Each train appears in exactly one group (the largest subset that fully matches its observed stops). Useful for separating trains that stop at, say, both Berlin Hbf and Berlin Gesundbrunnen from those that only stop at one.

`--out FILE` additionally serialises the EVAs↔trains mapping to JSON (bare names land under `out/`). Each entry is `{ "evas": [...], "from": [...], "to": [...], "stations": { "<eva>": "<station name>", ... }, "trains": [...] }`. The `from`/`to`/`stations` keys let `train-delay --input` print group titles like `Frankfurt (Main) Hbf (08000105) -> Köln Hbf (08000207)` (from-stations first); older files that lack them still work and fall back to a bare EVA list. Pass `--out` without a value to auto-derive the filename as `tbs_<from-spec>_to_<to-spec>.json` (the `station_` prefix on `@station_*.txt` specs is dropped, so `@station_berlin.txt → @station_regensburg.txt` becomes `tbs_berlin_to_regensburg.json`). `train-delay --input FILE` consumes this format and runs the delay query once per group, measuring delay at any of the group's EVAs:

```sh
bundle exec bin/trains-by-station --from 08011160,08011102 --to 08000105,08000207 --group-by-stops --out berlin.json
bundle exec bin/train-delay --input berlin.json --years 1 --threshold-minutes 20
```

```sh
bundle exec bin/trains-by-station --from 08011160,08011102 --to 08000105,08000207 --years 1 --group-by-stops
```

```
Group: 08000105 (Frankfurt (Main) Hbf, to)  +  08000207 (Köln Hbf, to)  +  08011160 (Berlin Hauptbahnhof, from)
  1 train:
    ICE 1148

Group: 08000105 (Frankfurt (Main) Hbf, to)  +  08011102 (Berlin Gesundbrunnen, from)
  20 trains:
    ICE 593, ICE 595, ...
```

Groups are sorted by coverage size (largest first), then by from-EVA count, then by EVA list.

```
EVA       Side     Station               Trains
---------------------------------------------------------------------------------
08000105  from     Frankfurt (Main) Hbf  IC 2241, IC 2341, …, ICE 928, NJ
08098105  from     Frankfurt (Main) Hbf  S 1, S 8
08000207  to       Köln Hbf              IC 2241, IC 2341, …, ICE 928, NJ
08098207  to       Köln Hbf              S 1, S 8
```

### Argument notes

| flag                  | example         | meaning                                                      |
| --------------------- | --------------- | ------------------------------------------------------------ |
| `--train`             | `"ICE 821"`     | Exact `train_name` as it appears in the dataset (with prefix)|
| `--station`           | `08000105`      | EVA station number, **zero-padded to 8 digits, as a string** |
| `--threshold-minutes` | `20`            | Minimum delay (inclusive) to count                           |
| `--years`             | `3`             | Lookback window from today                                   |
| `--data`              | `path/*.parquet`| Override the Parquet glob                                    |

Find a station's EVA via DuckDB:

```sh
duckdb -c "SELECT DISTINCT station_name, eva FROM read_parquet('data/deutsche_bahn/*.parquet') WHERE station_name ILIKE '%frankfurt%';"
```

## Schema (from `monthly_processed_data/`)

| column                 | type      | notes                                          |
| ---------------------- | --------- | ---------------------------------------------- |
| `train_name`           | string    | e.g. `"ICE 821"`, `"RE 5"`                     |
| `eva`                  | string    | EVA station id, zero-padded (e.g. `08000105`)  |
| `delay_in_min`         | integer   | already in **minutes** (not seconds)           |
| `arrival_planned_time` | timestamp | NULL for stops with no arrival (origin)        |
| `is_canceled`          | boolean   | reported as `Cancel` count; excluded from `Trips` and the delay percentage |

The query filters `arrival_planned_time IS NOT NULL`. Canceled rows are kept and counted separately so a frequently-canceled train doesn't masquerade as a punctual one — `Trips` and `Delay probability` are computed over rows that actually ran (`is_canceled = FALSE`); `Cancel` is the count of `is_canceled = TRUE` rows in the same window.

## Test

```sh
bundle exec rspec
```

The test suite builds a tiny synthetic Parquet via DuckDB and asserts the query returns expected counts — no network, no real dataset required.

## Attribution

Data: [piebro/deutsche-bahn-data](https://huggingface.co/datasets/piebro/deutsche-bahn-data) — CC BY 4.0 (Deutsche Bahn).
