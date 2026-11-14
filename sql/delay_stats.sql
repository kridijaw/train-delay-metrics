-- total_trips counts only trips that ran, so delay_percentage means "given the
-- train ran, was it late?"; cancellations are reported separately.
SELECT train_name,
       COUNT(*) FILTER (WHERE is_canceled = FALSE)                              AS total_trips,
       COUNT(*) FILTER (WHERE is_canceled = TRUE)                               AS canceled_trips,
       COUNT(*) FILTER (WHERE is_canceled = FALSE AND delay_in_min >= {{threshold}}) AS delayed_trips,
       CAST(
         CASE WHEN COUNT(*) FILTER (WHERE is_canceled = FALSE) = 0 THEN NULL
              ELSE 100.0 * COUNT(*) FILTER (WHERE is_canceled = FALSE AND delay_in_min >= {{threshold}})
                         / COUNT(*) FILTER (WHERE is_canceled = FALSE)
         END AS DOUBLE
       )                                                                        AS delay_percentage
FROM base
GROUP BY train_name
