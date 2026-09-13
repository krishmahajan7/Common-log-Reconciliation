"""
This file walks through the investigation behind the reconciliation bridge,
in the order the checks were actually run. It starts with a naive row count,
then a naive distinct-customer count, then digs into why neither matches
Finance's reported number of 22 -- first finding an unapproved campaign
(9004) whose sends shouldn't count yet, then finding a customer (C20) sent
twice under a standalone campaign that shouldn't be deduped like a retry
chain would be. Each step's result is noted inline; the final query that
generalizes these rules across the full dataset is in target_base.sql.
""" 

SELECT COUNT(*) AS naive_row_count
FROM communication_log;
-- 30  every send counted, no dedup

SELECT COUNT(DISTINCT customer_id) AS naive_customer_count
FROM communication_log;
-- 25 unique customers instead

SELECT id, parent_id, name, creation_status, processing_status
FROM campaign
WHERE NOT (
  creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
  AND processing_status = 'processed'
);
-- 9004 processed, but still approval_awaiting

-- drop the  unapproved campaigns and recount
SELECT COUNT(DISTINCT cl.customer_id) AS customer_count_excluding_unapproved
FROM communication_log cl
JOIN campaign c ON c.id = cl.communication_id
WHERE c.creation_status IN ('approved', 'aborted', 'resumed', 'stopped')
  AND c.processing_status = 'processed';
-- 21

SELECT communication_id, customer_id, COUNT(*) AS send_count
FROM communication_log
GROUP BY communication_id, customer_id
HAVING COUNT(*) > 1;
