require "date"
require "fileutils"
require "io/console"
require "json"
require "optparse"
require_relative "connections"

module TrainDelayMetrics
  class TrainsByStationCLI
    OUT_DIR = "out".freeze

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        years_back:     nil,
        exclude_types:  [],
        group_by_stops: false,
        out:            nil,
        parquet_glob:   Query::DEFAULT_GLOB
      }

      parser = OptionParser.new do |o|
        o.banner = %q{Usage: trains-by-station --from SPEC --to SPEC [options]

  --from / --to accept either a comma-separated EVA list ("08000105,08098105")
  or @FILE to read newline-separated EVAs from a file (bare names also
  resolved against out/, e.g. those produced by find-train-stations --out).

  For each EVA in the union of --from / --to, prints the alphabetically
  sorted list of trains that touch that EVA and connect any from-EVA to
  any to-EVA in the window. Useful for seeing which platform-group EVAs
  each train uses.}
        o.on("--from SPEC", "Origin EVA(s): comma-separated list or @FILE") do |v|
          options[:from_spec] = v
          options[:from_evas] = parse_eva_spec(v, "--from", stderr) or return 1
        end
        o.on("--to SPEC",   "Destination EVA(s): comma-separated list or @FILE") do |v|
          options[:to_spec]  = v
          options[:to_evas]  = parse_eva_spec(v, "--to", stderr) or return 1
        end
        o.on("--years N", Integer, "Years of history (default: all available data)") { |v| options[:years_back] = v }
        o.on("--exclude-types LIST", Array, %q{Exclude train_types (case-insensitive), e.g. --exclude-types FLX,DPF}) { |v| options[:exclude_types] = v }
        o.on("--group-by-stops", "Group trains by the exact set of from/to EVAs they touch instead of listing per EVA") { options[:group_by_stops] = true }
        o.on("--out [FILE]", "Also write the EVAs↔trains mapping to FILE as JSON. Without a value, derives FILE as <from>-to-<to>.json. Bare filenames are saved under #{OUT_DIR}/. Consumable by `train-delay --input`.") { |v| options[:out] = v || :auto }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      if argv.empty?
        stdout.puts parser
        return 0
      end
      parser.parse!(argv)

      missing = %i[from_evas to_evas].select { |k| options[k].nil? || options[k].empty? }
      unless missing.empty?
        stderr.puts "Missing required option(s): #{missing.map { |k| "--#{k.to_s.split('_').first}" }.join(', ')}"
        stderr.puts parser
        return 1
      end

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      svc = Connections.new(parquet_glob: options[:parquet_glob])

      window_from, window_to =
        if options[:years_back]
          [(Date.today << (options[:years_back] * 12)).to_s, Date.today.to_s]
        else
          min_d, max_d = svc.data_date_range
          [min_d&.to_s || "(none)", max_d&.to_s || "(none)"]
        end
      stdout.puts "Window: #{window_from} -> #{window_to}#{options[:years_back] ? " (--years #{options[:years_back]})" : " (full dataset)"}"

      from_set = options[:from_evas]
      to_set   = options[:to_evas]

      if options[:group_by_stops]
        return print_grouped(stdout, svc, options, from_set, to_set)
      end

      # When --out is set without --group-by-stops, the per-EVA listing is
      # also serialised so each EVA becomes its own group of one.

      rows = svc.trains_by_station(
        from_eva:      options[:from_evas],
        to_eva:        options[:to_evas],
        years_back:    options[:years_back],
        exclude_types: options[:exclude_types]
      )

      if rows.empty?
        stdout.puts "No matching trains for the given from/to."
        return 0
      end

      rows = rows.sort_by { |r| [from_set.include?(r.eva) ? 0 : 1, r.eva] }
      name_w   = [rows.map { |r| (r.station_name || "").length }.max, 7].max
      term_w   = terminal_width
      prefix_w = 8 + 2 + 7 + 2 + name_w + 2 # EVA + Side + Station columns + gaps
      trains_w = [term_w - prefix_w, 20].max

      stdout.puts format("%-8s  %-7s  %-#{name_w}s  %s", "EVA", "Side", "Station", "Trains")
      stdout.puts "-" * [term_w, prefix_w + trains_w].min
      rows.each do |r|
        side = []
        side << "from" if from_set.include?(r.eva)
        side << "to"   if to_set.include?(r.eva)
        lines = wrap_join(r.trains, ", ", trains_w)
        stdout.puts format("%-8s  %-7s  %-#{name_w}s  %s", r.eva, side.join("/"), r.station_name.to_s, lines.first)
        lines.drop(1).each { |l| stdout.puts (" " * prefix_w) + l }
      end

      if options[:out]
        groups = rows.map { |r| { "evas" => [r.eva], "trains" => r.trains } }
        write_out(stdout, resolve_out_path(options), groups)
      end
      0
    end

    def self.resolve_out_path(options)
      arg = options[:out]
      arg = derive_filename(options[:from_spec], options[:to_spec]) if arg == :auto
      arg.include?(File::SEPARATOR) ? arg : File.join(OUT_DIR, arg)
    end

    def self.derive_filename(from_spec, to_spec)
      "#{slug_spec(from_spec)}_to_#{slug_spec(to_spec)}.json"
    end

    def self.slug_spec(spec)
      s = spec.to_s
      s = s[1..] if s.start_with?("@")
      s = File.basename(s, ".*") if s.include?(".")
      Slug.slugify(s)
    end

    def self.write_out(stdout, path, groups)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(groups) + "\n")
      total_trains = groups.sum { |g| g["trains"].size }
      stdout.puts "Wrote #{groups.size} group#{'s' unless groups.size == 1} (#{total_trains} train mapping#{'s' unless total_trains == 1}) to #{path}."
    end

    def self.print_grouped(stdout, svc, options, from_set, to_set)
      coverage = svc.train_coverage(
        from_eva:      options[:from_evas],
        to_eva:        options[:to_evas],
        years_back:    options[:years_back],
        exclude_types: options[:exclude_types]
      )
      if coverage.empty?
        stdout.puts "No matching trains for the given from/to."
        return 0
      end

      station_rows = svc.trains_by_station(
        from_eva:      options[:from_evas],
        to_eva:        options[:to_evas],
        years_back:    options[:years_back],
        exclude_types: options[:exclude_types]
      )
      eva_to_name = station_rows.each_with_object({}) { |r, h| h[r.eva] = r.station_name }

      groups = coverage.group_by { |c| c.evas }
      sorted_groups = groups.keys.sort_by do |evas|
        from_count = evas.count { |e| from_set.include?(e) }
        to_count   = evas.count { |e| to_set.include?(e) }
        # Largest coverage first; within that, more from-EVAs first; then EVA list.
        [-evas.size, -from_count, -to_count, evas]
      end

      side_for = ->(e) {
        s = []
        s << "from" if from_set.include?(e)
        s << "to"   if to_set.include?(e)
        s.join("/")
      }

      side_w    = [sorted_groups.flat_map { |g| g.map { |e| side_for.call(e).length } }.max, 4].max
      eva_w     = 8 + 1 # trailing comma
      station_w = [sorted_groups.flat_map { |g| g.map { |e| (eva_to_name[e] || "").length } }.max, 7].max
      term_w    = terminal_width
      prefix_w  = side_w + 2 + eva_w + 2 + station_w + 2
      trains_w  = [term_w - prefix_w, 20].max

      stdout.puts format("%-#{side_w}s  %-#{eva_w}s  %-#{station_w}s  %s", "Side", "EVA", "Station", "Trains")
      stdout.puts "-" * [term_w, prefix_w + trains_w].min

      sorted_groups.each_with_index do |evas, gi|
        stdout.puts if gi > 0
        trains = groups[evas].map(&:train_name).sort_by { |n| TrainName.sort_key(n) }
        train_lines = wrap_join(trains, ", ", trains_w)

        display_evas = evas.sort_by { |e| [from_set.include?(e) ? 0 : 1, e] }
        rows = [display_evas.size, train_lines.size].max
        rows.times do |i|
          if i < display_evas.size
            e = display_evas[i]
            eva_cell = i == display_evas.size - 1 ? e : "#{e},"
            side_cell    = side_for.call(e)
            station_cell = eva_to_name[e].to_s
          else
            eva_cell = side_cell = station_cell = ""
          end
          train_cell = train_lines[i] || ""
          stdout.puts format("%-#{side_w}s  %-#{eva_w}s  %-#{station_w}s  %s",
                             side_cell, eva_cell, station_cell, train_cell)
        end
      end

      if options[:out]
        json_groups = sorted_groups.map do |evas|
          trains = groups[evas].map(&:train_name).sort_by { |n| TrainName.sort_key(n) }
          { "evas" => evas, "trains" => trains }
        end
        write_out(stdout, resolve_out_path(options), json_groups)
      end
      0
    end

    # Parses a --from / --to value: either a comma-separated EVA list or
    # @FILE (file path resolved literally first, then under out/).
    # Returns the EVA array on success or nil after printing an error.
    def self.parse_eva_spec(value, flag, stderr)
      if value.start_with?("@")
        raw  = value[1..]
        path = FileInput.resolve(raw)
        unless path
          stderr.puts "#{flag} file not found: #{raw} (also tried out/#{raw})"
          return nil
        end
        FileInput.read_lines(path)
      else
        value.split(",").map(&:strip).reject(&:empty?)
      end
    end

    def self.terminal_width
      cols = ENV["COLUMNS"]&.to_i
      return cols if cols && cols > 0
      IO.console&.winsize&.last || 100
    rescue
      100
    end

    # Joins items with `sep` and breaks into lines so that no single line
    # exceeds `width` characters. Continuation lines keep a trailing `sep`
    # (sans whitespace) to make the wrap visually unambiguous.
    def self.wrap_join(items, sep, width)
      trim_sep = sep.rstrip
      lines = []
      current = +""
      items.each do |item|
        candidate = current.empty? ? item : "#{current}#{sep}#{item}"
        if candidate.length <= width || current.empty?
          current = candidate
        else
          lines << current + trim_sep
          current = item.dup
        end
      end
      lines << current unless current.empty?
      lines.empty? ? [""] : lines
    end
  end
end
