SELECT CAST(MIN(DATE(COALESCE(departure_planned_time, arrival_planned_time))) AS VARCHAR) AS min_d,
       CAST(MAX(DATE(COALESCE(departure_planned_time, arrival_planned_time))) AS VARCHAR) AS max_d
FROM stop_events
