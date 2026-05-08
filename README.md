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
```

```
Total trips:                     29
Trips delayed >= 20 min:         5
Delay probability:               17.24%
```

### Look up a station's EVA(s) and train types

```sh
bundle exec bin/train-stations frankfurt
bundle exec bin/train-stations "berlin sp%"
bundle exec bin/train-stations frankfurt --types IC,ICE   # only EVAs with IC/ICE service
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
bundle exec bin/train-connections --from 08000105 --to 08000207 --years 3
```

```
Train       Dep    Arr    Days                         Obs
----------------------------------------------------------
ICE 222     04:31  06:38  Mon Tue Wed Thu Fri          5
NJ          03:13  05:57  Mon Tue Wed Thu Fri Sat Sun  211
ICE 824     07:09  09:43  Wed Sat                      2
...
```

Each row is a unique `(train_name, planned departure, planned arrival)` triple. `Days` lists the weekdays it was observed running; `Obs` counts observed runs in the window. Real-world planned-time edits across months can produce multiple rows for what is logically the same service.

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
| `is_canceled`          | boolean   | rows where this is `TRUE` are excluded         |

The query filters `arrival_planned_time IS NOT NULL AND is_canceled = FALSE`.

## Test

```sh
bundle exec rspec
```

The test suite builds a tiny synthetic Parquet via DuckDB and asserts the query returns expected counts — no network, no real dataset required.

## Attribution

Data: [piebro/deutsche-bahn-data](https://huggingface.co/datasets/piebro/deutsche-bahn-data) — CC BY 4.0 (Deutsche Bahn).
