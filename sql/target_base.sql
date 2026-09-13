"""
This is the primary solution. It uses a recursive query to trace each campaign 
back to the original campaign that started its retry chain, regardless of how many 
retries deep the chain goes. Customers are counted once per chain, while standalone 
campaigns count every send individually. This is the most robust of the four approaches, 
since it makes no assumption about chain depth, it will correctly handle a retry chain 
of any length, not just the depths present in this sample.

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
  SELECT a.id, a.root_id
  FROM ancestry a
  JOIN campaign c ON c.id = a.id
  WHERE c.merchant_id = 501
    AND c.creation_status IN ('approved','aborted','resumed','stopped')
    AND c.processing_status = 'processed'
),

per_root AS (
  SELECT
    f.root_id,
    CASE WHEN cs.sz > 1 THEN COUNT(DISTINCT cl.customer_id)
         ELSE COUNT(cl.id)
    END AS qualifying_sends
  FROM finalized f
  JOIN chain_sizes cs ON cs.root_id = f.root_id
  LEFT JOIN communication_log cl
    ON cl.communication_id = f.id
   AND cl.merchant_id = 501
   AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
  GROUP BY f.root_id, cs.sz
)

SELECT SUM(qualifying_sends) AS target_base FROM per_root;