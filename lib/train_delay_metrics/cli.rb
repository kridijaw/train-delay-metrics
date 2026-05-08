require "optparse"
require_relative "query"

module TrainDelayMetrics
  class CLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        threshold_minutes: 20,
        years_back:        3,
        parquet_glob:      Query::DEFAULT_GLOB,
        train_names:       []
      }

      parser = OptionParser.new do |o|
        o.banner = %q{Usage: train-delay --train NAME[,NAME...] --station EVA [options]

  --train accepts either a comma-separated list ("ICE 802,ICE 821") or
  @FILE to read newline-separated names from FILE, e.g. one produced by
  `train-connections --unique --out trains.txt`.}
        o.on("--train SPEC", %q{Train name(s): comma-separated list or @FILE}) do |v|
          if v.start_with?("@")
            path = v[1..]
            unless File.exist?(path)
              stderr.puts "Train list file not found: #{path}"
              return 1
            end
            options[:train_names] = File.readlines(path, chomp: true).map(&:strip).reject(&:empty?)
          else
            options[:train_names] = v.split(",").map(&:strip).reject(&:empty?)
          end
        end
        o.on("--station EVA",  "EVA station number, e.g. 8000105 (Frankfurt Hbf)") { |v| options[:station_eva] = v }
        o.on("--threshold-minutes N", Integer, "Delay threshold in minutes (default 20)") { |v| options[:threshold_minutes] = v }
        o.on("--years N", Integer, "Years of history to consider (default 3)") { |v| options[:years_back] = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      parser.parse!(argv)

      if options[:train_names].empty? || options[:station_eva].nil?
        missing = []
        missing << "--train"   if options[:train_names].empty?
        missing << "--station" if options[:station_eva].nil?
        stderr.puts "Missing required option(s): #{missing.join(', ')}"
        stderr.puts parser
        return 1
      end

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      results = Query.new(parquet_glob: options[:parquet_glob]).run_many(
        train_names:       options[:train_names],
        station_eva:       options[:station_eva],
        threshold_minutes: options[:threshold_minutes],
        years_back:        options[:years_back]
      )

      if results.size == 1
        print_single(stdout, results.first, options)
      else
        print_table(stdout, results, options)
      end
      0
    end

    def self.print_single(stdout, r, options)
      if r.total_trips.zero?
        stdout.puts %{No trips found for "#{r.train_name}" at EVA #{options[:station_eva]} in the last #{options[:years_back]} year(s).}
        return
      end
      stdout.puts "Total trips:                     #{r.total_trips}"
      stdout.puts "Trips delayed >= #{options[:threshold_minutes]} min:        #{r.delayed_trips}"
      stdout.puts "Delay probability:               #{format('%.2f', r.delay_percentage)}%"
    end

    def self.print_table(stdout, results, options)
      name_w = [results.map { |r| r.train_name.to_s.length }.max, 5].max
      stdout.puts format("%-#{name_w}s  %7s  %7s  %7s",
                         "Train", "Trips", "Delay#{options[:threshold_minutes]}+", "Prob%")
      stdout.puts "-" * (name_w + 2 + 7 + 2 + 7 + 2 + 7)
      results.each do |r|
        prob = r.delay_percentage ? format("%.2f", r.delay_percentage) : "-"
        stdout.puts format("%-#{name_w}s  %7d  %7d  %7s",
                           r.train_name, r.total_trips, r.delayed_trips, prob)
      end
    end
  end
end
