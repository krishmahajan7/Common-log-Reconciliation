"""
This applies the identical logic as the main query, organized differently. Rather than
handling chain and standalone campaigns within a single branching statement, it calculates
each total separately and combines them at the end. The result and underlying rules are 
unchanged — this version simply presents the two cases as distinct, more easily explainable steps.

"""

WITH RECURSIVE ancestry(id, root_id) AS (
  SELECT id, id FROM campaign WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, a.root_id
  FROM campaign c JOIN ancestry a ON c.parent_id = a.id
),
chain_sizes AS (
  SELECT root_id, COUNT(*) AS sz FROM ancestry GROUP BY root_id
),
finalized AS (
  SELECT a.id, a.root_id, cs.sz
  FROM ancestry a
  JOIN campaign c ON c.id = a.id
  JOIN chain_sizes cs ON cs.root_id = a.root_id
  WHERE c.merchant_id = 501
    AND c.creation_status IN ('approved','aborted','resumed','stopped')
    AND c.processing_status = 'processed'
),

chain_total AS (
  SELECT SUM(per_chain_count) AS n
  FROM (
    SELECT COUNT(DISTINCT cl.customer_id) AS per_chain_count
    FROM finalized f
    JOIN communication_log cl
      ON cl.communication_id = f.id
     AND cl.merchant_id = 501
     AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
    WHERE f.sz > 1
    GROUP BY f.root_id
  )
),

standalone_total AS (
  SELECT COUNT(cl.id) AS n
  FROM finalized f
  JOIN communication_log cl
    ON cl.communication_id = f.id
   AND cl.merchant_id = 501
   AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
  WHERE f.sz = 1
)
SELECT
  (SELECT n FROM chain_total) + (SELECT n FROM standalone_total) AS target_base,
  (SELECT n FROM chain_total)      AS chain_customers,
  (SELECT n FROM standalone_total) AS standalone_sends;