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

    # (Weekday, minute-of-day) window (±30 min within the same weekday) where
    # the train accumulated the most disruptions (delay >= threshold OR
    # canceled). Ranked by absolute disrupted count to avoid single-flier
    # 100% windows; ties broken by rate, then earliest weekday, then earliest
    # minute. weekday is DuckDB's DOW: 0=Sunday..6=Saturday (matches Ruby's
    # Date#wday and indexes DAY_ABBR directly).
    DAY_ABBR = %w[Sun Mon Tue Wed Thu Fri Sat].freeze

    PeakWindow = Struct.new(:weekday, :center_minute, :scheduled, :disrupted, :percentage, keyword_init: true) do
      def center_hhmm
        format("%02d:%02d", center_minute / 60, center_minute % 60)
      end

      def weekday_abbr
        DAY_ABBR[weekday]
      end

      # "Sat 21:31" — weekday + time, the human label for the window center.
      def center_label
        "#{weekday_abbr} #{center_hhmm}"
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

    def run(train_name:, station_eva:, threshold_minutes:, months_back:)
      results = run_many(
        train_names:       [train_name],
        station_evas:      [station_eva],
        threshold_minutes: threshold_minutes,
        months_back:        months_back
      )
      results.first || Result.new(train_name: train_name.to_s, total_trips: 0, canceled_trips: 0, delayed_trips: 0, delay_percentage: nil)
    end

    # Computes delay statistics for one or more trains. Two modes:
    #
    # * Per-stop (default). Pass `station_eva:` or `station_evas:`. Every
    #   matching stop-row counts as one "trip". A run that hits two queried
    #   EVAs in the same day contributes two rows.
    #
    # * Destination-deduplicated. Pass `destination_evas:`. The query
    #   restricts to those EVAs and keeps the *latest* arrival per
    #   (train_name, calendar day) so a single run counts as one trip even
    #   if it stops at multiple destination EVAs on the same day. The
    #   latest arrival is the train's final stop among the destination
    #   EVAs that day — modelling "did the train deliver me to my final
    #   stop on time?" rather than "was its first qualifying stop on
    #   time?". This is what `train-delay --input` uses with the `to`
    #   array.
    #
    # Returns an array of Result, ordered by delay_percentage DESC (NULL
    # last).
    def run_many(train_names:, station_eva: nil, station_evas: nil, destination_evas: nil, threshold_minutes:, months_back:)
      names = Array(train_names).map(&:to_s).reject(&:empty?)
      raise ArgumentError, "train_names must not be empty" if names.empty?

      dest_evas = Array(destination_evas).map(&:to_s).reject(&:empty?)
      if dest_evas.any?
        evas = dest_evas
        dedup_by_day = true
      else
        evas = Array(station_evas).map(&:to_s).reject(&:empty?)
        evas = [station_eva.to_s] if evas.empty? && station_eva
        dedup_by_day = false
      end
      raise ArgumentError, "station_eva, station_evas, or destination_evas must be provided" if evas.empty?

      train_placeholders = (["?"] * names.size).join(", ")
      eva_placeholders   = (["?"] * evas.size).join(", ")

      # total_trips counts only trips that ran (is_canceled = FALSE) so that
      # delay_percentage = delayed_trips / total_trips means "given the train
      # ran, was it late?". canceled_trips is reported alongside as a separate
      # failure mode — it doesn't get folded into the percentage.
      filter_cte = if dedup_by_day
                     # Keep only the latest arrival per (train, day) so a run
                     # touching multiple destination EVAs is counted once,
                     # at its final destination-EVA stop.
                     <<~SQL
                       WITH base AS (
                         SELECT train_name, eva, delay_in_min, is_canceled, arrival_planned_time
                         FROM read_parquet(?)
                         WHERE train_name IN (#{train_placeholders})
                           AND eva IN (#{eva_placeholders})
                           AND arrival_planned_time IS NOT NULL
                           AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 MONTH) * ?
                         QUALIFY ROW_NUMBER() OVER (
                           PARTITION BY train_name, CAST(arrival_planned_time AS DATE)
                           ORDER BY arrival_planned_time DESC, eva DESC
                         ) = 1
                       )
                     SQL
                   else
                     <<~SQL
                       WITH base AS (
                         SELECT train_name, delay_in_min, is_canceled
                         FROM read_parquet(?)
                         WHERE train_name IN (#{train_placeholders})
                           AND eva IN (#{eva_placeholders})
                           AND arrival_planned_time IS NOT NULL
                           AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 MONTH) * ?
                       )
                     SQL
                   end

      sql = filter_cte + <<~SQL
        SELECT train_name,
               COUNT(*) FILTER (WHERE is_canceled = FALSE)                              AS total_trips,
               COUNT(*) FILTER (WHERE is_canceled = TRUE)                               AS canceled_trips,
               COUNT(*) FILTER (WHERE is_canceled = FALSE AND delay_in_min >= ?)        AS delayed_trips,
               CASE WHEN COUNT(*) FILTER (WHERE is_canceled = FALSE) = 0 THEN NULL
                    ELSE 100.0 * COUNT(*) FILTER (WHERE is_canceled = FALSE AND delay_in_min >= ?)
                               / COUNT(*) FILTER (WHERE is_canceled = FALSE)
               END                                                                      AS delay_percentage
        FROM base
        GROUP BY train_name
      SQL

      stmt = connection.prepared_statement(sql)
      binds = [@parquet_glob, *names, *evas, months_back, threshold_minutes, threshold_minutes]
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
    # ±30-minute span around an observed time-of-day minute that contains the
    # greatest number of disruption events.
    #
    # Three modes:
    #
    # * Per-stop (default — no destination_evas, no origin_evas). Time-of-day
    #   is the row's `departure_planned_time` and only rows with one are
    #   considered (origin stops are excluded automatically; terminus stops
    #   have no departure and are also excluded).
    #
    # * Destination-arrival (destination_evas only). Time-of-day is the row's
    #   `arrival_planned_time` (so terminus stops still count). The
    #   per-minute aggregation is over the deduplicated row set — one row
    #   per (train, calendar day) at the latest destination arrival, matching
    #   run_many's tiebreaker.
    #
    # * Origin-departure (destination_evas + origin_evas). Trip identity and
    #   the disruption flag still come from the destination row (matches the
    #   headline counts), but the time-of-day shown is the train's *latest
    #   departure* from any origin EVA on that same day. This is the
    #   passenger-friendly "find the train in the timetable" time. Days
    #   without an origin row in the data drop out of the peak aggregate
    #   (the trip is still counted by run_many, just absent from this view).
    #
    # Trains with no matching rows are absent from the hash. Windows do not
    # wrap across midnight (a 23:50 center sees 23:20–24:00 only); sample
    # sizes there are tiny so this is rarely the peak window in practice.
    def peak_windows(train_names:, station_eva: nil, station_evas: nil, destination_evas: nil, origin_evas: nil, threshold_minutes:, months_back:)
      names = Array(train_names).map(&:to_s).reject(&:empty?)
      raise ArgumentError, "train_names must not be empty" if names.empty?

      dest_evas   = Array(destination_evas).map(&:to_s).reject(&:empty?)
      origin_list = Array(origin_evas).map(&:to_s).reject(&:empty?)

      mode = if dest_evas.any? && origin_list.any?
               :origin_dep
             elsif dest_evas.any?
               :dest_arr
             else
               :per_stop
             end

      if mode == :per_stop
        evas = Array(station_evas).map(&:to_s).reject(&:empty?)
        evas = [station_eva.to_s] if evas.empty? && station_eva
        raise ArgumentError, "station_eva, station_evas, or destination_evas must be provided" if evas.empty?
      end

      train_placeholders = (["?"] * names.size).join(", ")

      base_cte, base_binds = case mode
                             when :origin_dep
                               build_origin_dep_base_cte(train_placeholders, names, dest_evas, origin_list, months_back)
                             when :dest_arr
                               build_dest_arr_base_cte(train_placeholders, names, dest_evas, months_back)
                             else
                               build_per_stop_base_cte(train_placeholders, names, evas, months_back)
                             end

      sql = base_cte + <<~SQL
        per_min AS (
          SELECT train_name,
                 EXTRACT(DOW FROM time_of_day_ts)::INTEGER                                 AS weekday,
                 (EXTRACT(HOUR FROM time_of_day_ts) * 60
                  + EXTRACT(MINUTE FROM time_of_day_ts))::INTEGER                          AS dep_min,
                 COUNT(*)                                                                  AS scheduled,
                 COUNT(*) FILTER (WHERE is_canceled OR delay_in_min >= ?)                  AS disrupted
          FROM base
          GROUP BY train_name, weekday, dep_min
        ),
        windowed AS (
          SELECT a.train_name,
                 a.weekday                AS weekday,
                 a.dep_min                AS center_min,
                 SUM(b.scheduled)         AS w_scheduled,
                 SUM(b.disrupted)         AS w_disrupted
          FROM per_min a
          JOIN per_min b
            ON a.train_name = b.train_name
           AND a.weekday    = b.weekday
           AND b.dep_min BETWEEN a.dep_min - 30 AND a.dep_min + 30
          GROUP BY a.train_name, a.weekday, a.dep_min
        ),
        ranked AS (
          SELECT train_name, weekday, center_min, w_scheduled, w_disrupted,
                 ROW_NUMBER() OVER (
                   PARTITION BY train_name
                   ORDER BY w_disrupted DESC,
                            CASE WHEN w_scheduled = 0 THEN 0
                                 ELSE w_disrupted::DOUBLE / w_scheduled END DESC,
                            weekday    ASC,
                            center_min ASC
                 ) AS rn
          FROM windowed
        )
        SELECT train_name, weekday, center_min, w_scheduled, w_disrupted
        FROM ranked
        WHERE rn = 1
      SQL

      stmt = connection.prepared_statement(sql)
      binds = base_binds + [threshold_minutes]
      binds.each_with_index { |v, i| stmt.bind(i + 1, v) }

      out = {}
      stmt.execute.each do |row|
        sched   = row[3].to_i
        disrupt = row[4].to_i
        out[row[0]] = PeakWindow.new(
          weekday:       row[1].to_i,
          center_minute: row[2].to_i,
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

    def build_per_stop_base_cte(train_placeholders, names, evas, months_back)
      eva_placeholders = (["?"] * evas.size).join(", ")
      cte = <<~SQL
        WITH base AS (
          SELECT train_name,
                 departure_planned_time AS time_of_day_ts,
                 delay_in_min,
                 is_canceled
          FROM read_parquet(?)
          WHERE train_name IN (#{train_placeholders})
            AND eva IN (#{eva_placeholders})
            AND departure_planned_time IS NOT NULL
            AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 MONTH) * ?
        ),
      SQL
      [cte, [@parquet_glob, *names, *evas, months_back]]
    end

    def build_dest_arr_base_cte(train_placeholders, names, dest_evas, months_back)
      eva_placeholders = (["?"] * dest_evas.size).join(", ")
      cte = <<~SQL
        WITH base AS (
          SELECT train_name,
                 arrival_planned_time AS time_of_day_ts,
                 delay_in_min,
                 is_canceled
          FROM read_parquet(?)
          WHERE train_name IN (#{train_placeholders})
            AND eva IN (#{eva_placeholders})
            AND arrival_planned_time IS NOT NULL
            AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 MONTH) * ?
          QUALIFY ROW_NUMBER() OVER (
            PARTITION BY train_name, CAST(arrival_planned_time AS DATE)
            ORDER BY arrival_planned_time DESC, eva DESC
          ) = 1
        ),
      SQL
      [cte, [@parquet_glob, *names, *dest_evas, months_back]]
    end

    # Trip identity + disruption flag from destination (latest arrival per
    # day at any to-EVA); time-of-day from origin (latest departure per day
    # at any from-EVA), joined on (train_name, calendar day). Days where
    # origin or destination row is missing in the data are dropped from the
    # peak aggregate.
    def build_origin_dep_base_cte(train_placeholders, names, dest_evas, origin_evas, months_back)
      dest_eva_placeholders   = (["?"] * dest_evas.size).join(", ")
      origin_eva_placeholders = (["?"] * origin_evas.size).join(", ")
      cte = <<~SQL
        WITH dest AS (
          SELECT train_name,
                 CAST(arrival_planned_time AS DATE) AS day,
                 delay_in_min,
                 is_canceled
          FROM read_parquet(?)
          WHERE train_name IN (#{train_placeholders})
            AND eva IN (#{dest_eva_placeholders})
            AND arrival_planned_time IS NOT NULL
            AND arrival_planned_time >= CURRENT_DATE - (INTERVAL 1 MONTH) * ?
          QUALIFY ROW_NUMBER() OVER (
            PARTITION BY train_name, CAST(arrival_planned_time AS DATE)
            ORDER BY arrival_planned_time DESC, eva DESC
          ) = 1
        ),
        origin AS (
          SELECT train_name,
                 CAST(departure_planned_time AS DATE) AS day,
                 departure_planned_time
          FROM read_parquet(?)
          WHERE train_name IN (#{train_placeholders})
            AND eva IN (#{origin_eva_placeholders})
            AND departure_planned_time IS NOT NULL
            AND departure_planned_time >= CURRENT_DATE - (INTERVAL 1 MONTH) * ?
          QUALIFY ROW_NUMBER() OVER (
            PARTITION BY train_name, CAST(departure_planned_time AS DATE)
            ORDER BY departure_planned_time DESC, eva DESC
          ) = 1
        ),
        base AS (
          SELECT d.train_name,
                 o.departure_planned_time AS time_of_day_ts,
                 d.delay_in_min,
                 d.is_canceled
          FROM dest d
          JOIN origin o
            ON d.train_name = o.train_name
           AND d.day        = o.day
        ),
      SQL
      [cte, [@parquet_glob, *names, *dest_evas, months_back, @parquet_glob, *names, *origin_evas, months_back]]
    end
  end
end
