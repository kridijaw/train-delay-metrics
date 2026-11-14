require "duckdb"
require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::Connections do
  let(:tmpdir)  { Dir.mktmpdir("train-conn-spec") }

  after { FileUtils.remove_entry(tmpdir) }

  it "trains_by_station lists trains per EVA, alphabetically, with --exclude-types respected" do
    typed = File.join(tmpdir, "by_station.parquet")
    write_fixture("connections_by_station", typed)

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

  it "train_coverage returns the set of from/to EVAs each train touches" do
    typed = File.join(tmpdir, "coverage.parquet")
    write_fixture("connections_coverage", typed)

    rows = described_class.new(parquet_glob: typed).train_coverage(
      from_eva: %w[08000001 08000002], to_eva: %w[08000003 08000004]
    )
    by_train = rows.each_with_object({}) { |r, h| h[r.train_name] = r.evas }
    expect(by_train["ICE 9"]).to contain_exactly("08000001", "08000002", "08000003")
    expect(by_train["ICE 7"]).to contain_exactly("08000001", "08000004")
  end
end
