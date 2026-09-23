
SELECT p.pid, p.phase,
       round(100.0 * p.blocks_done / nullif(p.blocks_total, 0), 1) AS pct,
       p.lockers_done, p.lockers_total, p.current_locker_pid,
       a.query AS waiting_for
FROM pg_stat_progress_create_index p
LEFT JOIN pg_stat_activity a ON a.pid = p.current_locker_pid;
