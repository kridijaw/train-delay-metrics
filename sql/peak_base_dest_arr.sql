WITH base AS (
  SELECT train_name,
         arrival_planned_time AS time_of_day_ts,
         delay_in_min,
         is_canceled
  FROM stop_events
  WHERE train_name IN ({{train_names*}})
    AND eva IN ({{evas*}})
    AND arrival_planned_time IS NOT NULL
    AND arrival_planned_time >= CAST({{cutoff}} AS DATE)
  -- Coupled portions sharing a generic name (e.g. "NJ") tie here: the worst outcome wins.
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY train_name, CAST(arrival_planned_time AS DATE)
    ORDER BY arrival_planned_time DESC, eva DESC,
             is_canceled DESC NULLS LAST, delay_in_min DESC NULLS LAST
  ) = 1
),
