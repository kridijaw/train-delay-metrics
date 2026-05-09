require "date"
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
          -- ICE 777: peak-window fixture. 4 always-delayed runs at 09:14
          -- and 4 always-on-time runs at 17:00, all spaced one week apart so
          -- they share the same weekday. Peak window must be 09:14 / 100%
          -- on the weekday matching (CURRENT_DATE - 7 DAY).
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '09:14:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '17:00:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '17:00:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '17:00:00'),
          ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '17:00:00'),
          ('ICE 802', '8000001', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105', 99, NULL,                                                    FALSE, NULL),
          ('ICE 802', '8000105', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', TRUE,  (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
          ('ICE 802', '8000105', 99, (CURRENT_DATE - INTERVAL 4 YEAR ) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 4 YEAR ) + INTERVAL '09:14:00'),
          -- ICE 444: tests destination_evas dedup. Two destination EVAs
          -- (8000900, 8000901). Both fixture days are on the same weekday
          -- (one week apart) so the peak-window weekday assertion is
          -- deterministic. Day 1: arrives 8000900 first at 12:00 (delay 5
          -- min, on time), then 8000901 at 12:30 (delay 25 min, late).
          -- Day 2: only 8000900 (delay 30 min). Per-stop count would be 3
          -- trips / 2 delayed; dedup picks the LATEST arrival per day so
          -- it's 2 trips / 2 delayed.
          ('ICE 444', '8000900',  5, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:00:00'),
          ('ICE 444', '8000901', 25, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:30:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:30:00'),
          ('ICE 444', '8000900', 30, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '12:00:00'),
          -- Matching origin rows for ICE 444 at 8000800 — departing at 11:00
          -- on each of the two destination days. With origin_evas=[8000800]
          -- and destination_evas=[8000900,8000901] the peak window picks up
          -- 11:00 (origin departure) instead of 12:00 (destination arrival).
          ('ICE 444', '8000800',  0, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '10:55:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '11:00:00'),
          ('ICE 444', '8000800',  0, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '10:55:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '11:00:00')
        )
      ) TO '#{parquet}' (FORMAT PARQUET);
    SQL
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "counts trips and delayed trips correctly" do
    result = described_class.new(parquet_glob: glob).run(
      train_name: "ICE 802", station_eva: "8000105",
      threshold_minutes: 20, months_back: 36
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
      threshold_minutes: 20, months_back: 36
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
      threshold_minutes: 20, months_back: 36
    )

    expect(result.total_trips).to eq(0)
    expect(result.canceled_trips).to eq(2)
    expect(result.delayed_trips).to eq(0)
    expect(result.delay_percentage).to be_nil
    # All scheduled trips were canceled → 100% disruption.
    expect(result.delay_or_cancel_percentage).to be_within(0.001).of(100.0)
  end

  it "peak_windows finds the (weekday, ±30 min) bucket with the most disruptions" do
    peaks = described_class.new(parquet_glob: glob).peak_windows(
      train_names: ["ICE 777"], station_eva: "8000105",
      threshold_minutes: 20, months_back: 36
    )

    peak = peaks["ICE 777"]
    expect(peak).not_to be_nil
    expect(peak.center_minute).to eq(9 * 60 + 14)
    expect(peak.center_hhmm).to eq("09:14")
    # All ICE 777 fixture rows are spaced 7 days apart, so they share the
    # weekday of (today - 7 days) — which is just today's weekday.
    expect(peak.weekday).to eq(Date.today.wday)
    expect(peak.weekday_abbr).to eq(Date::ABBR_DAYNAMES[Date.today.wday])
    expect(peak.disrupted).to eq(4)
    expect(peak.scheduled).to eq(4)
    expect(peak.percentage).to be_within(0.001).of(100.0)
  end

  it "peak_windows omits trains with no rows that have departure_planned_time" do
    peaks = described_class.new(parquet_glob: glob).peak_windows(
      train_names: ["ICE 0000"], station_eva: "8000105",
      threshold_minutes: 20, months_back: 36
    )
    expect(peaks).to be_empty
  end

  it "destination_evas dedupes to one row per (train, day) using the latest arrival" do
    per_stop = described_class.new(parquet_glob: glob).run_many(
      train_names: ["ICE 444"], station_evas: ["8000900", "8000901"],
      threshold_minutes: 20, months_back: 36
    ).first
    deduped = described_class.new(parquet_glob: glob).run_many(
      train_names: ["ICE 444"], destination_evas: ["8000900", "8000901"],
      threshold_minutes: 20, months_back: 36
    ).first

    # Per-stop counts every matching row: 3 trips, 2 delayed at >=20 (the
    # 25-min stop at 8000901 on day 1, plus the 30-min stop at 8000900 on
    # day 2). The 5-min stop on day 1 is on time.
    expect(per_stop.total_trips).to eq(3)
    expect(per_stop.delayed_trips).to eq(2)

    # Dedup picks the LATEST arrival per day at any destination EVA. Day 1
    # picks 8000901@12:30 (25 min, delayed). Day 2 has only 8000900 (30 min,
    # delayed). So 2 trips, 2 delayed.
    expect(deduped.total_trips).to eq(2)
    expect(deduped.delayed_trips).to eq(2)
    expect(deduped.delay_percentage).to be_within(0.001).of(100.0)
  end

  it "peak_windows in destination mode uses arrival_planned_time so terminus stops count" do
    peaks = described_class.new(parquet_glob: glob).peak_windows(
      train_names: ["ICE 444"], destination_evas: ["8000900", "8000901"],
      threshold_minutes: 20, months_back: 36
    )
    peak = peaks["ICE 444"]
    expect(peak).not_to be_nil
    # Latest-arrival dedup keeps day 1's 8000901@12:30 row and day 2's
    # 8000900@12:00 row. Both fall in a single ±30 min window on the same
    # weekday, both are disruptions; the 12:00 and 12:30 centers tie on
    # count and rate so the earlier one wins the tiebreaker.
    expect(peak.weekday).to eq(Date.today.wday)
    expect(peak.center_hhmm).to eq("12:00")
    expect(peak.scheduled).to eq(2)
    expect(peak.disrupted).to eq(2)
  end

  it "peak_windows uses origin departure_planned_time when origin_evas is given" do
    peaks = described_class.new(parquet_glob: glob).peak_windows(
      train_names: ["ICE 444"],
      destination_evas: ["8000900", "8000901"],
      origin_evas:      ["8000800"],
      threshold_minutes: 20, months_back: 36
    )
    peak = peaks["ICE 444"]
    expect(peak).not_to be_nil
    # Time-of-day comes from the 8000800 origin row's departure (11:00 on
    # both days), but the disruption flag still comes from the destination
    # dedup (both days are disrupted as before).
    expect(peak.weekday).to eq(Date.today.wday)
    expect(peak.center_hhmm).to eq("11:00")
    expect(peak.scheduled).to eq(2)
    expect(peak.disrupted).to eq(2)
  end

  it "run_many returns multiple trains sorted by delay probability descending" do
    results = described_class.new(parquet_glob: glob).run_many(
      train_names: ["ICE 802", "ICE 999", "ICE 555", "ICE 0000"],
      station_eva: "8000105",
      threshold_minutes: 20, months_back: 36
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
