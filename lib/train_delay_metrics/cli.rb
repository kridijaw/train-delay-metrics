require "json"
require "optparse"
require_relative "query"

module TrainDelayMetrics
  class CLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        threshold_minutes: 20,
        years_back:        3,
        parquet_glob:      Query::DEFAULT_GLOB,
        train_names:       [],
        input_file:        nil
      }

      parser = OptionParser.new do |o|
        o.banner = %q{Usage: train-delay --train NAME[,NAME...] --station EVA [options]
                  train-delay --input FILE [options]

  --train accepts either a comma-separated list ("ICE 802,ICE 821") or
  @FILE to read newline-separated names from FILE.

  --input replaces both --train and --station: it reads a JSON file written by
  `trains-by-station --out`, where each entry maps a list of EVAs to a list of
  trains. The delay query runs once per group, with delay measured at any of
  the group's EVAs.}
        o.on("--train SPEC", %q{Train name(s): comma-separated list or @FILE (bare names also resolved against out/)}) do |v|
          if v.start_with?("@")
            raw  = v[1..]
            path = FileInput.resolve(raw)
            unless path
              stderr.puts "Train list file not found: #{raw} (also tried out/#{raw})"
              return 1
            end
            options[:train_names] = FileInput.read_lines(path)
          else
            options[:train_names] = v.split(",").map(&:strip).reject(&:empty?)
          end
        end
        o.on("--station EVA",  "EVA station number, e.g. 8000105 (Frankfurt Hbf)") { |v| options[:station_eva] = v }
        o.on("--input FILE",   %q{JSON file from `trains-by-station --out` (bare names also resolved against out/). Use "all" to run every out/tbs_*.json. Replaces --train/--station.}) do |v|
          if v == "all"
            options[:input_all] = true
          else
            path = FileInput.resolve(v)
            unless path
              stderr.puts "Input file not found: #{v} (also tried out/#{v})"
              return 1
            end
            options[:input_file] = path
          end
        end
        o.on("--threshold-minutes N", Integer, "Delay threshold in minutes (default 20)") { |v| options[:threshold_minutes] = v }
        o.on("--years N", Integer, "Years of history to consider (default 3)") { |v| options[:years_back] = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      if argv.empty?
        stdout.puts parser
        return 0
      end
      parser.parse!(argv)

      if options[:input_file] || options[:input_all]
        if !options[:train_names].empty? || options[:station_eva]
          stderr.puts "--input cannot be combined with --train/--station."
          return 1
        end
      else
        if options[:train_names].empty? || options[:station_eva].nil?
          missing = []
          missing << "--train"   if options[:train_names].empty?
          missing << "--station" if options[:station_eva].nil?
          stderr.puts "Missing required option(s): #{missing.join(', ')} (or use --input FILE)"
          stderr.puts parser
          return 1
        end
      end

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      query = Query.new(parquet_glob: options[:parquet_glob])

      if options[:input_all]
        files = Dir.glob(File.join("out", "tbs_*.json")).sort
        if files.empty?
          stderr.puts %{--input all: no out/tbs_*.json files found. Run trains-by-station --out first.}
          return 1
        end
        files.each_with_index do |f, i|
          stdout.puts if i > 0
          stdout.puts "=== #{File.basename(f)} ==="
          rc = run_input(stdout, stderr, query, options.merge(input_file: f))
          return rc unless rc == 0
        end
        return 0
      end

      if options[:input_file]
        return run_input(stdout, stderr, query, options)
      end

      results = query.run_many(
        train_names:       options[:train_names],
        station_eva:       options[:station_eva],
        threshold_minutes: options[:threshold_minutes],
        years_back:        options[:years_back]
      )

      if results.size == 1
        print_single(stdout, results.first, options)
      else
        with_data = results.reject { |r| r.total_trips.zero? && r.canceled_trips.zero? }
        if with_data.empty?
          stdout.puts %{No trips found for any of the requested trains at EVA #{options[:station_eva]} in the last #{options[:years_back]} year(s).}
        else
          print_table(stdout, with_data, options)
        end
      end
      0
    end

    def self.run_input(stdout, stderr, query, options)
      groups = JSON.parse(File.read(options[:input_file]))
      unless groups.is_a?(Array)
        stderr.puts "Expected a JSON array in #{options[:input_file]}."
        return 1
      end

      groups.each_with_index do |g, i|
        evas   = Array(g["evas"]).map(&:to_s)
        trains = Array(g["trains"]).map(&:to_s)
        if evas.empty? || trains.empty?
          stderr.puts "Skipping group #{i + 1}: missing evas or trains."
          next
        end

        stdout.puts if i > 0
        stdout.puts "Group #{i + 1}: EVAs #{evas.join(', ')}  (#{trains.size} train#{'s' unless trains.size == 1})"

        results = query.run_many(
          train_names:       trains,
          station_evas:      evas,
          threshold_minutes: options[:threshold_minutes],
          years_back:        options[:years_back]
        )
        with_data = results.reject { |r| r.total_trips.zero? && r.canceled_trips.zero? }
        if with_data.empty?
          stdout.puts "  No trips found in the last #{options[:years_back]} year(s)."
        else
          print_table(stdout, with_data, options, indent: "  ")
        end
      end
      0
    end

    def self.print_single(stdout, r, options)
      if r.total_trips.zero? && r.canceled_trips.zero?
        stdout.puts %{No trips found for "#{r.train_name}" at EVA #{options[:station_eva]} in the last #{options[:years_back]} year(s).}
        return
      end
      stdout.puts "Total trips:                     #{r.total_trips}"
      stdout.puts "Trips canceled:                  #{r.canceled_trips}"
      stdout.puts "Trips delayed >= #{options[:threshold_minutes]} min:        #{r.delayed_trips}"
      if r.delay_percentage
        stdout.puts "Delay probability:               #{format('%.2f', r.delay_percentage)}%"
      else
        stdout.puts "Delay probability:               - (no trips ran)"
      end
    end

    def self.print_table(stdout, results, options, indent: "")
      name_w = [results.map { |r| r.train_name.to_s.length }.max, 5].max
      stdout.puts indent + format("%-#{name_w}s  %7s  %7s  %7s  %7s",
                                  "Train", "Trips", "Cancel", "Delay#{options[:threshold_minutes]}+", "Prob%")
      stdout.puts indent + "-" * (name_w + 2 + 7 + 2 + 7 + 2 + 7 + 2 + 7)
      results.each do |r|
        prob = r.delay_percentage ? format("%.2f", r.delay_percentage) : "-"
        stdout.puts indent + format("%-#{name_w}s  %7d  %7d  %7d  %7s",
                                    r.train_name, r.total_trips, r.canceled_trips, r.delayed_trips, prob)
      end
    end
  end
end
