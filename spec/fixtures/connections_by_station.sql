COPY (
  SELECT * FROM (VALUES
    -- Long-distance ICE 9 from 105 -> 207, also stops at 207 sibling 098207
    ('ICE 9', 'ICE', 'Frankfurt Hbf', '08000105', 1, TIMESTAMP '2025-02-01 08:00', NULL,                          'ri', FALSE),
    ('ICE 9', 'ICE', 'Köln Hbf',      '08000207', 3, NULL,                          TIMESTAMP '2025-02-01 10:00', 'ri', FALSE),
    -- S 8 from S-Bahn EVAs
    ('S 8',   'S',   'Frankfurt Hbf', '08098105', 1, TIMESTAMP '2025-02-01 08:00', NULL,                          'rs', FALSE),
    ('S 8',   'S',   'Köln Hbf',      '08098207', 3, NULL,                          TIMESTAMP '2025-02-01 09:30', 'rs', FALSE),
    -- FLX excluded by --exclude-types
    ('FLX 1', 'FLX', 'Frankfurt Hbf', '08000105', 1, TIMESTAMP '2025-02-02 11:00', NULL,                          'rf', FALSE),
    ('FLX 1', 'FLX', 'Köln Hbf',      '08000207', 3, NULL,                          TIMESTAMP '2025-02-02 12:00', 'rf', FALSE)
  ) AS t(train_name, train_type, station_name, eva, train_line_station_num, departure_planned_time, arrival_planned_time, train_line_ride_id, is_canceled)
) TO '__OUT__' (FORMAT PARQUET);
