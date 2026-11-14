SELECT s.eva,
       any_value(s.station_name)                         AS station_name,
       list(DISTINCT m.train_name ORDER BY m.train_name) AS trains
FROM stops s JOIN matching_rides m USING (train_line_ride_id)
GROUP BY s.eva
ORDER BY s.eva
