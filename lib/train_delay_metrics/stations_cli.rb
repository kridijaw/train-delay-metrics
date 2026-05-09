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
                find-train-stations --input FILE [options]

  PATTERN is a SQL ILIKE pattern, e.g. "berlin sp%" or "%frankfurt%".
  If you pass a bare word, it is wrapped as %word%.

  --input replaces the positional PATTERN: each non-blank, non-comment
  line in FILE is processed as its own PATTERN.}
        o.on("--types LIST", Array, %q{Comma-separated train types to keep, e.g. "IC,ICE". Case-sensitive.}) { |v| options[:train_types] = v }
        o.on("--out [FILE]", "Write the matching EVAs to FILE, one per line. Without a value, derives FILE from PATTERN. Bare filenames are saved under #{OUT_DIR}/.") { |v| options[:out] = v || :auto }
        o.on("--input FILE", "Read patterns from FILE, one per line. Bare filenames are resolved against #{OUT_DIR}/. Replaces the positional PATTERN.") do |v|
          raw  = v.delete_prefix("@")
          path = FileInput.resolve(raw)
          unless path
            stderr.puts "Input file not found: #{raw} (also tried out/#{raw})"
            return 1
          end
          options[:input_file] = path
        end
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      if argv.empty?
        stdout.puts parser
        return 0
      end
      parser.parse!(argv)

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      if options[:input_file]
        if argv.any?
          stderr.puts "--input cannot be combined with a positional PATTERN."
          return 1
        end
        if options[:out].is_a?(String)
          stderr.puts "--input cannot be combined with --out FILE (each pattern needs its own file). Pass --out without a value to auto-derive per pattern."
          return 1
        end

        patterns = read_patterns(options[:input_file])
        if patterns.empty?
          stderr.puts "No patterns found in #{options[:input_file]}."
          return 1
        end

        patterns.each_with_index do |raw, i|
          stdout.puts if i > 0
          stdout.puts "=== #{raw} ==="
          rc = run_one(stdout, options, raw)
          return rc unless rc == 0
        end
        return 0
      end

      raw = argv.shift
      if raw.nil? || raw.empty?
        stderr.puts "Missing PATTERN argument (or use --input FILE)."
        stderr.puts parser
        return 1
      end

      run_one(stdout, options, raw)
    end

    # Runs the lookup for a single PATTERN string, prints the table, and
    # optionally writes the EVA list to a file. Returns a CLI exit code.
    def self.run_one(stdout, options, raw)
      pattern = raw.include?("%") ? raw : "%#{raw}%"

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
        out_arg = options[:out] == :auto ? derive_filename(raw) : options[:out]
        path = out_arg.include?(File::SEPARATOR) ? out_arg : File.join(OUT_DIR, out_arg)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rows.map(&:eva).join("\n") + "\n")
        stdout.puts "Wrote #{rows.size} EVA#{'s' unless rows.size == 1} to #{path}."
      end
      0
    end

    def self.read_patterns(path)
      File.foreach(path, chomp: true)
          .map(&:strip)
          .reject { |l| l.empty? || l.start_with?("#") }
    end

    def self.derive_filename(pattern_raw)
      slug = Slug.slugify(pattern_raw)
      slug = "all" if slug.empty?
      "station_#{slug}.txt"
    end
  end
end
