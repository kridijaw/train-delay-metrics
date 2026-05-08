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
          col4 AS is_canceled,
          col5 AS departure_planned_time
        FROM (VALUES
          -- All ICE 802 runs at this EVA depart at 09:14, on different days.
          ('ICE 802', '8000105', 25, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105', 30, (CURRENT_DATE - INTERVAL  60 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  60 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105', 20, (CURRENT_DATE - INTERVAL 200 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 200 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105',  5, (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105',  0, (CURRENT_DATE - INTERVAL  30 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  30 DAY) + INTERVAL '09:14:00'),
          -- ICE 999: one delayed trip (always delayed) → 100% delay rate
          ('ICE 999', '8000105', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00'),
          -- ICE 555: one trip, never delayed → 0%
          ('ICE 555', '8000105',  2, (CURRENT_DATE - INTERVAL   5 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL   5 DAY) + INTERVAL '12:00:00'),
          -- ICE 333: only ever canceled → total_trips=0, canceled_trips=2
          ('ICE 333', '8000105',  0, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00', TRUE,  (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00'),
          ('ICE 333', '8000105',  0, (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '12:00:00', TRUE,  (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '12:00:00'),
          -- ICE 777: peak-window fixture. 4 always-delayed runs at 09:14,
          -- 4 always-on-time runs at 17:00. Peak window must be 09:14 / 100%.
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL   1 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL   1 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL   2 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL   2 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL   3 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL   3 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL   4 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL   4 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL   1 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL   1 DAY) + INTERVAL '17:00:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL   2 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL   2 DAY) + INTERVAL '17:00:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL   3 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL   3 DAY) + INTERVAL '17:00:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL   4 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL   4 DAY) + INTERVAL '17:00:00'),
          ('ICE 802', '8000001', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105', 99, NULL,                                                    FALSE, NULL),
          ('ICE 802', '8000105', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', TRUE,  (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105', 99, (CURRENT_DATE - INTERVAL 4 YEAR ) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 4 YEAR ) + INTERVAL '09:14:00')
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
    expect(result.canceled_trips).to eq(1)
    expect(result.delay_percentage).to be_within(0.001).of(60.0)
    # (delayed + canceled) / (total + canceled) = (3 + 1) / (5 + 1)
    expect(result.delay_or_cancel_percentage).to be_within(0.001).of(66.667)
  end

  it "returns zero counts and nil percentage when no rows match" do
    result = described_class.new(parquet_glob: glob).run(
      train_name: "ICE 0000", station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )

    expect(result.total_trips).to eq(0)
    expect(result.canceled_trips).to eq(0)
    expect(result.delayed_trips).to eq(0)
    expect(result.delay_percentage).to be_nil
    expect(result.delay_or_cancel_percentage).to be_nil
  end

  it "reports canceled-only trains with total_trips=0 and a non-nil canceled_trips" do
    result = described_class.new(parquet_glob: glob).run(
      train_name: "ICE 333", station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )

    expect(result.total_trips).to eq(0)
    expect(result.canceled_trips).to eq(2)
    expect(result.delayed_trips).to eq(0)
    expect(result.delay_percentage).to be_nil
    # All scheduled trips were canceled → 100% disruption.
    expect(result.delay_or_cancel_percentage).to be_within(0.001).of(100.0)
  end

  it "peak_windows finds the ±30 min departure-time window with the most disruptions" do
    peaks = described_class.new(parquet_glob: glob).peak_windows(
      train_names: ["ICE 777"], station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )

    peak = peaks["ICE 777"]
    expect(peak).not_to be_nil
    expect(peak.center_minute).to eq(9 * 60 + 14)
    expect(peak.center_hhmm).to eq("09:14")
    expect(peak.disrupted).to eq(4)
    expect(peak.scheduled).to eq(4)
    expect(peak.percentage).to be_within(0.001).of(100.0)
  end

  it "peak_windows omits trains with no rows that have departure_planned_time" do
    peaks = described_class.new(parquet_glob: glob).peak_windows(
      train_names: ["ICE 0000"], station_eva: "8000105",
      threshold_minutes: 20, years_back: 3
    )
    expect(peaks).to be_empty
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
