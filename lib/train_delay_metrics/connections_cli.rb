require "date"
require "optparse"
require_relative "connections"

module TrainDelayMetrics
  class ConnectionsCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        years_back:   nil,
        parquet_glob: Query::DEFAULT_GLOB
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: train-connections --from EVA[,EVA...] --to EVA[,EVA...] [options]"
        o.on("--from LIST", Array, "Origin EVA(s), comma-separated, e.g. 08000105 or 08000105,08098105") { |v| options[:from_evas] = v }
        o.on("--to LIST",   Array, "Destination EVA(s), comma-separated")                                 { |v| options[:to_evas]   = v }
        o.on("--years N", Integer, "Years of history (default: all available data)") { |v| options[:years_back] = v }
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

      rows = svc.run(
        from_eva:    options[:from_evas],
        to_eva:      options[:to_evas],
        years_back:  options[:years_back]
      )

      if rows.empty?
        stdout.puts "No connections found from #{options[:from_evas].join(',')} to #{options[:to_evas].join(',')}."
        return 0
      end

      train_w = [rows.map { |r| r.train_name.to_s.length }.max, 10].max
      stdout.puts format("%-#{train_w}s  %-5s  %-5s  %-27s  %s", "Train", "Dep", "Arr", "Days", "Obs")
      stdout.puts "-" * (train_w + 2 + 5 + 2 + 5 + 2 + 27 + 2 + 3)
      rows.each do |r|
        stdout.puts format("%-#{train_w}s  %5s  %5s  %-27s  %d",
                           r.train_name, r.departure, r.arrival, r.days.join(" "), r.observations)
      end
      0
    end
  end
end
