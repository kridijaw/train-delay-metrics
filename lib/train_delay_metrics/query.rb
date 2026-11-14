require_relative "sql"

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

      base = dedup_by_day ? "delay_base_destination" : "delay_base_per_stop"
      rows = Sql.query(connection, [base, "delay_stats"], {
        train_names: names,
        evas:        evas,
        cutoff:      Sql.cutoff(months_back),
        threshold:   threshold_minutes
      })

      seen = {}
      rows.each do |row|
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

      rows = Sql.query(connection, ["peak_base_#{mode}", "peak_windows"], {
        train_names: names,
        evas:        mode == :per_stop ? evas : dest_evas,
        origin_evas: origin_list,
        cutoff:      Sql.cutoff(months_back),
        threshold:   threshold_minutes
      })

      out = {}
      rows.each do |row|
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
      @connection ||= Sql.connect(@parquet_glob)
    end
  end
end
