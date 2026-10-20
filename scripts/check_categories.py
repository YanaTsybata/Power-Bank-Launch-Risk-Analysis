import json
from collections import Counter

import requests

URL = "https://www.saferproducts.gov/RestWebServices/Recall?format=json"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
    "Accept": "application/json",
}

# API returns all recalls in one array, no paging
resp = requests.get(URL, headers=HEADERS, timeout=600)
print("status:", resp.status_code, "| type:", resp.headers.get("Content-Type"))

try:
    data = resp.json()
except ValueError:
    # not JSON: show what the server sent
    print(resp.text[:500])
    raise SystemExit

with open("recalls_all.json", "w") as f:
    json.dump(data, f)
print("total recalls:", len(data))

# count recalls per CPSC product type, 2016 and later
counts = Counter()
for r in data:
    year = (r.get("RecallDate") or "")[:4]
    if year >= "2016":
        types = {p.get("Type") or "(empty)" for p in r.get("Products", [])}
        for t in types:
            counts[t] += 1

for t, n in counts.most_common(50):
    print(n, t)
