require "optparse"
require_relative "connections"

module TrainDelayMetrics
  class ConnectionsCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = {
        years_back:   3,
        parquet_glob: Query::DEFAULT_GLOB
      }

      parser = OptionParser.new do |o|
        o.banner = "Usage: train-connections --from EVA --to EVA [options]"
        o.on("--from EVA",   "Origin EVA, e.g. 08000105")           { |v| options[:from_eva] = v }
        o.on("--to EVA",     "Destination EVA, e.g. 08000207")      { |v| options[:to_eva]   = v }
        o.on("--years N", Integer, "Years of history (default 3)")  { |v| options[:years_back]   = v }
        o.on("--data GLOB", "Parquet glob (default #{Query::DEFAULT_GLOB})") { |v| options[:parquet_glob] = v }
        o.on("-h", "--help") { stdout.puts o; return 0 }
      end
      parser.parse!(argv)

      missing = %i[from_eva to_eva].select { |k| options[k].nil? }
      unless missing.empty?
        stderr.puts "Missing required option(s): #{missing.map { |k| "--#{k.to_s.split('_').first}" }.join(', ')}"
        stderr.puts parser
        return 1
      end

      if Dir.glob(options[:parquet_glob]).empty?
        stderr.puts "No Parquet files match #{options[:parquet_glob]}. Run script/fetch_dataset.rb or pass --data."
        return 2
      end

      rows = Connections.new(parquet_glob: options[:parquet_glob]).run(
        from_eva:    options[:from_eva],
        to_eva:      options[:to_eva],
        years_back:  options[:years_back]
      )

      if rows.empty?
        stdout.puts "No connections found from EVA #{options[:from_eva]} to EVA #{options[:to_eva]}."
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
