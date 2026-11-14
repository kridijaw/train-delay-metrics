SELECT eva, station_name, train_type, COUNT(DISTINCT train_line_ride_id) AS rides
FROM read_parquet(__SOURCES__)
WHERE station_name IS NOT NULL
GROUP BY ALL
ORDER BY station_name, eva, train_type
