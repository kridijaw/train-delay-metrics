require "duckdb"
require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::Connections do
  let(:tmpdir)  { Dir.mktmpdir("train-conn-spec") }
  let(:parquet) { File.join(tmpdir, "fixture.parquet") }
  let(:glob)    { File.join(tmpdir, "*.parquet") }

  before do
    conn = DuckDB::Database.new.connect
    # Two scheduled services from EVA 08000105 (station_num=1) to 08000207
    # (station_num=3), running on different days, plus exclusions:
    #   - same ride_id at an intermediate station_num=2 (must not be matched as B)
    #   - opposite-direction stop pair (station_num decreases) — must be ignored
    #   - a stop pair across days within same ride_id — must be ignored (>16h)
    conn.execute(<<~SQL)
      COPY (
        SELECT * FROM (VALUES
          -- ICE 100 daily: dep 08:00 from 105, intermediate 09:00, arr 10:00 at 207
          ('ICE 100','08000105',1,TIMESTAMP '2025-01-06 08:00', NULL,                   'r1', FALSE),
          ('ICE 100','08000999',2,TIMESTAMP '2025-01-06 09:00', TIMESTAMP '2025-01-06 09:00','r1', FALSE),
          ('ICE 100','08000207',3,NULL,                          TIMESTAMP '2025-01-06 10:00','r1', FALSE),
          ('ICE 100','08000105',1,TIMESTAMP '2025-01-07 08:00', NULL,                   'r1', FALSE),
          ('ICE 100','08000207',3,NULL,                          TIMESTAMP '2025-01-07 10:00','r1', FALSE),
          -- IC 200 Sat only
          ('IC 200', '08000105',1,TIMESTAMP '2025-01-04 12:00', NULL,                   'r2', FALSE),
          ('IC 200', '08000207',3,NULL,                          TIMESTAMP '2025-01-04 14:00','r2', FALSE),
          -- Reverse direction (excluded: station_num decreases)
          ('ICE 100','08000207',3,TIMESTAMP '2025-01-08 18:00', NULL,                   'r1', FALSE),
          ('ICE 100','08000105',1,NULL,                          TIMESTAMP '2025-01-08 20:00','r1', FALSE),
          -- S-Bahn pairs at sibling EVAs (08098105 -> 08098207)
          ('S 1',   '08098105',1,TIMESTAMP '2025-01-09 09:00', NULL,                   'r3', FALSE),
          ('S 1',   '08098207',3,NULL,                          TIMESTAMP '2025-01-09 09:30','r3', FALSE)
        ) AS t(train_name, eva, train_line_station_num, departure_planned_time, arrival_planned_time, train_line_ride_id, is_canceled)
      ) TO '#{parquet}' (FORMAT PARQUET);
    SQL
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "lists scheduled connections with day patterns" do
    rows = described_class.new(parquet_glob: glob).run(
      from_eva: "08000105", to_eva: "08000207", years_back: 3
    )

    by_train = rows.group_by(&:train_name)
    expect(by_train.keys).to contain_exactly("ICE 100", "IC 200")

    ice = by_train["ICE 100"].first
    expect(ice.departure).to eq("08:00")
    expect(ice.arrival).to   eq("10:00")
    expect(ice.days).to      contain_exactly("Mon", "Tue") # Jan 6 = Mon, Jan 7 = Tue
    expect(ice.observations).to eq(2)

    ic = by_train["IC 200"].first
    expect(ic.days).to eq(["Sat"])
  end

  it "filters out excluded train_types case-insensitively" do
    # Add a parquet that includes a train_type column so the filter matters.
    typed = File.join(tmpdir, "typed.parquet")
    DuckDB::Database.new.connect.execute(<<~SQL)
      COPY (
        SELECT * FROM (VALUES
          ('FLX 1', 'FLX', '08000105', 1, TIMESTAMP '2025-01-09 11:00', NULL,                          'rf', FALSE),
          ('FLX 1', 'FLX', '08000207', 3, NULL,                          TIMESTAMP '2025-01-09 12:00', 'rf', FALSE),
          ('ICE 9', 'ICE', '08000105', 1, TIMESTAMP '2025-01-09 13:00', NULL,                          'ri', FALSE),
          ('ICE 9', 'ICE', '08000207', 3, NULL,                          TIMESTAMP '2025-01-09 14:00', 'ri', FALSE)
        ) AS t(train_name, train_type, eva, train_line_station_num, departure_planned_time, arrival_planned_time, train_line_ride_id, is_canceled)
      ) TO '#{typed}' (FORMAT PARQUET);
    SQL

    rows = described_class.new(parquet_glob: typed).run(
      from_eva: "08000105", to_eva: "08000207", years_back: 3,
      exclude_types: %w[flx]
    )
    expect(rows.map(&:train_name)).to eq(["ICE 9"])
  end

  it "returns empty when no connection exists" do
    rows = described_class.new(parquet_glob: glob).run(
      from_eva: "08000105", to_eva: "08000888", years_back: 3
    )
    expect(rows).to be_empty
  end

  it "accepts arrays of EVAs for from and to" do
    rows = described_class.new(parquet_glob: glob).run(
      from_eva: %w[08000105 08098105],
      to_eva:   %w[08000207 08098207],
      years_back: 3
    )

    train_names = rows.map(&:train_name)
    expect(train_names).to contain_exactly("ICE 100", "IC 200", "S 1")
  end

  it "unique_train_names returns a sorted, deduped list of train names" do
    names = described_class.new(parquet_glob: glob).unique_train_names(
      from_eva: %w[08000105 08098105],
      to_eva:   %w[08000207 08098207]
    )
    expect(names).to eq(["IC 200", "ICE 100", "S 1"])
  end

  it "unique_train_names respects exclude_types" do
    typed = File.join(tmpdir, "typed.parquet")
    DuckDB::Database.new.connect.execute(<<~SQL)
      COPY (
        SELECT * FROM (VALUES
          ('FLX 1', 'FLX', '08000105', 1, TIMESTAMP '2025-01-09 11:00', NULL,                          'rf', FALSE),
          ('FLX 1', 'FLX', '08000207', 3, NULL,                          TIMESTAMP '2025-01-09 12:00', 'rf', FALSE),
          ('ICE 9', 'ICE', '08000105', 1, TIMESTAMP '2025-01-09 13:00', NULL,                          'ri', FALSE),
          ('ICE 9', 'ICE', '08000207', 3, NULL,                          TIMESTAMP '2025-01-09 14:00', 'ri', FALSE)
        ) AS t(train_name, train_type, eva, train_line_station_num, departure_planned_time, arrival_planned_time, train_line_ride_id, is_canceled)
      ) TO '#{typed}' (FORMAT PARQUET);
    SQL

    names = described_class.new(parquet_glob: typed).unique_train_names(
      from_eva: "08000105", to_eva: "08000207", exclude_types: %w[flx]
    )
    expect(names).to eq(["ICE 9"])
  end

  it "trains_by_station lists trains per EVA, alphabetically, with --exclude-types respected" do
    typed = File.join(tmpdir, "by_station.parquet")
    DuckDB::Database.new.connect.execute(<<~SQL)
      COPY (
        SELECT * FROM (VALUES
          -- Long-distance ICE 9 from 105 -> 207, also stops at 207 sibling 098207
          ('ICE 9', 'ICE', 'Frankfurt Hbf', '08000105', 1, TIMESTAMP '2025-02-01 08:00', NULL,                          'ri', FALSE),
          ('ICE 9', 'ICE', 'Köln Hbf',      '08000207', 3, NULL,                          TIMESTAMP '2025-02-01 10:00', 'ri', FALSE),
          -- S 8 from S-Bahn EVAs
          ('S 8',   'S',   'Frankfurt Hbf', '08098105', 1, TIMESTAMP '2025-02-01 08:00', NULL,                          'rs', FALSE),
          ('S 8',   'S',   'Köln Hbf',      '08098207', 3, NULL,                          TIMESTAMP '2025-02-01 09:30', 'rs', FALSE),
          -- FLX excluded by --exclude-types
          ('FLX 1', 'FLX', 'Frankfurt Hbf', '08000105', 1, TIMESTAMP '2025-02-02 11:00', NULL,                          'rf', FALSE),
          ('FLX 1', 'FLX', 'Köln Hbf',      '08000207', 3, NULL,                          TIMESTAMP '2025-02-02 12:00', 'rf', FALSE)
        ) AS t(train_name, train_type, station_name, eva, train_line_station_num, departure_planned_time, arrival_planned_time, train_line_ride_id, is_canceled)
      ) TO '#{typed}' (FORMAT PARQUET);
    SQL

    rows = described_class.new(parquet_glob: typed).trains_by_station(
      from_eva: %w[08000105 08098105], to_eva: %w[08000207 08098207],
      exclude_types: %w[FLX]
    )

    by_eva = rows.each_with_object({}) { |r, h| h[r.eva] = r }
    expect(by_eva.keys).to contain_exactly("08000105", "08098105", "08000207", "08098207")
    expect(by_eva["08000105"].station_name).to eq("Frankfurt Hbf")
    expect(by_eva["08000105"].trains).to eq(["ICE 9"])
    expect(by_eva["08098105"].trains).to eq(["S 8"])
    expect(by_eva["08000207"].trains).to eq(["ICE 9"])
    expect(by_eva["08098207"].trains).to eq(["S 8"])
  end
end
