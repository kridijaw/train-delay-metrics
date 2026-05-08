require "fileutils"
require "optparse"
require_relative "stations"

module TrainDelayMetrics
  class StationsCLI
    OUT_DIR = "out".freeze

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = { parquet_glob: Query::DEFAULT_GLOB, train_types: [], out: nil }

      parser = OptionParser.new do |o|
        o.banner = %{Usage: find-train-stations PATTERN [options]

  PATTERN is a SQL ILIKE pattern, e.g. "berlin sp%" or "%frankfurt%".
  If you pass a bare word, it is wrapped as %word%.}
        o.on("--types LIST", Array, %q{Comma-separated train types to keep, e.g. "IC,ICE". Case-sensitive.}) { |v| options[:train_types] = v }
        o.on("--out FILE", "Write the matching EVAs to FILE, one per line. Bare filenames are saved under #{OUT_DIR}/.") { |v| options[:out] = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      if argv.empty?
        stdout.puts parser
        return 0
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
      stdout.puts format("%-#{name_w}s  %-#{eva_w}s  %-7s  %s", "Station", "EVA", "Trains", "Train types")
      stdout.puts "-" * (name_w + 2 + eva_w + 2 + 7 + 2 + 40)
      rows.each do |r|
        stdout.puts format("%-#{name_w}s  %-#{eva_w}s  %7d  %s",
                           r.station_name, r.eva, r.trains, r.train_types.join(", "))
      end
      stdout.puts "(#{rows.size} EVA#{'s' unless rows.size == 1})"

      if options[:out]
        path = options[:out].include?(File::SEPARATOR) ? options[:out] : File.join(OUT_DIR, options[:out])
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rows.map(&:eva).join("\n") + "\n")
        stdout.puts "Wrote #{rows.size} EVA#{'s' unless rows.size == 1} to #{path}."
      end
      0
    end
  end
end
