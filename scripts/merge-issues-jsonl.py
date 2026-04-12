#!/usr/bin/env python3
"""
Git merge driver for .beads/issues.jsonl.

Usage (via git config merge.beads-jsonl.driver):
  python3 scripts/merge-issues-jsonl.py %O %A %B

Arguments:
  %O  ancestor (base) version  — temp file, read-only
  %A  ours (current branch)    — temp file, must write merged result here
  %B  theirs (other branch)    — temp file, read-only

Strategy: for each issue ID, keep the version with the latest updated_at.
Issues present in only one side are included as-is. The result is written
to %A (ours). Exit 0 on success (no conflict).
"""

import json
import sys


def load_jsonl(path):
    """Return an ordered list of (id, obj) pairs from a JSONL file."""
    issues = {}
    order = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    issue_id = obj.get("id")
                    if issue_id:
                        if issue_id not in issues:
                            order.append(issue_id)
                        issues[issue_id] = obj
                except json.JSONDecodeError:
                    pass  # skip malformed lines
    except FileNotFoundError:
        pass
    return issues, order


def merge(ancestor_path, ours_path, theirs_path):
    ancestor, anc_order = load_jsonl(ancestor_path)
    ours, our_order = load_jsonl(ours_path)
    theirs, their_order = load_jsonl(theirs_path)

    # Stable ordering: start with ours order, append any new IDs from theirs
    all_ids = list(our_order)
    seen = set(all_ids)
    for tid in their_order:
        if tid not in seen:
            all_ids.append(tid)
            seen.add(tid)

    merged = {}
    for issue_id in all_ids:
        in_ours = issue_id in ours
        in_theirs = issue_id in theirs

        if in_ours and in_theirs:
            # Take whichever was updated more recently
            our_ts = ours[issue_id].get("updated_at", "")
            their_ts = theirs[issue_id].get("updated_at", "")
            merged[issue_id] = ours[issue_id] if our_ts >= their_ts else theirs[issue_id]
        elif in_ours:
            merged[issue_id] = ours[issue_id]
        elif in_theirs:
            merged[issue_id] = theirs[issue_id]
        # if neither: was deleted on both sides — omit

    # Write merged result back to %A (ours path)
    with open(ours_path, "w", encoding="utf-8") as f:
        for issue_id in all_ids:
            if issue_id in merged:
                f.write(json.dumps(merged[issue_id], separators=(",", ":")) + "\n")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <ancestor> <ours> <theirs>", file=sys.stderr)
        sys.exit(1)
    sys.exit(merge(sys.argv[1], sys.argv[2], sys.argv[3]))
