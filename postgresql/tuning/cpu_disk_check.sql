WITH v AS (
  SELECT query_id,
         sum(calls)                              AS cagri,
         sum(total_time)                         AS toplam_ms,
         max(max_time)                           AS en_kotu_ms,
         sum(rows)                               AS satir,
         sum(shared_blks_hit + shared_blks_read) AS blk_erisim,
         sum(shared_blks_read)                   AS disk_blk,
         sum(blk_read_time + blk_write_time)     AS io_ms,
         sum(temp_blks_read + temp_blks_written) AS temp_blk,
         max(query_sql_text)                     AS sorgu
  FROM query_store.qs_view
  WHERE start_time >= timestamp '2026-09-02 10:30:00' AT TIME ZONE 'Europe/Istanbul'
    AND start_time <  timestamp '2026-09-09 10:30:00' AT TIME ZONE 'Europe/Istanbul'
    AND is_system_query = false
  GROUP BY query_id
)
SELECT query_id,
       cagri,
       round((cagri/7.0)::numeric, 0)                                     AS cagri_gun,
       round((toplam_ms/60000)::numeric, 1)                               AS toplam_dk,
       round((toplam_ms/7.0/1000)::numeric, 1)                            AS sn_gun,
       round((100*toplam_ms/nullif(sum(toplam_ms) OVER (),0))::numeric, 1) AS sure_pay_yuzde,
       round((toplam_ms/nullif(cagri,0))::numeric, 1)                     AS ort_ms,
       round(en_kotu_ms::numeric, 0)                                      AS en_kotu_ms,
       round((100*io_ms/nullif(toplam_ms,0))::numeric, 0)                 AS io_yuzde,
       CASE
         WHEN io_ms/nullif(toplam_ms,0) > 0.5                    THEN 'I/O-bound'
         WHEN cagri > 1000000 AND toplam_ms/nullif(cagri,0) < 20 THEN 'N+1 / sohbet'
         WHEN toplam_ms/nullif(cagri,0) > 1000                   THEN 'agir tek atis'
         ELSE 'CPU-bound'
       END                                                                AS tip,
       round((blk_erisim/nullif(cagri,0))::numeric, 0)                    AS blk_cagri,
       round((disk_blk/nullif(cagri,0))::numeric, 0)                      AS disk_blk_cagri,
       round((satir/nullif(cagri,0))::numeric, 1)                         AS satir_cagri,
       round((temp_blk*8192/1024.0^2/nullif(cagri,0))::numeric, 1)        AS temp_mb_cagri,
       sorgu                                                  AS sorgu
FROM v
ORDER BY toplam_ms DESC
LIMIT 25;
