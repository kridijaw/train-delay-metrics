SELECT m.train_name,
       list(DISTINCT s.eva ORDER BY s.eva) AS evas
FROM stops s JOIN matching_rides m USING (train_line_ride_id)
GROUP BY m.train_name
ORDER BY m.train_name
