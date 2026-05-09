require "duckdb"

module TrainDelayMetrics
  class Connections
    # train_line_ride_id is reused across days for the same scheduled service,
    # so we dedupe per (ride_id, eva, plan_date) and pair stops only when the
    # arrival is within MAX_JOURNEY_HOURS of the departure (handles overnight
    # services without crossing into the next day's run of the same service).
    MAX_JOURNEY_HOURS = 16

    def initialize(parquet_glob:, connection: nil)
      @parquet_glob = parquet_glob
      @connection = connection
    end

    StationTrains = Struct.new(:eva, :station_name, :trains, keyword_init: true)

    # For each EVA in the union of from_eva/to_eva, returns the list of
    # train_names (alphabetically sorted) that touch that EVA *and* connect
    # any from-EVA to any to-EVA in the configured window.
    def trains_by_station(from_eva:, to_eva:, years_back: nil, exclude_types: nil)
      sql, binds = build_sql(from_eva: from_eva, to_eva: to_eva, years_back: years_back, exclude_types: exclude_types, select: :by_station)
      stmt = bind(connection.prepared_statement(sql), binds)
      stmt.execute.map do |row|
        sorted = (row[2] || []).sort_by { |n| TrainName.sort_key(n) }
        StationTrains.new(eva: row[0], station_name: row[1], trains: sorted)
      end
    end

    TrainCoverage = Struct.new(:train_name, :evas, keyword_init: true)

    # For each connecting train_name, returns the sorted list of from/to EVAs
    # it ever stops at across the window. Useful for bucketing trains by which
    # combination of stops they cover.
    def train_coverage(from_eva:, to_eva:, years_back: nil, exclude_types: nil)
      sql, binds = build_sql(from_eva: from_eva, to_eva: to_eva, years_back: years_back, exclude_types: exclude_types, select: :coverage)
      stmt = bind(connection.prepared_statement(sql), binds)
      stmt.execute.map do |row|
        TrainCoverage.new(train_name: row[0], evas: row[1] || [])
      end
    end

    # Returns [min_date, max_date] (Date objects) of the planned timestamps
    # in the parquet glob, or [nil, nil] if there is no data.
    def data_date_range
      stmt = connection.prepared_statement(<<~SQL)
        SELECT MIN(DATE(COALESCE(departure_planned_time, arrival_planned_time))) AS min_d,
               MAX(DATE(COALESCE(departure_planned_time, arrival_planned_time))) AS max_d
        FROM read_parquet(?)
      SQL
      stmt.bind(1, @parquet_glob)
      row = stmt.execute.first
      [row[0], row[1]]
    end

    private

    def build_sql(from_eva:, to_eva:, years_back:, exclude_types:, select:)
      from_evas = Array(from_eva).map(&:to_s).reject(&:empty?)
      to_evas   = Array(to_eva).map(&:to_s).reject(&:empty?)
      excluded  = Array(exclude_types).map { |t| t.to_s.strip }.reject(&:empty?).map(&:upcase)
      raise ArgumentError, "from_eva must not be empty" if from_evas.empty?
      raise ArgumentError, "to_eva must not be empty"   if to_evas.empty?

      all_evas          = from_evas + to_evas
      from_placeholders = (["?"] * from_evas.size).join(", ")
      to_placeholders   = (["?"] * to_evas.size).join(", ")
      all_placeholders  = (["?"] * all_evas.size).join(", ")
      excl_placeholders = (["?"] * excluded.size).join(", ")

      year_filter    = years_back ? "AND COALESCE(departure_planned_time, arrival_planned_time) >= CURRENT_DATE - (INTERVAL 1 YEAR) * ?" : ""
      exclude_filter = excluded.empty? ? "" : "AND (train_type IS NULL OR UPPER(train_type) NOT IN (#{excl_placeholders}))"

      outer = case select
              when :by_station
                <<~SQL
                  , matching_rides AS (
                    SELECT DISTINCT a.train_line_ride_id, a.train_name
                    FROM stops a JOIN stops b
                      ON a.train_line_ride_id = b.train_line_ride_id
                     AND b.arr >= a.dep
                     AND b.arr <= a.dep + INTERVAL #{MAX_JOURNEY_HOURS} HOUR
                    WHERE a.eva IN (#{from_placeholders})
                      AND b.eva IN (#{to_placeholders})
                      AND a.station_num < b.station_num
                      AND a.dep IS NOT NULL
                      AND b.arr IS NOT NULL
                  )
                  SELECT s.eva,
                         any_value(s.station_name)                   AS station_name,
                         list(DISTINCT m.train_name ORDER BY m.train_name) AS trains
                  FROM stops s JOIN matching_rides m USING (train_line_ride_id)
                  GROUP BY s.eva
                  ORDER BY s.eva;
                SQL
              when :coverage
                <<~SQL
                  , matching_rides AS (
                    SELECT DISTINCT a.train_line_ride_id, a.train_name
                    FROM stops a JOIN stops b
                      ON a.train_line_ride_id = b.train_line_ride_id
                     AND b.arr >= a.dep
                     AND b.arr <= a.dep + INTERVAL #{MAX_JOURNEY_HOURS} HOUR
                    WHERE a.eva IN (#{from_placeholders})
                      AND b.eva IN (#{to_placeholders})
                      AND a.station_num < b.station_num
                      AND a.dep IS NOT NULL
                      AND b.arr IS NOT NULL
                  )
                  SELECT m.train_name,
                         list(DISTINCT s.eva ORDER BY s.eva) AS evas
                  FROM stops s JOIN matching_rides m USING (train_line_ride_id)
                  GROUP BY m.train_name
                  ORDER BY m.train_name;
                SQL
              else
                raise ArgumentError, "unknown select #{select.inspect}"
              end

      sql = <<~SQL
        WITH stops AS (
          SELECT
            train_line_ride_id,
            eva,
            DATE(COALESCE(departure_planned_time, arrival_planned_time)) AS plan_date,
            any_value(train_name)             AS train_name,
            #{select == :by_station ? "any_value(station_name)           AS station_name," : ""}
            any_value(train_line_station_num) AS station_num,
            any_value(departure_planned_time) AS dep,
            any_value(arrival_planned_time)   AS arr
          FROM read_parquet(?)
          WHERE eva IN (#{all_placeholders})
            #{year_filter}
            #{exclude_filter}
          GROUP BY train_line_ride_id, eva, plan_date
        )
        #{outer}
      SQL

      binds = [@parquet_glob, *all_evas]
      binds << years_back if years_back
      binds.concat(excluded)
      binds.concat([*from_evas, *to_evas])
      [sql, binds]
    end

    def bind(stmt, binds)
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }
      stmt
    end

    def connection
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
