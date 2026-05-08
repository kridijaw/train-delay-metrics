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
end
