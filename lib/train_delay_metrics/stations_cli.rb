require "optparse"
require_relative "stations"

module TrainDelayMetrics
  class StationsCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = { parquet_glob: Query::DEFAULT_GLOB, train_types: [] }

      parser = OptionParser.new do |o|
        o.banner = %{Usage: train-stations PATTERN [options]

  PATTERN is a SQL ILIKE pattern, e.g. "berlin sp%" or "%frankfurt%".
  If you pass a bare word, it is wrapped as %word%.}
        o.on("--types LIST", Array, %q{Comma-separated train types to keep, e.g. "IC,ICE". Case-sensitive.}) { |v| options[:train_types] = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      parser.parse!(argv)

      raw = argv.shift
      if raw.nil? || raw.empty?
        stderr.puts "Missing PATTERN argument."
        stderr.puts parser
        return 1
      end
      pattern = raw.include?("%") ? raw : "%#{raw}%"

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      rows = Stations.new(parquet_glob: options[:parquet_glob])
                     .run(name_pattern: pattern, train_types: options[:train_types])

      if rows.empty?
        stdout.puts "No stations match #{pattern.inspect}."
        return 0
      end

      name_w = [rows.map { |r| r.station_name.to_s.length }.max, 14].max
      eva_w  = [rows.map { |r| r.eva.to_s.length }.max, 8].max
      stdout.puts format("%-#{name_w}s  %-#{eva_w}s  %-9s  %s", "Station", "EVA", "Rows", "Train types")
      stdout.puts "-" * (name_w + 2 + eva_w + 2 + 9 + 2 + 40)
      rows.each do |r|
        stdout.puts format("%-#{name_w}s  %-#{eva_w}s  %9d  %s",
                           r.station_name, r.eva, r.rows, r.train_types.join(", "))
      end
      stdout.puts "(#{rows.size} EVA#{'s' unless rows.size == 1})"
      0
    end
  end
end
