per_min AS (
  SELECT train_name,
         EXTRACT(DOW FROM time_of_day_ts)::INTEGER                                 AS weekday,
         (EXTRACT(HOUR FROM time_of_day_ts) * 60
          + EXTRACT(MINUTE FROM time_of_day_ts))::INTEGER                          AS dep_min,
         COUNT(*)                                                                  AS scheduled,
         COUNT(*) FILTER (WHERE is_canceled OR delay_in_min >= {{threshold}})      AS disrupted
  FROM base
  GROUP BY train_name, weekday, dep_min
),
windowed AS (
  SELECT a.train_name,
         a.weekday                AS weekday,
         a.dep_min                AS center_min,
         SUM(b.scheduled)::BIGINT AS w_scheduled,
         SUM(b.disrupted)::BIGINT AS w_disrupted
  FROM per_min a
  JOIN per_min b
    ON a.train_name = b.train_name
   AND a.weekday    = b.weekday
   AND b.dep_min BETWEEN a.dep_min - 30 AND a.dep_min + 30
  GROUP BY a.train_name, a.weekday, a.dep_min
),
ranked AS (
  SELECT train_name, weekday, center_min, w_scheduled, w_disrupted,
         ROW_NUMBER() OVER (
           PARTITION BY train_name
           ORDER BY w_disrupted DESC,
                    CASE WHEN w_scheduled = 0 THEN 0
                         ELSE w_disrupted::DOUBLE / w_scheduled END DESC,
                    weekday    ASC,
                    center_min ASC
         ) AS rn
  FROM windowed
)
SELECT train_name, weekday, center_min, w_scheduled, w_disrupted
FROM ranked
WHERE rn = 1
