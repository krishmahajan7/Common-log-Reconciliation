"""
Independent validation of the target_base calculation.

Re-implements the reconciliation logic using a different method (pandas
with a manual parent-chain walk) rather than the recursive CTE in
sql/target_base.sql. Agreement between the two confirms the result is
not an artifact of a single query.
"""

import pandas as pd

campaigns = pd.read_csv("data/campaign.csv")
logs = pd.read_csv("data/communication_log.csv")

parent_of = dict(zip(campaigns.id, campaigns.parent_id))


def find_chain_root(campaign_id):
    """Walk parent_id pointers up to the top of the retry chain."""
    visited = set()
    while pd.notna(parent_of.get(campaign_id)):
        campaign_id = int(parent_of[campaign_id])
        if campaign_id in visited:
            raise ValueError(f"cycle detected involving campaign {campaign_id}")
        visited.add(campaign_id)
    return campaign_id


campaigns["chain_root"] = campaigns.id.apply(find_chain_root)
chain_member_count = campaigns.groupby("chain_root").id.count().to_dict()

is_eligible = campaigns.creation_status.isin(
    ["approved", "aborted", "resumed", "stopped"]
) & (campaigns.processing_status == "processed")
eligible_campaigns = campaigns[is_eligible][["id", "chain_root"]]

eligible_logs = logs.merge(
    eligible_campaigns, left_on="communication_id", right_on="id", suffixes=("", "_campaign")
)

target_base = 0
print(f"{'root':>6} {'members':>7} {'method':<28} {'count':>5}")
for root, group in eligible_logs.groupby("chain_root"):
    members = chain_member_count[root]
    if members > 1:
        count = group.customer_id.nunique()
        method = "distinct customers (chain)"
    else:
        count = len(group)
        method = "raw row count (standalone)"
    print(f"{root:>6} {members:>7} {method:<28} {count:>5}")
    target_base += count

print(f"\nComputed target_base: {target_base}")
assert target_base == 22, f"Mismatch: got {target_base}, expected 22"
print("Matches sql/target_base.sql.")