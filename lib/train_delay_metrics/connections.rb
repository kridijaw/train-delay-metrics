require "duckdb"

module TrainDelayMetrics
  class Connections
    Connection = Struct.new(:train_name, :departure, :arrival, :days, :observations, keyword_init: true)

    DAY_ORDER = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].freeze
    DAY_SHORT = { "Monday"=>"Mon","Tuesday"=>"Tue","Wednesday"=>"Wed","Thursday"=>"Thu","Friday"=>"Fri","Saturday"=>"Sat","Sunday"=>"Sun" }.freeze

    # train_line_ride_id is reused across days for the same scheduled service,
    # so we dedupe per (ride_id, eva, plan_date) and pair stops only when the
    # arrival is within MAX_JOURNEY_HOURS of the departure (handles overnight
    # services without crossing into the next day's run of the same service).
    MAX_JOURNEY_HOURS = 16

    def initialize(parquet_glob:, connection: nil)
      @parquet_glob = parquet_glob
      @connection = connection
    end

    def run(from_eva:, to_eva:, years_back: nil)
      from_evas = Array(from_eva).map(&:to_s).reject(&:empty?)
      to_evas   = Array(to_eva).map(&:to_s).reject(&:empty?)
      raise ArgumentError, "from_eva must not be empty" if from_evas.empty?
      raise ArgumentError, "to_eva must not be empty"   if to_evas.empty?

      all_evas          = from_evas + to_evas
      from_placeholders = (["?"] * from_evas.size).join(", ")
      to_placeholders   = (["?"] * to_evas.size).join(", ")
      all_placeholders  = (["?"] * all_evas.size).join(", ")

      year_filter = years_back ? "AND COALESCE(departure_planned_time, arrival_planned_time) >= CURRENT_DATE - (INTERVAL 1 YEAR) * ?" : ""

      sql = <<~SQL
        WITH stops AS (
          SELECT
            train_line_ride_id,
            eva,
            DATE(COALESCE(departure_planned_time, arrival_planned_time)) AS plan_date,
            any_value(train_name)             AS train_name,
            any_value(train_line_station_num) AS station_num,
            any_value(departure_planned_time) AS dep,
            any_value(arrival_planned_time)   AS arr
          FROM read_parquet(?)
          WHERE eva IN (#{all_placeholders})
            #{year_filter}
          GROUP BY train_line_ride_id, eva, plan_date
        ),
        pairs AS (
          SELECT a.train_name,
                 a.dep AS dep_time,
                 b.arr AS arr_time,
                 dayname(a.dep) AS dow
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
        SELECT train_name,
               strftime(dep_time, '%H:%M') AS dep,
               strftime(arr_time, '%H:%M') AS arr,
               list(DISTINCT dow)          AS days,
               COUNT(*)                    AS observations
        FROM pairs
        GROUP BY train_name, strftime(dep_time, '%H:%M'), strftime(arr_time, '%H:%M')
        ORDER BY dep, train_name;
      SQL

      stmt = connection.prepared_statement(sql)
      binds = [@parquet_glob, *all_evas]
      binds << years_back if years_back
      binds.concat([*from_evas, *to_evas])
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }

      stmt.execute.map do |row|
        days = (row[3] || []).sort_by { |d| DAY_ORDER.index(d) || 99 }.map { |d| DAY_SHORT[d] || d }
        Connection.new(
          train_name:   row[0],
          departure:    row[1],
          arrival:      row[2],
          days:         days,
          observations: row[4].to_i
        )
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

    def connection
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
