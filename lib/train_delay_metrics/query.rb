require "duckdb"

module TrainDelayMetrics
  class Query
    Result = Struct.new(:train_name, :total_trips, :canceled_trips, :delayed_trips, :delay_percentage, keyword_init: true) do
      # Share of *scheduled* trips that either ran late or were canceled.
      # Denominator is total_trips + canceled_trips (i.e. everything that was
      # supposed to run); numerator counts both failure modes.
      def delay_or_cancel_percentage
        scheduled = total_trips + canceled_trips
        return nil if scheduled.zero?
        100.0 * (delayed_trips + canceled_trips) / scheduled
      end
    end

    # Time-of-day window (centered on a departure minute, ±30 min) where the
    # train accumulated the most disruptions (delay >= threshold OR canceled).
    # Ranked by absolute disrupted count to avoid single-flier 100% windows;
    # ties broken by rate, then earliest center.
    PeakWindow = Struct.new(:center_minute, :scheduled, :disrupted, :percentage, keyword_init: true) do
      def center_hhmm
        format("%02d:%02d", center_minute / 60, center_minute % 60)
      end
    end

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
      results.first || Result.new(train_name: train_name.to_s, total_trips: 0, canceled_trips: 0, delayed_trips: 0, delay_percentage: nil)
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

      # total_trips counts only trips that ran (is_canceled = FALSE) so that
      # delay_percentage = delayed_trips / total_trips means "given the train
      # ran, was it late?". canceled_trips is reported alongside as a separate
      # failure mode — it doesn't get folded into the percentage.
      sql = <<~SQL
        SELECT train_name,
               COUNT(*) FILTER (WHERE is_canceled = FALSE)                              AS total_trips,
               COUNT(*) FILTER (WHERE is_canceled = TRUE)                               AS canceled_trips,
               COUNT(*) FILTER (WHERE is_canceled = FALSE AND delay_in_min >= ?)        AS delayed_trips,
               CASE WHEN COUNT(*) FILTER (WHERE is_canceled = FALSE) = 0 THEN NULL
                    ELSE 100.0 * COUNT(*) FILTER (WHERE is_canceled = FALSE AND delay_in_min >= ?)
                               / COUNT(*) FILTER (WHERE is_canceled = FALSE)
               END                                                                      AS delay_percentage
        FROM read_parquet(?)
        WHERE train_name IN (#{train_placeholders})
          AND eva IN (#{eva_placeholders})
          AND arrival_planned_time IS NOT NULL
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
          canceled_trips:   row[2].to_i,
          delayed_trips:    row[3].to_i,
          delay_percentage: row[4]&.to_f
        )
      end

      # Include zero-row results for trains that had no matching data so the
      # caller can see they were checked.
      names.each do |n|
        seen[n] ||= Result.new(train_name: n, total_trips: 0, canceled_trips: 0, delayed_trips: 0, delay_percentage: nil)
      end

      seen.values.sort_by { |r| [r.delay_percentage ? -r.delay_percentage : Float::INFINITY, TrainName.sort_key(r.train_name)] }
    end

    # Returns { train_name => PeakWindow }. For each train, the window is the
    # ±30-minute span around an observed departure minute that contains the
    # greatest number of disruption events. Trains with no data — or with no
    # rows that have departure_planned_time at the queried EVA — are absent
    # from the hash. Windows do not wrap across midnight (a 23:50 center sees
    # 23:20–24:00 only); sample sizes there are tiny so this is rarely the
    # peak window in practice.
    def peak_windows(train_names:, station_eva: nil, station_evas: nil, threshold_minutes:, years_back:)
      names = Array(train_names).map(&:to_s).reject(&:empty?)
      raise ArgumentError, "train_names must not be empty" if names.empty?

      evas = Array(station_evas).map(&:to_s).reject(&:empty?)
      evas = [station_eva.to_s] if evas.empty? && station_eva
      raise ArgumentError, "station_eva or station_evas must be provided" if evas.empty?

      train_placeholders = (["?"] * names.size).join(", ")
      eva_placeholders   = (["?"] * evas.size).join(", ")

      sql = <<~SQL
        WITH per_min AS (
          SELECT train_name,
                 (EXTRACT(HOUR FROM departure_planned_time) * 60
                  + EXTRACT(MINUTE FROM departure_planned_time))::INTEGER AS dep_min,
                 COUNT(*)                                                                  AS scheduled,
                 COUNT(*) FILTER (WHERE is_canceled OR delay_in_min >= ?)                  AS disrupted
          FROM read_parquet(?)
          WHERE train_name IN (#{train_placeholders})
            AND eva IN (#{eva_placeholders})
            AND departure_planned_time IS NOT NULL
            AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 YEAR) * ?
          GROUP BY train_name, dep_min
        ),
        windowed AS (
          SELECT a.train_name,
                 a.dep_min                AS center_min,
                 SUM(b.scheduled)         AS w_scheduled,
                 SUM(b.disrupted)         AS w_disrupted
          FROM per_min a
          JOIN per_min b
            ON a.train_name = b.train_name
           AND b.dep_min BETWEEN a.dep_min - 30 AND a.dep_min + 30
          GROUP BY a.train_name, a.dep_min
        ),
        ranked AS (
          SELECT train_name, center_min, w_scheduled, w_disrupted,
                 ROW_NUMBER() OVER (
                   PARTITION BY train_name
                   ORDER BY w_disrupted DESC,
                            CASE WHEN w_scheduled = 0 THEN 0
                                 ELSE w_disrupted::DOUBLE / w_scheduled END DESC,
                            center_min ASC
                 ) AS rn
          FROM windowed
        )
        SELECT train_name, center_min, w_scheduled, w_disrupted
        FROM ranked
        WHERE rn = 1
      SQL

      stmt = connection.prepared_statement(sql)
      binds = [threshold_minutes, @parquet_glob, *names, *evas, years_back]
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }

      out = {}
      stmt.execute.each do |row|
        sched = row[2].to_i
        disrupt = row[3].to_i
        out[row[0]] = PeakWindow.new(
          center_minute: row[1].to_i,
          scheduled:     sched,
          disrupted:     disrupt,
          percentage:    sched.zero? ? nil : 100.0 * disrupt / sched
        )
      end
      out
    end

    private

    def connection
      @connection ||= DuckDB::Database.new.connect
    end
  end
end
