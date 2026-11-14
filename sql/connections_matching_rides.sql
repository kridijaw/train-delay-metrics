-- Pair stops only when the arrival is within 16 hours of the departure, which
-- handles overnight services without reaching the next day's run of the ride.
, matching_rides AS (
  SELECT DISTINCT a.train_line_ride_id, a.train_name
  FROM stops a JOIN stops b
    ON a.train_line_ride_id = b.train_line_ride_id
   AND b.arr >= a.dep
   AND b.arr <= a.dep + INTERVAL 16 HOUR
  WHERE a.eva IN ({{from_evas*}})
    AND b.eva IN ({{to_evas*}})
    AND a.station_num < b.station_num
    AND a.dep IS NOT NULL
    AND b.arr IS NOT NULL
)
