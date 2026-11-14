require "spec_helper"
require "json"

RSpec.describe TrainDelayMetrics::Sql do
  shared_dir = File.expand_path("shared", __dir__)

  describe ".expand" do
    JSON.parse(File.read(File.join(shared_dir, "sql_template_cases.json"))).each do |c|
      if c["error"]
        it "raises for #{c['name']}" do
          expect { described_class.expand(c["text"], c["params"]) }.to raise_error(ArgumentError)
        end
      else
        it "expands #{c['name']}" do
          expect(described_class.expand(c["text"], c["params"])).to eq([c["sql"], c["binds"]])
        end
      end
    end

    it "accepts symbol keys" do
      expect(described_class.expand("a = {{a}}", { a: 1 })).to eq(["a = ?", [1]])
    end
  end

  describe ".cutoff" do
    JSON.parse(File.read(File.join(shared_dir, "cutoff_cases.json"))).each do |c|
      it "#{c['today']} minus #{c['months_back'].inspect} months is #{c['expected'].inspect}" do
        expect(described_class.cutoff(c["months_back"], today: Date.iso8601(c["today"]))).to eq(c["expected"])
      end
    end
  end

  describe ".load" do
    it "expands every shared SQL file with all params present" do
      params = {
        train_names: ["ICE 1"], evas: ["1"], origin_evas: ["2"], cutoff: "2025-01-01", threshold: 20,
        all_evas: ["1", "2"], from_evas: ["1"], to_evas: ["2"], exclude_types: ["FLX"],
        name_pattern: "%x%", train_types: ["ICE"]
      }
      Dir.glob(File.join(described_class::SQL_DIR, "*.sql")).each do |path|
        sql, = described_class.expand(described_class.load(File.basename(path, ".sql")), params)
        expect(sql).not_to include("{{")
      end
    end
  end
end
