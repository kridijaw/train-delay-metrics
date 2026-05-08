require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::FileInput do
  let(:tmpdir) { Dir.mktmpdir("file-input-spec") }

  around do |example|
    original = Dir.pwd
    Dir.chdir(tmpdir)
    FileUtils.mkdir_p("out")
    example.run
  ensure
    Dir.chdir(original) if original
    FileUtils.remove_entry(tmpdir) if tmpdir && File.exist?(tmpdir)
  end

  it "returns the literal path when it exists" do
    File.write("foo.txt", "x")
    expect(described_class.resolve("foo.txt")).to eq("foo.txt")
  end

  it "falls back to out/<raw> for bare filenames" do
    File.write("out/foo.txt", "x")
    expect(described_class.resolve("foo.txt")).to eq("out/foo.txt")
  end

  it "tries out/<raw><extension> when extension: is given" do
    File.write("out/berlin_to_regensburg.json", "[]")
    expect(described_class.resolve("berlin_to_regensburg", extension: ".json"))
      .to eq("out/berlin_to_regensburg.json")
  end

  it "tries out/<prefix><raw> when prefix: is given" do
    File.write("out/station_berlin", "x")
    expect(described_class.resolve("berlin", prefix: "station_"))
      .to eq("out/station_berlin")
  end

  it "tries out/<prefix><raw><extension> when both are given" do
    File.write("out/station_berlin.txt", "x")
    expect(described_class.resolve("berlin", prefix: "station_", extension: ".txt"))
      .to eq("out/station_berlin.txt")
    File.write("out/tbs_berlin_to_regensburg.json", "[]")
    expect(described_class.resolve("berlin_to_regensburg", prefix: "tbs_", extension: ".json"))
      .to eq("out/tbs_berlin_to_regensburg.json")
  end

  it "does not double-apply prefix or extension when raw already has them" do
    File.write("out/station_berlin.txt", "x")
    expect(described_class.resolve("station_berlin.txt", prefix: "station_", extension: ".txt"))
      .to eq("out/station_berlin.txt")
    expect(described_class.resolve("station_berlin", prefix: "station_", extension: ".txt"))
      .to eq("out/station_berlin.txt")
    expect(described_class.resolve("berlin.txt", prefix: "station_", extension: ".txt"))
      .to eq("out/station_berlin.txt")
  end

  it "prefers the literal path over a prefix/extension fallback" do
    File.write("out/berlin", "literal")
    File.write("out/station_berlin.txt", "fallback")
    expect(described_class.resolve("berlin", prefix: "station_", extension: ".txt"))
      .to eq("out/berlin")
  end

  it "returns nil when nothing matches" do
    expect(described_class.resolve("nope", prefix: "tbs_", extension: ".json")).to be_nil
  end

  it "returns nil for a path with separators that does not exist" do
    expect(described_class.resolve("some/path.txt")).to be_nil
  end

  it "transliterates German umlauts to ASCII when looking up files" do
    File.write("out/station_duesseldorf.txt", "x")
    expect(described_class.resolve("düsseldorf", prefix: "station_", extension: ".txt"))
      .to eq("out/station_duesseldorf.txt")
    expect(described_class.resolve("düsseldorf.txt", prefix: "station_", extension: ".txt"))
      .to eq("out/station_duesseldorf.txt")
    expect(described_class.resolve("station_düsseldorf.txt", prefix: "station_", extension: ".txt"))
      .to eq("out/station_duesseldorf.txt")
  end

  it "transliterates ä, ö, ü, and ß without a prefix when an extension is given" do
    File.write("out/koeln_muenchen_strasse.txt", "x")
    expect(described_class.resolve("köln_münchen_straße", extension: ".txt"))
      .to eq("out/koeln_muenchen_strasse.txt")
  end
end
