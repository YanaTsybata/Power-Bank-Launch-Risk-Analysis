import csv
import json
import re
from collections import Counter
from pathlib import Path

HERE = Path(__file__).parent
with open(HERE / "recalls_all.json") as f:
    data = json.load(f)

# strong terms: clearly a lithium battery
STRONG = {
    "lithium": r"lithium",
    "li-ion": r"\bli-?ion\b",
    "lipo": r"\bli-?po\b",
    "18650/21700": r"\b(18650|21700)\b",
    "lifepo4": r"lifepo4",
}
# weak terms: usually lithium, check by eye
WEAK = {
    "power bank": r"power ?banks?",
    "battery pack": r"battery packs?",
    "rechargeable battery": r"rechargeable batter",
    "hoverboard": r"hoverboards?|self-balancing",
}
# coin/button cells: ingestion risk, out of scope by default
COIN = r"coin (cell|batter)|button (cell|batter)|\bcr2032\b"


def all_text(r):
    parts = [r.get("Title") or "", r.get("Description") or ""]
    for key in ["Products", "Hazards", "Remedies", "Injuries"]:
        parts += [x.get("Name") or "" for x in r.get(key) or []]
    return " ".join(parts)


rows = []
for r in data:
    year = (r.get("RecallDate") or "")[:4]
    if year < "2016":
        continue
    text = all_text(r)
    strong = [k for k, p in STRONG.items() if re.search(p, text, re.I)]
    weak = [k for k, p in WEAK.items() if re.search(p, text, re.I)]
    if not strong and not weak:
        continue
    coin = bool(re.search(COIN, text, re.I))
    rows.append({
        "recall_id": r.get("RecallID"),
        "recall_number": r.get("RecallNumber"),
        "year": year,
        "title": r.get("Title"),
        "matched_terms": "; ".join(strong + weak),
        "coin_cell": "yes" if coin else "",
        "needs_review": "yes" if (not strong or coin) else "",
        "keep": "" if (not strong or coin) else "yes",
        "url": r.get("URL"),
    })

out = HERE / "lithium_candidates.csv"
with open(out, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

review = [x for x in rows if x["needs_review"]]
print("candidates:", len(rows))
print("auto keep (strong term, no coin cell):", len(rows) - len(review))
print("needs review:", len(review), "| of them coin cell:", sum(1 for x in review if x["coin_cell"]))
print("18650/21700 hits:", sum(1 for x in rows if "18650/21700" in x["matched_terms"]))
print("per year:", dict(sorted(Counter(x["year"] for x in rows).items())))
print("saved:", out)
