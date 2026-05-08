require "duckdb"
require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::Query do
  let(:tmpdir)  { Dir.mktmpdir("train-delay-spec") }
  let(:parquet) { File.join(tmpdir, "fixture.parquet") }
  let(:glob)    { File.join(tmpdir, "*.parquet") }

  before do
    conn = DuckDB::Database.new.connect
    # Recent arrivals of "ICE 802" at EVA 8000105:
    #   3 with delay_in_min >= 20, 2 below.
    # Plus rows that should be excluded:
    #   - different train, different eva, no arrival time, canceled, too old.
    conn.execute(<<~SQL)
      COPY (
        SELECT
          col0 AS train_name,
          col1 AS eva,
          col2 AS delay_in_min,
          col3 AS arrival_planned_time,
          col4 AS is_canceled
        FROM (VALUES
          ('ICE 802', '8000105', 25, CURRENT_TIMESTAMP - INTERVAL  10 DAY, FALSE),
          ('ICE 802', '8000105', 30, CURRENT_TIMESTAMP - INTERVAL  60 DAY, FALSE),
          ('ICE 802', '8000105', 20, CURRENT_TIMESTAMP - INTERVAL 200 DAY, FALSE),
          ('ICE 802', '8000105',  5, CURRENT_TIMESTAMP - INTERVAL  20 DAY, FALSE),
          ('ICE 802', '8000105',  0, CURRENT_TIMESTAMP - INTERVAL  30 DAY, FALSE),
          -- ICE 999: one delayed trip (always delayed) → 100% delay rate
          ('ICE 999', '8000105', 99, CURRENT_TIMESTAMP - INTERVAL  10 DAY, FALSE),
          -- ICE 555: one trip, never delayed → 0%
          ('ICE 555', '8000105',  2, CURRENT_TIMESTAMP - INTERVAL   5 DAY, FALSE),
          ('ICE 802', '8000001', 99, CURRENT_TIMESTAMP - INTERVAL  10 DAY, FALSE),
          ('ICE 802', '8000105', 99, NULL,                                FALSE),
          ('ICE 802', '8000105', 99, CURRENT_TIMESTAMP - INTERVAL  10 DAY, TRUE),
          ('ICE 802', '8000105', 99, CURRENT_TIMESTAMP - INTERVAL 4 YEAR,  FALSE)
        )
      ) TO '#{parquet}' (FORMAT PARQUET);
    SQL
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "counts trips and delayed trips correctly" do
    result = described_class.new(parquet_glob: glob).run(
      train_name: "ICE 802", station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )

    expect(result.total_trips).to eq(5)
    expect(result.delayed_trips).to eq(3)
    expect(result.delay_percentage).to be_within(0.001).of(60.0)
  end

  it "returns zero counts and nil percentage when no rows match" do
    result = described_class.new(parquet_glob: glob).run(
      train_name: "ICE 0000", station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )

    expect(result.total_trips).to eq(0)
    expect(result.delayed_trips).to eq(0)
    expect(result.delay_percentage).to be_nil
  end

  it "run_many returns multiple trains sorted by delay probability descending" do
    results = described_class.new(parquet_glob: glob).run_many(
      train_names: ["ICE 802", "ICE 999", "ICE 555", "ICE 0000"],
      station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )

    expect(results.map(&:train_name)).to eq(["ICE 999", "ICE 802", "ICE 555", "ICE 0000"])
    # ICE 999 100%, ICE 802 60%, ICE 555 0%, ICE 0000 nil (last)
    expect(results[0].delay_percentage).to be_within(0.001).of(100.0)
    expect(results[1].delay_percentage).to be_within(0.001).of(60.0)
    expect(results[2].delay_percentage).to be_within(0.001).of(0.0)
    expect(results[3].delay_percentage).to be_nil
    expect(results[3].total_trips).to eq(0)
  end
end
