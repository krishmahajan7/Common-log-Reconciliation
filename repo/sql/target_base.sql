-- target_base for merchant 501, October 2026, Diwali campaigns
-- Run: sqlite3 data/comm_log.db < sql/target_base.sql
--
-- Rule: a "chain" (a campaign plus every retry chained off it) counts distinct
-- customers once each. A "standalone" campaign (no retries, not itself a retry)
-- counts every send as its own event, even if the same customer appears twice.
-- Only campaigns that have cleared creation approval AND finished processing
-- count toward reporting.

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
    CASE WHEN cs.sz > 1 THEN COUNT(DISTINCT cl.customer_id)  -- chain: dedupe customers
         ELSE COUNT(cl.id)                                    -- standalone: every send counts
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
