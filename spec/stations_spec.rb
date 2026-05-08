require "duckdb"
require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::Stations do
  let(:tmpdir)  { Dir.mktmpdir("train-stations-spec") }
  let(:parquet) { File.join(tmpdir, "fixture.parquet") }
  let(:glob)    { File.join(tmpdir, "*.parquet") }

  before do
    conn = DuckDB::Database.new.connect
    conn.execute(<<~SQL)
      COPY (
        SELECT * FROM (VALUES
          ('Berlin Hbf',     '08011160', 'ICE'),
          ('Berlin Hbf',     '08011160', 'IC'),
          ('Berlin Hbf',     '08089001', 'S'),
          ('Berlin Hbf',     '08089001', 'S'),
          ('Munich Hbf',     '08000261', 'ICE'),
          ('Hamburg Altona', '08002553', 'IC')
        ) AS t(station_name, eva, train_type)
      ) TO '#{parquet}' (FORMAT PARQUET);
    SQL
  end

  after { FileUtils.remove_entry(tmpdir) }

  it "groups by station+eva and aggregates train types" do
    rows = described_class.new(parquet_glob: glob).run(name_pattern: "%berlin%")

    expect(rows.size).to eq(2)
    long_distance = rows.find { |r| r.eva == "08011160" }
    s_bahn        = rows.find { |r| r.eva == "08089001" }

    expect(long_distance.station_name).to eq("Berlin Hbf")
    expect(long_distance.train_types).to contain_exactly("IC", "ICE")
    expect(long_distance.rows).to eq(2)

    expect(s_bahn.train_types).to eq(["S"])
    expect(s_bahn.rows).to eq(2)
  end

  it "filters to only the requested train types" do
    rows = described_class.new(parquet_glob: glob).run(
      name_pattern: "%berlin%", train_types: %w[ICE IC]
    )

    expect(rows.size).to eq(1)
    expect(rows.first.eva).to eq("08011160")
    expect(rows.first.train_types).to contain_exactly("IC", "ICE")
    expect(rows.first.rows).to eq(2)
  end

  it "returns empty for non-matching pattern" do
    rows = described_class.new(parquet_glob: glob).run(name_pattern: "%nowhere%")
    expect(rows).to be_empty
  end
end
