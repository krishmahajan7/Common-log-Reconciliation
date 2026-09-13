"""
This version breaks the calculation into separate temporary tables built step by step,
rather than a single query. Its advantage is that each intermediate result can be inspected 
directly during debugging. The tradeoff is that it requires multiple statements to run instead of
one, making it better suited to larger, ongoing projects than a small, one-time reconciliation like this.

""" 

DROP TABLE IF EXISTS tmp_ancestry;
CREATE TEMP TABLE tmp_ancestry AS
WITH RECURSIVE ancestry(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, a.root_id
  FROM campaign c JOIN ancestry a ON c.parent_id = a.id
)
SELECT * FROM ancestry;

DROP TABLE IF EXISTS tmp_finalized;
CREATE TEMP TABLE tmp_finalized AS
SELECT
  a.id,
  a.root_id,
  (SELECT COUNT(*) FROM tmp_ancestry a2 WHERE a2.root_id = a.root_id) AS chain_size
FROM tmp_ancestry a
JOIN campaign c ON c.id = a.id
WHERE c.merchant_id = 501
  AND c.creation_status IN ('approved','aborted','resumed','stopped')
  AND c.processing_status = 'processed';

SELECT SUM(qualifying_sends) AS target_base
FROM (
  SELECT
    f.root_id,
    CASE WHEN f.chain_size > 1 THEN COUNT(DISTINCT cl.customer_id)
         ELSE COUNT(cl.id)
    END AS qualifying_sends
  FROM tmp_finalized f
  LEFT JOIN communication_log cl
    ON cl.communication_id = f.id
   AND cl.merchant_id = 501
   AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
  GROUP BY f.root_id, f.chain_size
);