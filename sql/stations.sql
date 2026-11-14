SELECT station_name,
       eva,
       list(DISTINCT train_type ORDER BY train_type) AS train_types,
       COUNT(DISTINCT train_line_ride_id) AS trains
FROM stop_events
WHERE station_name ILIKE {{name_pattern}}
  {{#train_types}}AND train_type IN ({{train_types*}}){{/train_types}}
GROUP BY station_name, eva
ORDER BY station_name, trains DESC
