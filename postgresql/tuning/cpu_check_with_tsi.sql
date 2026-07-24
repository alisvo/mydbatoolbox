SELECT query_id,
       sum(calls)                                              AS cagrilar,
       round(sum(total_time)::numeric, 0)                      AS toplam_ms,
       round((sum(total_time)/nullif(sum(calls),0))::numeric,2) AS ort_ms,
       round((100*sum(total_time)/sum(sum(total_time)) OVER ())::numeric,1) AS cpu_pay_yuzde,
       sum(rows)                                               AS satir,
       max(query_sql_text)                          AS sorgu
FROM query_store.qs_view
WHERE start_time >= (timestamp '2026-07-24 09:00:00' AT TIME ZONE 'Europe/Istanbul') AT TIME ZONE 'UTC'
  AND start_time <  (timestamp '2026-07-24 11:00:00' AT TIME ZONE 'Europe/Istanbul') AT TIME ZONE 'UTC'
  AND is_system_query = false
GROUP BY query_id
ORDER BY sum(total_time) DESC
LIMIT 20;
