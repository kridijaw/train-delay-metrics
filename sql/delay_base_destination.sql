-- Keep only the latest arrival per (train, day) so a run touching several
-- destination EVAs counts once, at its final destination-EVA stop.
WITH base AS (
  SELECT train_name, eva, delay_in_min, is_canceled, arrival_planned_time
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
)
