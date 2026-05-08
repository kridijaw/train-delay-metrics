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
            # Tolerate a leading @ — --input always takes a filename, but
            # users habitually type @<name> from the --train / --from / --to
            # flags where the @ prefix is meaningful.
            raw  = v.delete_prefix("@")
            path = FileInput.resolve(raw, prefix: "tbs_", extension: ".json")
            unless path
              stderr.puts "Input file not found: #{raw} (also tried out/, tbs_<name>, tbs_<name>.json)"
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
      peaks = query.peak_windows(
        train_names:       options[:train_names],
        station_eva:       options[:station_eva],
        threshold_minutes: options[:threshold_minutes],
        years_back:        options[:years_back]
      )

      if results.size == 1
        print_single(stdout, results.first, peaks[results.first.train_name], options, time_source: :departure)
      else
        with_data = results.reject { |r| r.total_trips.zero? && r.canceled_trips.zero? }
        if with_data.empty?
          stdout.puts %{No trips found for any of the requested trains at EVA #{options[:station_eva]} in the last #{options[:years_back]} year(s).}
        else
          print_table(stdout, with_data, peaks, options, time_source: :departure)
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
        stdout.puts "Group #{i + 1}: #{format_group_title(g, evas)}"

        # If the group declares a `to` array (newer JSON format), measure
        # delay at the destination and de-dup to one row per (train, day).
        # Otherwise fall back to per-stop counting against the union of EVAs.
        to_evas = Array(g["to"]).map(&:to_s).reject(&:empty?)
        run_args = {
          train_names:       trains,
          threshold_minutes: options[:threshold_minutes],
          years_back:        options[:years_back]
        }
        if to_evas.any?
          run_args[:destination_evas] = to_evas
          time_source = :arrival
        else
          run_args[:station_evas] = evas
          time_source = :departure
        end

        results = query.run_many(**run_args)
        peaks   = query.peak_windows(**run_args)
        with_data = results.reject { |r| r.total_trips.zero? && r.canceled_trips.zero? }
        if with_data.empty?
          stdout.puts "  No trips found in the last #{options[:years_back]} year(s)."
        else
          print_table(stdout, with_data, peaks, options, indent: "  ", time_source: time_source)
        end
      end
      0
    end

    def self.print_single(stdout, r, peak, options, time_source: :departure)
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
      doc = r.delay_or_cancel_percentage
      stdout.puts "Delay-or-cancel probability:     #{doc ? format('%.2f', doc) + '%' : '-'}"
      kind = peak_time_label(time_source)
      label = "Peak #{kind} window (±30m):"
      label = label.ljust(33)
      if peak && peak.scheduled.positive?
        stdout.puts format("%s%s (%.2f%%, %d of %d)",
                           label, peak.center_hhmm, peak.percentage, peak.disrupted, peak.scheduled)
      else
        stdout.puts "#{label}-"
      end
    end

    def self.print_table(stdout, results, peaks, options, indent: "", time_source: :departure)
      name_w = [results.map { |r| r.train_name.to_s.length }.max, 5].max
      peak_w = 12 # fits "Arr Peak D+C" / "Dep Peak D+C" exactly; cells right-align inside
      peak_header = "#{peak_time_label(time_source).capitalize} Peak D+C"
      stdout.puts indent + format("%-#{name_w}s  %7s  %7s  %7s  %7s  %7s  %#{peak_w}s",
                                  "Train", "Trips", "Cancel", "Delay#{options[:threshold_minutes]}+",
                                  "Prob%", "Prob%+C", peak_header)
      stdout.puts indent + "-" * (name_w + 2 + 7 + 2 + 7 + 2 + 7 + 2 + 7 + 2 + 7 + 2 + peak_w)
      results.each do |r|
        prob   = r.delay_percentage           ? format("%.2f", r.delay_percentage)           : "-"
        prob_c = r.delay_or_cancel_percentage ? format("%.2f", r.delay_or_cancel_percentage) : "-"
        peak_s = format_peak_cell(peaks[r.train_name])
        stdout.puts indent + format("%-#{name_w}s  %7d  %7d  %7d  %7s  %7s  %#{peak_w}s",
                                    r.train_name, r.total_trips, r.canceled_trips, r.delayed_trips,
                                    prob, prob_c, peak_s)
      end
    end

    # Compact "HH:MM NNN%" for the table; "-" when no peak data is available
    # (e.g. no rows at the EVA had departure_planned_time, like a terminus).
    def self.format_peak_cell(peak)
      return "-" unless peak && peak.scheduled.positive?
      format("%s %3d%%", peak.center_hhmm, peak.percentage.round)
    end

    # "dep" for per-stop mode (time-of-day = departure_planned_time),
    # "arr" for destination-dedup mode (time-of-day = arrival_planned_time
    # at the destination EVA).
    def self.peak_time_label(time_source)
      time_source == :arrival ? "arr" : "dep"
    end

    # Group title for `train-delay --input`. Uses the new `from`/`to`/`stations`
    # keys when present (writing them is now the default in trains-by-station)
    # so the title reads "<from-stations> -> <to-stations>". Falls back to a
    # bare EVA list for older JSON files that lack those keys.
    def self.format_group_title(g, evas)
      from_evas = Array(g["from"]).map(&:to_s)
      to_evas   = Array(g["to"]).map(&:to_s)
      stations  = g["stations"].is_a?(Hash) ? g["stations"] : {}
      label     = ->(e) { (n = stations[e]) && !n.empty? ? "#{n} (#{e})" : e }

      # Legacy file with no side info — preserve old behaviour (no train count).
      return "EVAs #{evas.map(&label).join(', ')}" if from_evas.empty? && to_evas.empty?

      from_part = from_evas.map(&label).join(", ")
      to_only   = to_evas.reject { |e| from_evas.include?(e) }
      to_part   = to_only.map(&label).join(", ")

      if from_part.empty? then to_part
      elsif to_part.empty? then from_part
      else "#{from_part} -> #{to_part}"
      end
    end
  end
end
