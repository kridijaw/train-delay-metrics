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
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY train_name, CAST(arrival_planned_time AS DATE)
    ORDER BY arrival_planned_time DESC, eva DESC
  ) = 1
),
