require "duckdb"

module TrainDelayMetrics
  class Query
    Result = Struct.new(:train_name, :total_trips, :delayed_trips, :delay_percentage, keyword_init: true)

    DEFAULT_GLOB = "data/deutsche_bahn/*.parquet".freeze

    # Schema reference (piebro/deutsche-bahn-data, monthly_processed_data):
    #   train_name              e.g. "ICE 802"
    #   eva                     EVA station number, string
    #   delay_in_min            integer minutes
    #   arrival_planned_time    timestamp (NULL for stops with no arrival, e.g. origin)
    #   is_canceled             bool

    def initialize(parquet_glob: DEFAULT_GLOB, connection: nil)
      @parquet_glob = parquet_glob
      @connection = connection
    end

    def run(train_name:, station_eva:, threshold_minutes:, years_back:)
      results = run_many(
        train_names:       [train_name],
        station_evas:      [station_eva],
        threshold_minutes: threshold_minutes,
        years_back:        years_back
      )
      results.first || Result.new(train_name: train_name.to_s, total_trips: 0, delayed_trips: 0, delay_percentage: nil)
    end

    # Computes delay statistics for one or more trains across one or more
    # stations. Pass either station_eva: (single) or station_evas: (list).
    # Returns an array of Result, ordered by delay_percentage DESC (NULL last).
    def run_many(train_names:, station_eva: nil, station_evas: nil, threshold_minutes:, years_back:)
      names = Array(train_names).map(&:to_s).reject(&:empty?)
      raise ArgumentError, "train_names must not be empty" if names.empty?

      evas = Array(station_evas).map(&:to_s).reject(&:empty?)
      evas = [station_eva.to_s] if evas.empty? && station_eva
      raise ArgumentError, "station_eva or station_evas must be provided" if evas.empty?

      train_placeholders = (["?"] * names.size).join(", ")
      eva_placeholders   = (["?"] * evas.size).join(", ")

      sql = <<~SQL
        SELECT train_name,
               COUNT(*)                                                  AS total_trips,
               COUNT(*) FILTER (WHERE delay_in_min >= ?)                 AS delayed_trips,
               CASE WHEN COUNT(*) = 0 THEN NULL
                    ELSE 100.0 * COUNT(*) FILTER (WHERE delay_in_min >= ?) / COUNT(*)
               END                                                       AS delay_percentage
        FROM read_parquet(?)
        WHERE train_name IN (#{train_placeholders})
          AND eva IN (#{eva_placeholders})
          AND arrival_planned_time IS NOT NULL
          AND is_canceled = FALSE
          AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 YEAR) * ?
        GROUP BY train_name
      SQL

      stmt = connection.prepared_statement(sql)
      binds = [threshold_minutes, threshold_minutes, @parquet_glob, *names, *evas, years_back]
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }

      seen = {}
      stmt.execute.each do |row|
        seen[row[0]] = Result.new(
          train_name:       row[0],
          total_trips:      row[1].to_i,
          delayed_trips:    row[2].to_i,
          delay_percentage: row[3]&.to_f
        )
      end

      # Include zero-row results for trains that had no matching data so the
      # caller can see they were checked.
      names.each do |n|
        seen[n] ||= Result.new(train_name: n, total_trips: 0, delayed_trips: 0, delay_percentage: nil)
      end

      seen.values.sort_by { |r| [r.delay_percentage ? -r.delay_percentage : Float::INFINITY, TrainName.sort_key(r.train_name)] }
    end

    private

    def connection
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
