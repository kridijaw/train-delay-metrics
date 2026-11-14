require_relative "sql"

module TrainDelayMetrics
  class Stations
    Station = Struct.new(:station_name, :eva, :train_types, :trains, keyword_init: true)

    def initialize(parquet_glob:, connection: nil)
      @parquet_glob = parquet_glob
      @connection   = connection
    end

    def run(name_pattern:, train_types: nil)
      types = Array(train_types).map { |t| t.to_s.strip }.reject(&:empty?)

      rows = Sql.query(connection, ["stations"], { name_pattern: name_pattern, train_types: types })

      rows.map do |row|
        Station.new(
          station_name: row[0],
          eva:          row[1],
          train_types:  row[2] || [],
          trains:       row[3].to_i
        )
      end
    end

    private

    def connection
      @connection ||= Sql.connect(@parquet_glob)
    end
  end
end
