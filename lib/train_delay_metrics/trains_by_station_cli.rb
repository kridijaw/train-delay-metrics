require "date"
require "io/console"
require "optparse"
require_relative "connections"

module TrainDelayMetrics
  class TrainsByStationCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        years_back:    nil,
        exclude_types: [],
        parquet_glob:  Query::DEFAULT_GLOB
      }

      parser = OptionParser.new do |o|
        o.banner = %q{Usage: trains-by-station --from EVA[,EVA...] --to EVA[,EVA...] [options]

  For each EVA in the union of --from / --to, prints the alphabetically
  sorted list of trains that touch that EVA and connect any from-EVA to
  any to-EVA in the window. Useful for seeing which platform-group EVAs
  each train uses.}
        o.on("--from LIST", Array, "Origin EVA(s), comma-separated") { |v| options[:from_evas] = v }
        o.on("--to LIST",   Array, "Destination EVA(s), comma-separated") { |v| options[:to_evas] = v }
        o.on("--years N", Integer, "Years of history (default: all available data)") { |v| options[:years_back] = v }
        o.on("--exclude-types LIST", Array, %q{Exclude train_types (case-insensitive), e.g. --exclude-types FLX,DPF}) { |v| options[:exclude_types] = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
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

      from_set = options[:from_evas]
      to_set   = options[:to_evas]
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
      0
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
