COPY (
  SELECT * FROM (VALUES
    -- ICE 9 stops at both from-EVAs and one to-EVA
    ('ICE 9', 'ICE', 'A', '08000001', 1, TIMESTAMP '2025-03-01 08:00', NULL,                          'r1', FALSE),
    ('ICE 9', 'ICE', 'A', '08000002', 2, TIMESTAMP '2025-03-01 08:05', NULL,                          'r1', FALSE),
    ('ICE 9', 'ICE', 'B', '08000003', 4, NULL,                          TIMESTAMP '2025-03-01 10:00', 'r1', FALSE),
    -- ICE 7 stops at only one from-EVA and one to-EVA
    ('ICE 7', 'ICE', 'A', '08000001', 1, TIMESTAMP '2025-03-02 08:00', NULL,                          'r2', FALSE),
    ('ICE 7', 'ICE', 'B', '08000004', 4, NULL,                          TIMESTAMP '2025-03-02 10:00', 'r2', FALSE)
  ) AS t(train_name, train_type, station_name, eva, train_line_station_num, departure_planned_time, arrival_planned_time, train_line_ride_id, is_canceled)
) TO '__OUT__' (FORMAT PARQUET);
