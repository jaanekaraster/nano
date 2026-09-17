-- From raw statewise parquet file, 
-- extract pincode and NIC5DigitId from Activities JSON array, 
-- count occurrences of each NIC5DigitId per pincode, 
-- and save the result to a new parquet file.

-- Next steps: Add a column for Name by joining with NIC reference table.

COPY (
    WITH source AS (
        SELECT
            Pincode,
            Activities,
            json_valid(Activities) AS is_valid
        FROM 'data/raw/MAHARASHTRA.parquet'
        WHERE Pincode IS NOT NULL
          AND Activities IS NOT NULL
          AND Activities <> 'NA'
    ),

    valid_activities AS (
        SELECT
            Pincode,
            json_extract_string(a.value, '$.NIC5DigitId') AS nic5_id
        FROM source,
             LATERAL json_each(Activities) AS a
        WHERE is_valid
    ),

    invalid_activities AS (
        SELECT
            Pincode,
            unnest(
                regexp_extract_all(
                    Activities,
                    '"NIC5DigitId":"([^"]+)"',
                    1
                )
            ) AS nic5_id
        FROM source
        WHERE NOT is_valid
    ),

    all_activities AS (
        SELECT * FROM valid_activities
        UNION ALL
        SELECT * FROM invalid_activities
    )

    SELECT
        CAST(Pincode AS BIGINT) AS pincode,
        nic5_id,
        COUNT(*) AS activity_count
    FROM all_activities
    WHERE nic5_id IS NOT NULL
      AND nic5_id <> ''
    GROUP BY
        pincode,
        nic5_id
    ORDER BY
        pincode,
        activity_count DESC
)
TO 'data/udyam/pincode_nic_counts_mh.parquet'
(FORMAT PARQUET);
