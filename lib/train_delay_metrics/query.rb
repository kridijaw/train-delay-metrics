require "duckdb"

module TrainDelayMetrics
  class Query
    Result = Struct.new(:total_trips, :delayed_trips, :delay_percentage, keyword_init: true)

    DEFAULT_GLOB = "data/deutsche_bahn/*.parquet".freeze

    # Schema reference (piebro/deutsche-bahn-data, monthly_processed_data):
    #   train_name              e.g. "ICE 802"
    #   eva                     EVA station number, string
    #   delay_in_min            integer minutes
    #   arrival_planned_time    timestamp (NULL for stops with no arrival, e.g. origin)
    #   is_canceled             bool
    SQL = <<~SQL.freeze
      SELECT
        COUNT(*)                                                       AS total_trips,
        COUNT(*) FILTER (WHERE delay_in_min >= ?)                      AS delayed_trips,
        CASE WHEN COUNT(*) = 0 THEN NULL
             ELSE 100.0 * COUNT(*) FILTER (WHERE delay_in_min >= ?) / COUNT(*)
        END                                                            AS delay_percentage
      FROM read_parquet(?)
      WHERE train_name = ?
        AND eva = ?
        AND arrival_planned_time IS NOT NULL
        AND is_canceled = FALSE
        AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 YEAR) * ?
    SQL

    def initialize(parquet_glob: DEFAULT_GLOB, connection: nil)
      @parquet_glob = parquet_glob
      @connection = connection
    end

    def run(train_name:, station_eva:, threshold_minutes:, years_back:)
      stmt = connection.prepared_statement(SQL)
      stmt.bind(1, threshold_minutes)
      stmt.bind(2, threshold_minutes)
      stmt.bind(3, @parquet_glob)
      stmt.bind(4, train_name.to_s)
      stmt.bind(5, station_eva.to_s)
      stmt.bind(6, years_back)

      row = stmt.execute.first
      Result.new(
        total_trips:      row[0].to_i,
        delayed_trips:    row[1].to_i,
        delay_percentage: row[2]&.to_f
      )
    end

    private

    def connection
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
