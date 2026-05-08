require "duckdb"

module TrainDelayMetrics
  class Stations
    Station = Struct.new(:station_name, :eva, :train_types, :rows, keyword_init: true)

    SQL = <<~SQL.freeze
      SELECT station_name,
             eva,
             list(DISTINCT train_type ORDER BY train_type) AS train_types,
             COUNT(*) AS rows
      FROM read_parquet(?)
      WHERE station_name ILIKE ?
      GROUP BY station_name, eva
      ORDER BY station_name, rows DESC;
    SQL

    def initialize(parquet_glob:, connection: nil)
      @parquet_glob = parquet_glob
      @connection   = connection
    end

    def run(name_pattern:)
      stmt = connection.prepared_statement(SQL)
      stmt.bind(1, @parquet_glob)
      stmt.bind(2, name_pattern)

      stmt.execute.map do |row|
        Station.new(
          station_name: row[0],
          eva:          row[1],
          train_types:  row[2] || [],
          rows:         row[3].to_i
        )
      end
    end

    private

    def connection
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
