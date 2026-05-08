require "date"
require "fileutils"
require "optparse"
require_relative "connections"

module TrainDelayMetrics
  class GetTrainsCLI
    OUT_DIR = "out".freeze

    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        years_back:    nil,
        exclude_types: [],
        out:           nil,
        parquet_glob:  Query::DEFAULT_GLOB
      }

      parser = OptionParser.new do |o|
        o.banner = %q{Usage: get-trains --from EVA[,EVA...] --to EVA[,EVA...] [options]

  Prints an alphabetically sorted, deduplicated list of train names that
  connect the given stations. Output is consumable by `train-delay --train @FILE`.}
        o.on("--from LIST", Array, "Origin EVA(s), comma-separated") { |v| options[:from_evas] = v }
        o.on("--to LIST",   Array, "Destination EVA(s), comma-separated") { |v| options[:to_evas] = v }
        o.on("--years N", Integer, "Years of history (default: all available data)") { |v| options[:years_back] = v }
        o.on("--exclude-types LIST", Array, %q{Exclude train_types (case-insensitive), e.g. --exclude-types FLX,DPF}) { |v| options[:exclude_types] = v }
        o.on("--out FILE", "Write the train-name list to FILE, one per line. Bare filenames are saved under #{OUT_DIR}/.") { |v| options[:out] = v }
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

      names = svc.unique_train_names(
        from_eva:      options[:from_evas],
        to_eva:        options[:to_evas],
        years_back:    options[:years_back],
        exclude_types: options[:exclude_types]
      )

      if names.empty?
        stdout.puts "No connections found from #{options[:from_evas].join(',')} to #{options[:to_evas].join(',')}."
        return 0
      end

      if options[:out]
        path = options[:out].include?(File::SEPARATOR) ? options[:out] : File.join(OUT_DIR, options[:out])
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, names.join("\n") + "\n")
        stdout.puts "Wrote #{names.size} train names to #{path}."
      else
        names.each { |n| stdout.puts n }
      end
      0
    end
  end
end
