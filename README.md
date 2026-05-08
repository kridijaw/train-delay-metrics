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

```sh
bundle exec bin/train-delay --train "ICE 821" --station 08000105 --threshold-minutes 20 --years 3
```

Output:

```
Total trips:                     29
Trips delayed >= 20 min:         5
Delay probability:               17.24%
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
| `is_canceled`          | boolean   | rows where this is `TRUE` are excluded         |

The query filters `arrival_planned_time IS NOT NULL AND is_canceled = FALSE`.

## Test

```sh
bundle exec rspec
```

The test suite builds a tiny synthetic Parquet via DuckDB and asserts the query returns expected counts — no network, no real dataset required.

## Attribution

Data: [piebro/deutsche-bahn-data](https://huggingface.co/datasets/piebro/deutsche-bahn-data) — CC BY 4.0 (Deutsche Bahn).
