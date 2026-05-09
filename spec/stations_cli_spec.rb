require "fileutils"
require "tmpdir"

RSpec.describe TrainDelayMetrics::StationsCLI do
  describe ".read_patterns" do
    let(:tmpdir) { Dir.mktmpdir("stations-cli-spec") }
    let(:path)   { File.join(tmpdir, "patterns.txt") }

    after { FileUtils.remove_entry(tmpdir) }

    it "returns one pattern per line, trimming whitespace" do
      File.write(path, "  berlin\nfrankfurt  \n%koeln%\n")
      expect(described_class.read_patterns(path)).to eq(["berlin", "frankfurt", "%koeln%"])
    end

    it "skips blank lines and # comments" do
      File.write(path, <<~TXT)
        # German cities

        berlin
        # second batch
        frankfurt

      TXT
      expect(described_class.read_patterns(path)).to eq(["berlin", "frankfurt"])
    end
  end
end
