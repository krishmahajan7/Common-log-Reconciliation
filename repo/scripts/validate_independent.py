"""
Independent validation of target_base = 22, deliberately NOT reusing the SQL
in sql/target_base.sql. Same logic, different implementation (pandas + manual
parent-chain walk instead of a recursive CTE) — if both agree, that's real
evidence the number isn't a coincidence of one query's bug.

Run: python3 scripts/validate_independent.py
"""
import pandas as pd

campaign = pd.read_csv("data/campaign.csv")
comm = pd.read_csv("data/communication_log.csv")

parent = dict(zip(campaign.id, campaign.parent_id))


def root_of(cid):
    seen = set()
    while pd.notna(parent.get(cid)):
        cid = int(parent[cid])
        if cid in seen:
            raise ValueError(f"cycle detected involving campaign {cid}")
        seen.add(cid)
    return cid


campaign["root_id"] = campaign.id.apply(root_of)
chain_size = campaign.groupby("root_id").id.count().to_dict()

finalized_mask = campaign.creation_status.isin(
    ["approved", "aborted", "resumed", "stopped"]
) & (campaign.processing_status == "processed")
finalized = campaign[finalized_mask][["id", "root_id"]]

merged = comm.merge(finalized, left_on="communication_id", right_on="id", suffixes=("", "_camp"))

total = 0
print(f"{'root':>6} {'size':>5} {'method':<28} {'qty':>4}")
for root, grp in merged.groupby("root_id"):
    size = chain_size[root]
    if size > 1:
        qty = grp.customer_id.nunique()
        method = "distinct customers (chain)"
    else:
        qty = len(grp)
        method = "raw row count (standalone)"
    print(f"{root:>6} {size:>5} {method:<28} {qty:>4}")
    total += qty

print(f"\nINDEPENDENT TOTAL: {total}")
assert total == 22, f"Mismatch! Independent method gave {total}, expected 22"
print("Matches sql/target_base.sql. ✓")
