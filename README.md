# Comm-Log Send Reconciliation

## The problem

Finance says the true `target_base` (qualifying sends) for merchant 501's
Diwali campaigns in October 2026 is **22**. This repo shows how to get from
the raw data to that number, and explains exactly why a simple, obvious query
does not.

## Summary

A plain row count gives 30. A plain "unique customers" count gives 25.
Neither is 22, because of two rules the data actually follows:

1. A campaign that hasn't been approved yet doesn't count — even if messages
   already went out for it.
2. Customers should only be deduplicated **inside a retry chain** (a campaign
   plus its retries). A standalone campaign with no retries counts every send
   separately, even if it happens to hit the same customer twice.

## How the number was worked out (the bridge)

| Step | What was tried | Result | Why |
|---|---|---|---|
| 0 | Count every row in `communication_log` | 30 | Simplest possible starting point — treats every send as a qualifying send |
| 1 | Count unique customers instead | 25 | `target_base` sounds like "customers reached," not raw send attempts |
| 2 | Remove sends from campaigns that were never approved | 21 | Campaign 9004 had sends go out, but its approval was still pending — the data dictionary says unapproved campaigns don't count |
| 3 | Add back a customer who was legitimately sent to twice | **22** | Customer C20 was sent to twice under a standalone campaign (not a retry) — those two sends should both count, but counting unique customers had wrongly merged them into one |

The exact queries behind each row of this table are in
[`sql/investigation_steps.sql`](sql/investigation_steps.sql) — see below for
what that file is and how to read it.

## The final SQL query

[`sql/target_base.sql`](sql/target_base.sql) is the answer. Run it with:

```bash
sqlite3 data/comm_log.db < sql/target_base.sql
```

**What it does, in plain terms:** every campaign is traced back to the
original campaign that started its retry chain (however many retries deep
that chain goes). Then:
- If a chain has more than one campaign in it, customers are counted once
  each, no matter how many times they were retried.
- If a campaign is standalone (no retries), every send counts on its own.

Only campaigns that are both approved and finished processing are included.

Broken down by chain:

| Campaign | Made up of | How it's counted | Sends counted |
|---|---|---|---|
| Wave 1 | 9001, 9002, 9003 (9004 excluded — not approved) | Retry chain — unique customers | 10 |
| Flash Sale | 9101 | Standalone — every send counts | 7 |
| Wave 2 | 9201, 9202 | Retry chain — unique customers | 5 |
| | | **Total** | **22** |

## Other ways to write the same query

The `sql/` folder has three more files that solve this the same way but
written differently — kept to show a few different techniques, not because
there was any doubt about the answer. All four give 22.

- **`alt_approach_selfjoin.sql`** — instead of a recursive query, this joins
  the campaign table to itself twice to jump straight to a campaign's parent
  and grandparent. Easier to read, but only works because no chain in this
  data is more than 3 levels deep — a longer chain would quietly break it.
- **`alt_approach_split_sum.sql`** — same logic as the main query, but instead
  of handling retry chains and standalone campaigns in one combined step, it
  calculates each one separately and adds them together at the end.
- **`alt_approach_temptables.sql`** — breaks the work into temporary tables
  built one step at a time, instead of one query. Useful for checking each
  in-between result while debugging, at the cost of needing several steps
  instead of one.

## The investigation file

[`sql/investigation_steps.sql`](sql/investigation_steps.sql) contains the
actual queries that were run, in the order they were run, to build the bridge
table above — starting from the naive count, then narrowing down exactly why
it didn't match 22. This exists so the bridge isn't just a claim — anyone can
re-run these same queries and see the same findings.

## The validation script

[`scripts/validate_independent.py`](scripts/validate_independent.py) checks
the answer a second, completely different way — using Python and pandas
instead of SQL, and manually following each campaign back to its retry-chain
root instead of using a recursive query. Run it with:

```bash
python3 scripts/validate_independent.py
```

```
  root members method                       count
  9001       4 distinct customers (chain)      10
  9101       1 raw row count (standalone)       7
  9201       2 distinct customers (chain)       5

Computed target_base: 22
Matches sql/target_base.sql.
```

Two completely different methods landing on the same number is stronger
proof than either one alone — it rules out one query just happening to look
right by coincidence.

## Things checked that turned out not to matter

These didn't change the final number, but were worth ruling out rather than
ignoring:

- Every message was sent by the same channel (`sms`) — no risk of the same
  message being double-counted across channels.
- `credit_used` is always 1 — not something that needed to be factored in.
- `sent_time` and `scheduled_time` are always identical — no lag to account for.
- The October date filter doesn't actually remove any rows here, but it's
  kept in the query anyway, since a real version of this query shouldn't
  assume every future dataset will already be this clean.
- No customer in a chain failed on *every* attempt — every retried customer
  eventually got delivered. See below for why that matters.
- No customer was ever part of more than one campaign chain — each customer
  belongs to exactly one. Checked, not assumed.

## What surprised me

Every customer who was retried eventually got delivered somewhere in their
chain — there's no case in this data of a customer who was retried and still
never got the message. That means the data can't actually tell us whether
`target_base` should count customers who were *attempted*, or only those who
were *delivered* at least once. The word "reached" suggests attempted, but
the only example given happens to end in a delivery either way. It didn't
change the final number, but it's a real open question worth confirming.

More concretely: the four customers under the excluded campaign (C11–C14)
aren't retries of anyone else — they're new people who were never contacted
before. That means the approval gate is protecting the *reported number*, not
the actual customer experience: those four people were already messaged,
regardless of what Finance's number says. It raises a real follow-up question
too — if that campaign gets approved later, do those sends retroactively
belong to October, or to whichever month the approval happens to land in?

Two smaller things stood out as well:

- **The excluded campaign's own name gives away its status** — it's literally
  called `"Diwali Cart Recovery - Retry C (pending)"`. Convenient here, but
  not something to rely on in general — the actual approval status field is
  what should decide this.
- **The two retry chains aren't the same shape.** One goes three campaigns
  deep, the other only two. A query that assumed "every campaign has at most
  one retry" would have worked on one chain and silently failed on the other
  — a real reason the query needed to handle chains of any length, not just
  a fixed number of retries.

## Files in this repo

```
README.md                         this file

sql/target_base.sql                the final answer
sql/alt_approach_selfjoin.sql      a different way to write the same query
sql/alt_approach_split_sum.sql     another different way to write it
sql/alt_approach_temptables.sql    a third different way to write it
sql/investigation_steps.sql        the queries behind the bridge table

scripts/validate_independent.py    a second, independent check of the answer

data/comm_log.db                   the raw data (SQLite)
data/campaign.csv                  same data, as a CSV
data/communication_log.csv         same data, as a CSV
data/DATA_DICTIONARY.md            schema and field definitions, as provided
data/generate_dataset.py           the script that generated this data, as provided
```
