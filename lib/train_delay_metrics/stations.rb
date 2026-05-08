require "duckdb"

module TrainDelayMetrics
  class Stations
    Station = Struct.new(:station_name, :eva, :train_types, :trains, keyword_init: true)

    def initialize(parquet_glob:, connection: nil)
      @parquet_glob = parquet_glob
      @connection   = connection
    end

    def run(name_pattern:, train_types: nil)
      types = Array(train_types).map { |t| t.to_s.strip }.reject(&:empty?)

      sql = +<<~SQL
        SELECT station_name,
               eva,
               list(DISTINCT train_type ORDER BY train_type) AS train_types,
               COUNT(DISTINCT train_line_ride_id) AS trains
        FROM read_parquet(?)
        WHERE station_name ILIKE ?
      SQL
      binds = [@parquet_glob, name_pattern]

      unless types.empty?
        sql << "  AND train_type IN (#{(['?'] * types.size).join(', ')})\n"
        binds.concat(types)
      end

      sql << "GROUP BY station_name, eva\nORDER BY station_name, trains DESC;"

      stmt = connection.prepared_statement(sql)
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }

      stmt.execute.map do |row|
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
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
