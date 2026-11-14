COPY (
  SELECT * FROM (VALUES
    -- Berlin long-distance EVA: 2 distinct trains (ride_a ICE, ride_b IC),
    -- ride_a observed twice (polling) so it must dedupe to 1.
    ('Berlin Hbf',     '08011160', 'ICE', 'ride_a'),
    ('Berlin Hbf',     '08011160', 'ICE', 'ride_a'),
    ('Berlin Hbf',     '08011160', 'IC',  'ride_b'),
    -- Berlin S-Bahn EVA: 1 distinct train across multiple observations
    ('Berlin Hbf',     '08089001', 'S',   'ride_c'),
    ('Berlin Hbf',     '08089001', 'S',   'ride_c'),
    ('Munich Hbf',     '08000261', 'ICE', 'ride_d'),
    ('Hamburg Altona', '08002553', 'IC',  'ride_e')
  ) AS t(station_name, eva, train_type, train_line_ride_id)
) TO '__OUT__' (FORMAT PARQUET);
