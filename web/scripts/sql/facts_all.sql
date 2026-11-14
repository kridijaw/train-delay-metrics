COPY (
  SELECT train_name,
         train_type,
         station_name,
         eva,
         CAST(train_line_ride_id AS BIGINT)       AS train_line_ride_id,
         CAST(train_line_station_num AS SMALLINT) AS train_line_station_num,
         CAST(delay_in_min AS SMALLINT)           AS delay_in_min,
         is_canceled,
         CAST(arrival_planned_time AS TIMESTAMP)   AS arrival_planned_time,
         CAST(departure_planned_time AS TIMESTAMP) AS departure_planned_time,
         COALESCE(TRY_CAST(eva AS INTEGER), 0) % 256 AS bucket
  FROM read_parquet(__SOURCES__)
  ORDER BY train_name, eva, arrival_planned_time
) TO __OUT__ (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 50000, PARQUET_VERSION V1, PARTITION_BY (bucket), FILENAME_PATTERN 'part')
