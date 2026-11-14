-- Trip identity and disruption flag come from the destination (latest arrival
-- per day at any to-EVA), time of day from the origin (latest departure per
-- day at any from-EVA). Days missing either side drop out of the aggregate.
WITH dest AS (
  SELECT train_name,
         CAST(arrival_planned_time AS DATE) AS day,
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
origin AS (
  SELECT train_name,
         CAST(departure_planned_time AS DATE) AS day,
         departure_planned_time
  FROM stop_events
  WHERE train_name IN ({{train_names*}})
    AND eva IN ({{origin_evas*}})
    AND departure_planned_time IS NOT NULL
    AND departure_planned_time >= CAST({{cutoff}} AS DATE)
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
