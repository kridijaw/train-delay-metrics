require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe TrainDelayMetrics::FindTrainsCLI do
  describe ".parse_input_pairs" do
    let(:tmpdir) { Dir.mktmpdir("tbs-input-spec") }
    let(:path)   { File.join(tmpdir, "pairs.txt") }
    let(:stderr) { StringIO.new }

    after { FileUtils.remove_entry(tmpdir) }

    it "splits each line on the first comma" do
      File.write(path, <<~TXT)
        @station_berlin.txt, @station_koeln.txt
        @station_berlin.txt, @station_regensburg.txt
      TXT

      pairs = described_class.parse_input_pairs(path, stderr)
      expect(pairs).to eq([
        ["@station_berlin.txt", "@station_koeln.txt"],
        ["@station_berlin.txt", "@station_regensburg.txt"]
      ])
      expect(stderr.string).to be_empty
    end

    it "supports ' -> ' as a separator so each side can contain commas" do
      File.write(path, "08000105,08098105 -> 08000207,08098207\n")
      pairs = described_class.parse_input_pairs(path, stderr)
      expect(pairs).to eq([["08000105,08098105", "08000207,08098207"]])
    end

    it "ignores blank lines and # comments" do
      File.write(path, <<~TXT)
        # First pair (Berlin → Köln)
        @berlin, @koeln

        # Second pair
        @berlin, @regensburg
      TXT

      pairs = described_class.parse_input_pairs(path, stderr)
      expect(pairs).to eq([
        ["@berlin", "@koeln"],
        ["@berlin", "@regensburg"]
      ])
    end

    it "returns nil and reports the line on a missing separator" do
      File.write(path, "@berlin only\n")
      expect(described_class.parse_input_pairs(path, stderr)).to be_nil
      expect(stderr.string).to include("pairs.txt:1")
      expect(stderr.string).to include("missing separator")
    end

    it "returns nil and reports the line on an empty side" do
      File.write(path, "@berlin,\n")
      expect(described_class.parse_input_pairs(path, stderr)).to be_nil
      expect(stderr.string).to include("pairs.txt:1")
      expect(stderr.string).to include("empty from or to spec")
    end
  end
end
