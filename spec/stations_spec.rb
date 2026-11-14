require "duckdb"
require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::Stations do
  let(:tmpdir)  { Dir.mktmpdir("train-stations-spec") }
  let(:parquet) { File.join(tmpdir, "fixture.parquet") }
  let(:glob)    { File.join(tmpdir, "*.parquet") }

  before { write_fixture("stations", parquet) }

  after { FileUtils.remove_entry(tmpdir) }

  it "groups by station+eva and aggregates train types" do
    rows = described_class.new(parquet_glob: glob).run(name_pattern: "%berlin%")

    expect(rows.size).to eq(2)
    long_distance = rows.find { |r| r.eva == "08011160" }
    s_bahn        = rows.find { |r| r.eva == "08089001" }

    expect(long_distance.station_name).to eq("Berlin Hbf")
    expect(long_distance.train_types).to contain_exactly("IC", "ICE")
    expect(long_distance.trains).to eq(2) # ride_a + ride_b, polling dedup

    expect(s_bahn.train_types).to eq(["S"])
    expect(s_bahn.trains).to eq(1)        # ride_c counted once despite 2 rows
  end

  it "filters to only the requested train types" do
    rows = described_class.new(parquet_glob: glob).run(
      name_pattern: "%berlin%", train_types: %w[ICE IC]
    )

    expect(rows.size).to eq(1)
    expect(rows.first.eva).to eq("08011160")
    expect(rows.first.train_types).to contain_exactly("IC", "ICE")
    expect(rows.first.trains).to eq(2) # ride_a + ride_b, ride_c excluded by --types
  end

  it "returns empty for non-matching pattern" do
    rows = described_class.new(parquet_glob: glob).run(name_pattern: "%nowhere%")
    expect(rows).to be_empty
  end
end
