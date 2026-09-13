-- The four queries behind the reconciliation bridge, in the order they were run.
-- Run individually: sqlite3 data/comm_log.db "<paste one block>"

-- Step 0: naive row count — treats every send attempt as a qualifying send
SELECT COUNT(*) AS step0_naive_rowcount
FROM communication_log;
-- => 30

-- Step 1: naive distinct-customer count — first guess at "customers reached"
SELECT COUNT(DISTINCT customer_id) AS step1_distinct_customers
FROM communication_log;
-- => 25

-- Discovery: campaign 9004 has processed sends but was never approved
SELECT id, parent_id, name, creation_status, processing_status
FROM campaign
WHERE NOT (
  creation_status IN ('approved','aborted','resumed','stopped')
  AND processing_status = 'processed'
);
-- => 9004 | 9001 | Diwali Cart Recovery - Retry C (pending) | approval_awaiting | processed

-- Step 2: exclude sends from campaigns that haven't cleared approval
SELECT COUNT(DISTINCT cl.customer_id) AS step2_after_excluding_unapproved
FROM communication_log cl
JOIN campaign c ON c.id = cl.communication_id
WHERE c.creation_status IN ('approved','aborted','resumed','stopped')
  AND c.processing_status = 'processed';
-- => 21

-- Discovery: same customer sent twice under the SAME campaign id (not a retry chain)
SELECT communication_id, customer_id, COUNT(*) AS n
FROM communication_log
GROUP BY communication_id, customer_id
HAVING COUNT(*) > 1;
-- => 9101 | C20 | 2   (campaign 9101 has no parent and no children -> standalone)

-- Step 3 (final): standalone campaigns should NOT dedupe customers -- only
-- retry chains should. Resolve each campaign to its retry-chain root, then
-- apply distinct-customer counting only where the chain has more than one
-- campaign in it. See target_base.sql for the full query.
-- => 22
