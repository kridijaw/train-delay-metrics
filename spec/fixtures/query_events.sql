-- Recent arrivals of "ICE 802" at EVA 8000105:
--   3 with delay_in_min >= 20, 2 below.
-- Plus rows that should be excluded:
--   - different train, different eva, no arrival time, canceled, too old.
COPY (
  SELECT
    col0 AS train_name,
    col1 AS eva,
    col2 AS delay_in_min,
    col3 AS arrival_planned_time,
    col4 AS is_canceled,
    col5 AS departure_planned_time
  FROM (VALUES
    -- All ICE 802 runs at this EVA depart at 09:14, on different days.
    ('ICE 802', '8000105', 25, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
    ('ICE 802', '8000105', 30, (CURRENT_DATE - INTERVAL  60 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  60 DAY) + INTERVAL '09:14:00'),
    ('ICE 802', '8000105', 20, (CURRENT_DATE - INTERVAL 200 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 200 DAY) + INTERVAL '09:14:00'),
    ('ICE 802', '8000105',  5, (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '09:14:00'),
    ('ICE 802', '8000105',  0, (CURRENT_DATE - INTERVAL  30 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  30 DAY) + INTERVAL '09:14:00'),
    -- ICE 999: one delayed trip (always delayed) → 100% delay rate
    ('ICE 999', '8000105', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00'),
    -- ICE 555: one trip, never delayed → 0%
    ('ICE 555', '8000105',  2, (CURRENT_DATE - INTERVAL   5 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL   5 DAY) + INTERVAL '12:00:00'),
    -- ICE 333: only ever canceled → total_trips=0, canceled_trips=2
    ('ICE 333', '8000105',  0, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00', TRUE,  (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '12:00:00'),
    ('ICE 333', '8000105',  0, (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '12:00:00', TRUE,  (CURRENT_DATE - INTERVAL  20 DAY) + INTERVAL '12:00:00'),
    -- ICE 777: peak-window fixture. 4 always-delayed runs at 09:14
    -- and 4 always-on-time runs at 17:00, all spaced one week apart so
    -- they share the same weekday. Peak window must be 09:14 / 100%
    -- on the weekday matching (CURRENT_DATE - 7 DAY).
    ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '09:14:00'),
    ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '09:14:00'),
    ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '09:14:00'),
    ('ICE 777', '8000105', 30, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '09:14:00'),
    ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '17:00:00'),
    ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '17:00:00'),
    ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL 21 DAY) + INTERVAL '17:00:00'),
    ('ICE 777', '8000105',  0, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '17:00:00', FALSE, (CURRENT_DATE - INTERVAL 28 DAY) + INTERVAL '17:00:00'),
    ('ICE 802', '8000001', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
    ('ICE 802', '8000105', 99, NULL,                                                    FALSE, NULL),
    ('ICE 802', '8000105', 99, (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00', TRUE,  (CURRENT_DATE - INTERVAL  10 DAY) + INTERVAL '09:14:00'),
    ('ICE 802', '8000105', 99, (CURRENT_DATE - INTERVAL 4 YEAR ) + INTERVAL '09:14:00', FALSE, (CURRENT_DATE - INTERVAL 4 YEAR ) + INTERVAL '09:14:00'),
    -- ICE 444: tests destination_evas dedup. Two destination EVAs
    -- (8000900, 8000901). Both fixture days are on the same weekday
    -- (one week apart) so the peak-window weekday assertion is
    -- deterministic. Day 1: arrives 8000900 first at 12:00 (delay 5
    -- min, on time), then 8000901 at 12:30 (delay 25 min, late).
    -- Day 2: only 8000900 (delay 30 min). Per-stop count would be 3
    -- trips / 2 delayed; dedup picks the LATEST arrival per day so
    -- it's 2 trips / 2 delayed.
    ('ICE 444', '8000900',  5, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:00:00'),
    ('ICE 444', '8000901', 25, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:30:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '12:30:00'),
    ('ICE 444', '8000900', 30, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '12:00:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '12:00:00'),
    -- Matching origin rows for ICE 444 at 8000800, departing at 11:00
    -- on each of the two destination days. With origin_evas=[8000800]
    -- and destination_evas=[8000900,8000901] the peak window picks up
    -- 11:00 (origin departure) instead of 12:00 (destination arrival).
    ('ICE 444', '8000800',  0, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '10:55:00', FALSE, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '11:00:00'),
    ('ICE 444', '8000800',  0, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '10:55:00', FALSE, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '11:00:00'),
    -- NJ: coupled portions under one generic name, tied on arrival time and
    -- EVA. Day 1: one runs on time, one is canceled. Day 2: 10 and 30 min.
    -- The destination dedup keeps the worst portion: 1 trip, 1 canceled,
    -- 1 delayed.
    ('NJ', '8000950',  0, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '22:23:00', FALSE, NULL),
    ('NJ', '8000950',  0, (CURRENT_DATE - INTERVAL  7 DAY) + INTERVAL '22:23:00', TRUE,  NULL),
    ('NJ', '8000950', 10, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '22:23:00', FALSE, NULL),
    ('NJ', '8000950', 30, (CURRENT_DATE - INTERVAL 14 DAY) + INTERVAL '22:23:00', FALSE, NULL)
  )
) TO '__OUT__' (FORMAT PARQUET);
