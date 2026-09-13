"""
This achieves the same result without recursion, using two self-joins to resolve each 
campaign directly to its parent and grandparent. It is more compact and easier to read 
at a glance, but it depends on no retry chain exceeding three levels — true for this dataset,
but not guaranteed in general. A deeper chain would be silently resolved incorrectly rather 
than raising an error, which is the tradeoff for this approach's simplicity.

"""

WITH resolved AS (

  SELECT
    c.id,
    c.creation_status,
    c.processing_status,
    COALESCE(gp.id, p.id, c.id) AS root_id
  FROM campaign c
  LEFT JOIN campaign p  ON c.parent_id = p.id
  LEFT JOIN campaign gp ON p.parent_id = gp.id
  WHERE c.merchant_id = 501
),
sized AS (
  SELECT *, COUNT(*) OVER (PARTITION BY root_id) AS chain_size
  FROM resolved
),
per_root AS (
  SELECT
    root_id,
    CASE WHEN chain_size > 1 THEN COUNT(DISTINCT cl.customer_id)
         ELSE COUNT(cl.id)
    END AS qualifying_sends
  FROM sized s
  LEFT JOIN communication_log cl
    ON cl.communication_id = s.id
   AND cl.merchant_id = 501
   AND cl.sent_time >= '2026-10-01' AND cl.sent_time < '2026-11-01'
  WHERE s.creation_status IN ('approved','aborted','resumed','stopped')
    AND s.processing_status = 'processed'
  GROUP BY root_id, chain_size
)
SELECT SUM(qualifying_sends) AS target_base FROM per_root;