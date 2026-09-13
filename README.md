# Comm-Log Send Reconciliation

Reconciling Finance's reported `target_base = 22` for merchant 501, October 2026,
across all Diwali campaigns, from the raw `comm_log.db` data.

## TL;DR

The naive query gives 30 (raw rows) or 25 (distinct customers). Two rules in the
data model close the gap to 22:

1. A campaign that hasn't cleared approval doesn't count, even if sends already
   went out for it.
2. Deduping by customer only applies **within a retry chain** — a standalone
   campaign counts every send as its own event, even if the same customer
   appears twice.

## Reconciliation bridge

| Step | Description | Result | Reason |
|---|---|---|---|
| 0 | Naive `COUNT(*)` on `communication_log` | 30 | Starting point — treats every send attempt as a qualifying send |
| 1 | Switch to `COUNT(DISTINCT customer_id)` | 25 | `target_base` sounds like "customers reached," not raw attempts — dataset shows customers repeating (retries + one plain re-send) |
| 2 | Exclude sends from campaigns where `creation_status = 'approval_awaiting'` | 21 | Campaign 9004 has processed sends (C11–C14) but was never approved — the data dictionary is explicit that unapproved campaigns don't count even if the send pipeline already ran |
| 3 | Add back a double-counted customer under a **standalone** campaign | **22** | Customer C20 was sent twice under campaign 9101, which has no retry chain (no parent, no children). Dedup only applies *within* a retry chain — a standalone campaign counts every send as its own event. Global `DISTINCT` had wrongly collapsed C20's two sends into one |

Full step-by-step queries, in the order they were run: [`sql/investigation_steps.sql`](sql/investigation_steps.sql)

## Root cause

The naive query is wrong for two independent reasons, not one:

1. It counts sends from campaigns that haven't cleared approval yet — the send
   pipeline can run ahead of approval bookkeeping, so "processed" doesn't mean
   "eligible."
2. It applies the same dedup rule (by customer) everywhere, but the data model
   only wants that dedup applied *within a retry chain*. A standalone campaign
   is a different kind of thing — every send under it is a distinct event.

## Final query

**[`sql/target_base.sql`](sql/target_base.sql) is the answer** — run it with:

```bash
sqlite3 data/comm_log.db < sql/target_base.sql
```

It uses a recursive query to trace every campaign back to the original
campaign that started its retry chain, no matter how many retries deep the
chain goes. It then counts distinct customers once per chain, and counts
every send individually for standalone campaigns (a "chain" of size 1).

Broken out by chain, the three underlying communications for merchant 501 are:

| Root campaign | Chain members | Treatment | Qualifying sends |
|---|---|---|---|
| 9001 | 9001, 9002, 9003, 9004 | Chain — dedupe customers (9004 excluded: not approved) | 10 |
| 9101 | 9101 | Standalone — count every send | 7 |
| 9201 | 9201, 9202 | Chain — dedupe customers | 5 |
| | | **Total** | **22** |

### Alternative implementations

The `sql/` folder also has three other working implementations of the same
calculation, kept to show different ways of solving the same problem — not
because there was any doubt about the answer. All four return 22.

| File | Approach | Tradeoff vs. the main query |
|---|---|---|
| [`sql/alt_approach_selfjoin.sql`](sql/alt_approach_selfjoin.sql) | Two self-joins (parent, grandparent) instead of recursion, plus a window function for chain size | Simpler to read, but only correct because no chain here is deeper than 3 levels — a longer chain would silently resolve to the wrong root instead of failing |
| [`sql/alt_approach_split_sum.sql`](sql/alt_approach_split_sum.sql) | Same recursive root-resolution, but computes the chain total and the standalone total as two separate named blocks, then adds them | Same rules, same answer — just organized so each half is easier to explain on its own; also surfaces the 15 / 7 split for free |
| [`sql/alt_approach_temptables.sql`](sql/alt_approach_temptables.sql) | Materializes each step as a temp table instead of chaining CTEs | Lets you inspect any intermediate step directly while debugging, at the cost of being a multi-statement script instead of one query |

## Validation

Two independently-implemented calculations agree on 22:

- **SQL** (`sql/target_base.sql`): recursive query to resolve retry-chain roots.
- **Pandas** (`scripts/validate_independent.py`): manual parent-pointer walk,
  no SQL at all — a different implementation of the same rule.

```
$ python3 scripts/validate_independent.py
  root members method                       count
  9001       4 distinct customers (chain)      10
  9101       1 raw row count (standalone)       7
  9201       2 distinct customers (chain)       5

Computed target_base: 22
Matches sql/target_base.sql.
```

Two unrelated code paths landing on the same number is stronger evidence than
either one alone — it rules out a bug in one query happening to look right.

**Other things checked that turned out not to matter** (kept separate from the
bridge since the assignment specifically asks not to pad it with adjustments
that had no effect):

- `channel` is uniformly `'sms'` — no cross-channel duplicate-send risk.
- `credit_used` is always `1` — not a weighting factor on the metric.
- `sent_time` equals `scheduled_time` for every row — no send-vs-schedule lag.
- The October 2026 date filter is a no-op — every row already falls inside
  `2026-10-01` to `2026-10-31` (kept in the query anyway, since a production
  version of this query shouldn't rely on the sample happening to be clean).
- No customer in a finalized retry chain fails on *every* attempt — so this
  dataset can't actually distinguish "reached" (attempted) from "delivered
  at least once" as the definition of target_base. Flagged below since it's a
  real open question, not something resolved by the data.

## What surprised me

Every customer in a retry chain who ever failed eventually got delivered on a
later attempt within the same chain — there's no case in this dataset of a
customer who was retried and still never delivered. That means I couldn't
actually tell from the data whether `target_base` counts customers who were
*attempted* in a chain or only those *delivered* at least once in it — the
spec says "reached," which reads like attempted, but the only example given
happens to end in delivery. It didn't move the final number here, but it's a
real open question, not something resolved by the data.

## Repo contents

```
README.md                        this file

sql/target_base.sql               the answer — recursive CTE
sql/alt_approach_selfjoin.sql     alternative: self-joins, no recursion
sql/alt_approach_split_sum.sql    alternative: chain + standalone totals added separately
sql/alt_approach_temptables.sql   alternative: temp tables instead of CTEs
sql/investigation_steps.sql       the queries behind the bridge, in the order run

scripts/validate_independent.py   independent (non-SQL) cross-check of the final number

data/comm_log.db                  raw data (SQLite)
data/campaign.csv                 same data, CSV
data/communication_log.csv        same data, CSV
data/DATA_DICTIONARY.md           schema + data dictionary as provided
data/generate_dataset.py          script that generated the synthetic dataset, as provided
```