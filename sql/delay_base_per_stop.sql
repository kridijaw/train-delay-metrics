WITH base AS (
  SELECT train_name, delay_in_min, is_canceled
  FROM stop_events
  WHERE train_name IN ({{train_names*}})
    AND eva IN ({{evas*}})
    AND arrival_planned_time IS NOT NULL
    AND arrival_planned_time >= CAST({{cutoff}} AS DATE)
)
