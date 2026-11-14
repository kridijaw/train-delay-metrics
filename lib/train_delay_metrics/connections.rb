require "date"
require_relative "sql"

module TrainDelayMetrics
  class Connections
    # train_line_ride_id is reused across days for the same scheduled service,
    # so we dedupe per (ride_id, eva, plan_date) and pair stops only when the
    # arrival is within MAX_JOURNEY_HOURS of the departure (handles overnight
    # services without crossing into the next day's run of the same service).
    # Hardcoded as INTERVAL 16 HOUR in sql/connections_matching_rides.sql.
    MAX_JOURNEY_HOURS = 16

    def initialize(parquet_glob:, connection: nil)
      @parquet_glob = parquet_glob
      @connection = connection
    end

    StationTrains = Struct.new(:eva, :station_name, :trains, keyword_init: true)

    # For each EVA in the union of from_eva/to_eva, returns the list of
    # train_names (alphabetically sorted) that touch that EVA *and* connect
    # any from-EVA to any to-EVA in the configured window.
    def trains_by_station(from_eva:, to_eva:, months_back: nil, exclude_types: nil)
      params = connection_params(from_eva: from_eva, to_eva: to_eva, months_back: months_back, exclude_types: exclude_types)
      Sql.query(connection, %w[connections_stops connections_matching_rides connections_by_station], params).map do |row|
        sorted = (row[2] || []).sort_by { |n| TrainName.sort_key(n) }
        StationTrains.new(eva: row[0], station_name: row[1], trains: sorted)
      end
    end

    TrainCoverage = Struct.new(:train_name, :evas, keyword_init: true)

    # For each connecting train_name, returns the sorted list of from/to EVAs
    # it ever stops at across the window. Useful for bucketing trains by which
    # combination of stops they cover.
    def train_coverage(from_eva:, to_eva:, months_back: nil, exclude_types: nil)
      params = connection_params(from_eva: from_eva, to_eva: to_eva, months_back: months_back, exclude_types: exclude_types)
      Sql.query(connection, %w[connections_stops connections_matching_rides connections_coverage], params).map do |row|
        TrainCoverage.new(train_name: row[0], evas: row[1] || [])
      end
    end

    # Returns [min_date, max_date] (Date objects) of the planned timestamps
    # in the parquet glob, or [nil, nil] if there is no data.
    def data_date_range
      row = Sql.query(connection, ["data_date_range"], {}).first
      [row[0] && Date.iso8601(row[0]), row[1] && Date.iso8601(row[1])]
    end

    private

    def connection_params(from_eva:, to_eva:, months_back:, exclude_types:)
      from_evas = Array(from_eva).map(&:to_s).reject(&:empty?)
      to_evas   = Array(to_eva).map(&:to_s).reject(&:empty?)
      excluded  = Array(exclude_types).map { |t| t.to_s.strip }.reject(&:empty?).map(&:upcase)
      raise ArgumentError, "from_eva must not be empty" if from_evas.empty?
      raise ArgumentError, "to_eva must not be empty"   if to_evas.empty?

      {
        all_evas:      from_evas + to_evas,
        cutoff:        Sql.cutoff(months_back),
        exclude_types: excluded,
        from_evas:     from_evas,
        to_evas:       to_evas
      }
    end

    def connection
      @connection ||= Sql.connect(@parquet_glob)
    end
  end
end
