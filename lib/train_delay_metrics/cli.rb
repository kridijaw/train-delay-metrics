require "optparse"
require_relative "query"

module TrainDelayMetrics
  class CLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        threshold_minutes: 20,
        years_back:        3,
        parquet_glob:      Query::DEFAULT_GLOB
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: train-delay --train NAME --station EVA [options]"
        o.on("--train NAME",   %q{Train name as it appears in the data, e.g. "ICE 802"}) { |v| options[:train_name]  = v }
        o.on("--station EVA",  "EVA station number, e.g. 8000105 (Frankfurt Hbf)")        { |v| options[:station_eva] = v }
        o.on("--threshold-minutes N", Integer, "Delay threshold in minutes (default 20)") { |v| options[:threshold_minutes] = v }
        o.on("--years N", Integer, "Years of history to consider (default 3)")            { |v| options[:years_back] = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})")               { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      parser.parse!(argv)

      missing = %i[train_name station_eva].select { |k| options[k].nil? }
      unless missing.empty?
        stderr.puts "Missing required option(s): #{missing.map { |k| "--#{k.to_s.split('_').first}" }.join(', ')}"
        stderr.puts parser
        return 1
      end

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      result = Query.new(parquet_glob: options[:parquet_glob]).run(
        train_name:        options[:train_name],
        station_eva:       options[:station_eva],
        threshold_minutes: options[:threshold_minutes],
        years_back:        options[:years_back]
      )

      if result.total_trips.zero?
        stdout.puts %{No trips found for "#{options[:train_name]}" at EVA #{options[:station_eva]} in the last #{options[:years_back]} year(s).}
        return 0
      end

      stdout.puts "Total trips:                     #{result.total_trips}"
      stdout.puts "Trips delayed >= #{options[:threshold_minutes]} min:        #{result.delayed_trips}"
      stdout.puts "Delay probability:               #{format('%.2f', result.delay_percentage)}%"
      0
    end
  end
end
