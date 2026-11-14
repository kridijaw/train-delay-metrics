require "spec_helper"
require "json"
require "tmpdir"

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

  describe ".connect" do
    around do |ex|
      Dir.mktmpdir("sql-connect-spec") { |dir| @dir = dir; ex.run }
    end

    it "maps upstream's raw columns onto stop_events" do
      path = File.join(@dir, "raw.parquet")
      DuckDB::Database.new.connect.execute(<<~SQL)
        COPY (SELECT * FROM (VALUES
          ('ICE', '619',   NULL,  FALSE, FALSE),
          ('RE',  '3730',  'RE7', TRUE,  FALSE),
          ('S',   '38137', 'S1',  FALSE, TRUE),
          (NULL,  NULL,    'S3',  FALSE, FALSE)
        ) AS t(train_type, train_number, line_number, arrival_is_canceled, departure_is_canceled))
        TO '#{path}' (FORMAT PARQUET)
      SQL

      rows = described_class.connect(path).query("SELECT train_name, is_canceled FROM stop_events ORDER BY train_name").to_a
      expect(rows).to eq([["ICE 619", false], ["RE RE7", true], ["S S1", true]])
    end
  end
end
