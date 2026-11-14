-- train_line_ride_id is reused across days for the same scheduled service, so
-- stops are deduped per (ride, eva, plan_date).
WITH stops AS (
  SELECT
    train_line_ride_id,
    eva,
    DATE(COALESCE(departure_planned_time, arrival_planned_time)) AS plan_date,
    any_value(train_name)             AS train_name,
    any_value(station_name)           AS station_name,
    any_value(train_line_station_num) AS station_num,
    any_value(departure_planned_time) AS dep,
    any_value(arrival_planned_time)   AS arr
  FROM stop_events
  WHERE eva IN ({{all_evas*}})
    {{#cutoff}}AND COALESCE(departure_planned_time, arrival_planned_time) >= CAST({{cutoff}} AS DATE){{/cutoff}}
    {{#exclude_types}}AND (train_type IS NULL OR UPPER(train_type) NOT IN ({{exclude_types*}})){{/exclude_types}}
  GROUP BY train_line_ride_id, eva, plan_date
)
