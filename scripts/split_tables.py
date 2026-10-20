import csv
import json
from collections import Counter
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "tables"
OUT.mkdir(exist_ok=True)

with open(HERE / "recalls_all.json") as f:
    data = json.load(f)

# recall ids kept after manual review (delimiter can be "," or ";")
with open(HERE / "lithium_candidates.csv", encoding="utf-8-sig") as f:
    dialect = csv.Sniffer().sniff(f.readline())
    f.seek(0)
    lithium = {row["recall_id"].strip() for row in csv.DictReader(f, dialect=dialect)
               if row["keep"].strip().lower() == "yes"}

COLUMNS = {
    "recalls": ["recall_id", "recall_number", "recall_date", "last_publish_date", "title",
                "description", "consumer_contact", "url", "lithium_scope"],
    "products": ["product_id", "recall_id", "product_name", "product_description", "model",
                 "product_type", "category_id", "units_text"],
    "hazards": ["hazard_id", "recall_id", "hazard_text", "hazard_type", "hazard_type_id"],
    "remedies": ["remedy_id", "recall_id", "remedy_text"],
    "remedy_options": ["remedy_option_id", "recall_id", "remedy_option"],
    "injuries": ["injury_id", "recall_id", "injury_text"],
    "recall_companies": ["recall_company_id", "recall_id", "role", "company_text", "company_id_api"],
    "countries": ["country_row_id", "recall_id", "country_raw"],
    "upcs": ["upc_row_id", "recall_id", "upc"],
    "joint_recalls": ["joint_recall_id", "recall_id", "url"],
}
tables = {name: [] for name in COLUMNS}


def clean(value):
    # collapse line breaks and extra spaces, keep text as is
    return " ".join(str(value).split()) if value not in (None, "") else ""


def add(table, rid, items, mapping):
    for item in items or []:
        row = {"recall_id": rid}
        for col, key in mapping.items():
            row[col] = clean(item.get(key)) if isinstance(item, dict) else clean(item)
        tables[table].append(row)


for r in data:
    rid = r.get("RecallID")
    tables["recalls"].append({
        "recall_id": rid,
        "recall_number": clean(r.get("RecallNumber")),
        "recall_date": (r.get("RecallDate") or "")[:10],
        "last_publish_date": (r.get("LastPublishDate") or "")[:10],
        "title": clean(r.get("Title")),
        "description": clean(r.get("Description")),
        "consumer_contact": clean(r.get("ConsumerContact")),
        "url": clean(r.get("URL")),
        "lithium_scope": "yes" if str(rid) in lithium else "no",
    })
    add("products", rid, r.get("Products"), {
        "product_name": "Name", "product_description": "Description", "model": "Model",
        "product_type": "Type", "category_id": "CategoryID", "units_text": "NumberOfUnits"})
    add("hazards", rid, r.get("Hazards"),
        {"hazard_text": "Name", "hazard_type": "HazardType", "hazard_type_id": "HazardTypeID"})
    add("remedies", rid, r.get("Remedies"), {"remedy_text": "Name"})
    add("remedy_options", rid, r.get("RemedyOptions"), {"remedy_option": "Option"})
    add("injuries", rid, r.get("Injuries"), {"injury_text": "Name"})
    add("countries", rid, r.get("ManufacturerCountries"), {"country_raw": "Country"})
    add("upcs", rid, r.get("ProductUPCs"), {"upc": "UPC"})
    add("joint_recalls", rid, r.get("Inconjunctions"), {"url": "URL"})
    for role, key in [("manufacturer", "Manufacturers"), ("importer", "Importers"),
                      ("distributor", "Distributors"), ("retailer", "Retailers")]:
        for item in r.get(key) or []:
            tables["recall_companies"].append({
                "recall_id": rid, "role": role,
                "company_text": clean(item.get("Name")),
                "company_id_api": clean(item.get("CompanyID"))})

# add row ids to child tables and save
for name, rows in tables.items():
    id_col = COLUMNS[name][0]
    if id_col != "recall_id":
        for i, row in enumerate(rows, start=1):
            row[id_col] = i
    with open(OUT / f"{name}.csv", "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS[name])
        writer.writeheader()
        writer.writerows(rows)
    print(f"{name}: {len(rows)} rows")

# checks
ids = [str(r["recall_id"]) for r in tables["recalls"]]
dupes = sum(1 for n in Counter(ids).values() if n > 1)
with_products = {str(p["recall_id"]) for p in tables["products"]}
print("\nduplicate recall_id:", dupes)
print("recalls without products:", len(set(ids) - with_products))
print("lithium_scope yes:", sum(r["lithium_scope"] == "yes" for r in tables["recalls"]), "(expected 190)")
print("lithium ids not found in json:", len(lithium - set(ids)))
print("saved to:", OUT)
