-- Power Bank Launch Risk: CPSC Recall Analysis (BigQuery)

-- Part 1. Load checks

-- Row counts after upload from Python
SELECT 'recalls' AS table_name, COUNT(*) AS row_count FROM `portfolioprojects-509718.cpsc_analysis.recalls`
UNION ALL
SELECT 'products', COUNT(*) FROM `portfolioprojects-509718.cpsc_analysis.products`
UNION ALL
SELECT 'hazards', COUNT(*) FROM `portfolioprojects-509718.cpsc_analysis.hazards`
UNION ALL
SELECT 'countries', COUNT(*) FROM `portfolioprojects-509718.cpsc_analysis.countries`
UNION ALL
SELECT 'injuries', COUNT(*) FROM `portfolioprojects-509718.cpsc_analysis.injuries`
UNION ALL
SELECT 'recall_companies', COUNT(*) FROM `portfolioprojects-509718.cpsc_analysis.recall_companies`
UNION ALL
SELECT 'lithium_candidates', COUNT(*) FROM `portfolioprojects-509718.cpsc_analysis.lithium_candidates`;

-- Lithium recalls marked in Python (keywords + manual check)
SELECT 'recalls' AS table_name, COUNT(*) AS lithium_recalls
FROM portfolioprojects-509718.cpsc_analysis.recalls
WHERE lithium_scope = TRUE;
-- Result: 190

-- How many products have the official product type filled in
SELECT COUNT(product_type) AS filled_product_type
FROM portfolioprojects-509718.cpsc_analysis.products;
-- Result: product type is often empty, so groups are built by keywords

-- Part 2. Cleaning

-- clean_countries: remove brackets and "Assembled in", unify country names
CREATE OR REPLACE TABLE `portfolioprojects-509718.cpsc_analysis.clean_countries` AS
WITH step1 AS (
  SELECT
    country_row_id,
    recall_id,
    country_raw,
    REGEXP_REPLACE(
      REGEXP_REPLACE(country_raw, r'\s*\(.*?\)', ''),  -- remove brackets
      r'^Assembled in (the )?', ''                      -- remove "Assembled in"
    ) AS country_step
  FROM `portfolioprojects-509718.cpsc_analysis.countries`
)
SELECT
  country_row_id,
  recall_id,
  country_raw,
  CASE
    WHEN country_step IN ('USA', 'United State', 'United Stateso') THEN 'United States'
    WHEN country_step IN ('Bosnia', 'Bosnia Herzegovina') THEN 'Bosnia and Herzegovina'
    WHEN country_step IN ('England', 'Scotland', 'Great Britain') THEN 'United Kingdom'
    WHEN country_step IN ('Various countries', 'United States and Mexico',
                          'Japan and assembled in the United States',
                          'European Union', 'United States, China') THEN 'Multiple'
    WHEN country_step IN ('Unknown', 'N/A') THEN 'Unknown'
    WHEN country_step = 'Korea' THEN 'South Korea'
    WHEN country_step = 'The Netherlands' THEN 'Netherlands'
    WHEN country_step = 'Trinidad' THEN 'Trinidad and Tobago'
    ELSE country_step
  END AS country
FROM step1;

-- clean_hazards: TRUE/FALSE flag for each hazard type by keywords
CREATE OR REPLACE TABLE portfolioprojects-509718.cpsc_analysis.clean_hazards AS
SELECT hazard_id, recall_id, hazard_text,
  REGEXP_CONTAINS(LOWER(hazard_text), r'fire|ignit|flame|combust') AS fire,
  REGEXP_CONTAINS(LOWER(hazard_text), r'\bburns?\b') AS burn,
  REGEXP_CONTAINS(LOWER(hazard_text), r'explo|burst') AS explosion,
  REGEXP_CONTAINS(LOWER(hazard_text), r'shock|electrocut') AS shock,
  REGEXP_CONTAINS(LOWER(hazard_text), r'\bfall|crash|tip.?over') AS fall_crash,
  REGEXP_CONTAINS(LOWER(hazard_text), r'lacerat|\bcut\b') AS laceration,
  REGEXP_CONTAINS(LOWER(hazard_text), r'ingest|swallow|chok') AS ingestion_choking,
  REGEXP_CONTAINS(LOWER(hazard_text), r'carbon monoxide') AS carbon_monoxide,
  REGEXP_CONTAINS(LOWER(hazard_text), r'comply|complian|violat|mandatory|safety standard') AS standard_violation
FROM portfolioprojects-509718.cpsc_analysis.hazards;

-- clean_injuries: remove negations, then flag injuries, deaths and property damage
CREATE OR REPLACE TABLE portfolioprojects-509718.cpsc_analysis.clean_injuries AS
WITH step1 AS (
  SELECT
    injury_id, recall_id, injury_text,
    REGEXP_REPLACE(LOWER(injury_text), r'no (injuries|injury|deaths?|incidents)( (have been|has been|were|was))?( reported)?( received)?|none reported', '') AS text_clean
  FROM portfolioprojects-509718.cpsc_analysis.injuries
)
SELECT
  injury_id, recall_id, injury_text,
  REGEXP_CONTAINS(text_clean, r'injur|\bburns?\b|\bdeaths?\b|\bdied\b|killed|fatal|bruis|lacerat|hospital|fractur|smoke inhalation') AS injury_reported,
  REGEXP_CONTAINS(text_clean, r'\bdeaths?\b|\bdied\b|killed|fatal') AS death_reported,
  REGEXP_CONTAINS(text_clean, r'property damage') AS property_damage
FROM step1;

-- clean_products: number of US units (first number in the text, millions handled)
CREATE OR REPLACE TABLE `portfolioprojects-509718.cpsc_analysis.clean_products` AS
WITH step1 AS (
  SELECT
    product_id, recall_id, product_name, units_text,
    REGEXP_EXTRACT(units_text, r'\d[\d,]*(?:\.\d+)?') AS first_num,                    -- first number
    REGEXP_CONTAINS(LOWER(units_text), r'^\D*\d[\d,]*(\.\d+)?\s*million') AS is_million -- "million" after it
  FROM `portfolioprojects-509718.cpsc_analysis.products`
)
SELECT
  product_id, recall_id, product_name, units_text,
  CASE
    WHEN REGEXP_CONTAINS(LOWER(units_text), r'^\D*\bone million') THEN 1000000
    WHEN REGEXP_CONTAINS(LOWER(units_text), r'^\D*\btwo million') THEN 2000000
    WHEN REGEXP_CONTAINS(LOWER(units_text), r'^\D*\bthree million') THEN 3000000
    ELSE CAST(SAFE_CAST(REPLACE(first_num, ',', '') AS FLOAT64)
              * IF(is_million, 1000000, 1) AS INT64)
  END AS units_us
FROM step1;

-- clean_recalls: add year and product group (non_lithium / power_bank / other_lithium)
CREATE OR REPLACE TABLE `portfolioprojects-509718.cpsc_analysis.clean_recalls` AS
SELECT
  recall_id, recall_number, recall_date, title, url, lithium_scope,
  EXTRACT(YEAR FROM recall_date) AS year,
  CASE
    WHEN lithium_scope = false THEN 'non_lithium'
    WHEN REGEXP_CONTAINS(LOWER(title), r'power ?banks?|portable (\w+ ){0,2}chargers?|battery banks?') THEN 'power_bank'
    ELSE 'other_lithium'
  END AS product_group
FROM `portfolioprojects-509718.cpsc_analysis.recalls`;

-- clean_sales: retailer rows with sales text (where the product was sold)
CREATE OR REPLACE TABLE `portfolioprojects-509718.cpsc_analysis.clean_sales` AS
WITH step1 AS (
  SELECT
    recall_company_id, recall_id, company_text AS sales_text,
    REGEXP_CONTAINS(LOWER(company_text), r'online|\.com\b|www\.|website|amazon|ebay') AS online,
    REGEXP_CONTAINS(
      REGEXP_REPLACE(LOWER(company_text), r'online (retailers|sellers)|third.party sellers', ''),
      r'\bstores?\b|retailers|dealers|distributors|merchandisers|carriers|shopping programs'
    ) AS stores,
    REGEXP_CONTAINS(LOWER(company_text), r'amazon') AS sold_on_amazon
  FROM `portfolioprojects-509718.cpsc_analysis.recall_companies`
  WHERE role = 'retailer'
    AND REGEXP_CONTAINS(LOWER(company_text), r'\$|\bfrom\b|\bonline\b|\bstores?\b|nationwide|\bsold\b|\.com')
)
SELECT
  recall_company_id, recall_id, sales_text, sold_on_amazon,
  CASE
    WHEN stores AND online THEN 'stores_and_online'
    WHEN stores THEN 'stores_only'
    WHEN online THEN 'online_only'
    ELSE 'unknown'
  END AS channel
FROM step1;

-- clean_recall_companies: company name, location and company_key (name without punctuation)
CREATE OR REPLACE TABLE `portfolioprojects-509718.cpsc_analysis.clean_recall_companies` AS
SELECT
  recall_company_id, recall_id, role, company_text,
  COALESCE(REGEXP_EXTRACT(company_text, r'^(.*?),? of '), company_text) AS company_name,
  REGEXP_EXTRACT(company_text, r' of (.*)$') AS location,
  REGEXP_REPLACE(LOWER(COALESCE(REGEXP_EXTRACT(company_text, r'^(.*?),? of '), company_text)), r'[^a-z0-9]', '') AS company_key
FROM `portfolioprojects-509718.cpsc_analysis.recall_companies`
WHERE company_text IS NOT NULL
  AND NOT (role = 'retailer' AND REGEXP_CONTAINS(LOWER(company_text), r'\$|\bfrom\b|\bonline\b|\bstores?\b|nationwide|\bsold\b|\.com'))
  AND NOT REGEXP_CONTAINS(LOWER(company_text), r'^see chart|has received|have received');

-- Part 3. Analysis
-- Q1. What share of lithium battery product recalls and of all CPSC recalls in 2016-2026 are power banks?
-- Q2. What share of power bank recalls are linked to fire or burns and injuries, compared with other lithium products?
-- Q3. How many units does a power bank recall usually affect, and are there very large recalls?
-- Q4. Where were recalled power banks made and sold, and do the same companies appear more than once?
-- Q5. How did the number of lithium product and power bank recalls change by year?

-- Check: earliest year of lithium recalls (all 190 fall in 2016-2026?)
SELECT MIN(year) AS first_lithium_year
FROM `cpsc_analysis.clean_recalls`
WHERE product_group != 'non_lithium';
-- Result: 2016 (lithium products were searched only in 2016-2026 recalls)

-- Q1: share of power banks among lithium recalls and all recalls, 2016-2026
WITH counts AS (
  SELECT
    COUNT(recall_id) AS all_recalls,
    COUNTIF(product_group IN ('power_bank', 'other_lithium')) AS lithium_recalls,
    COUNTIF(product_group = 'power_bank') AS power_bank_recalls
  FROM `portfolioprojects-509718.cpsc_analysis.clean_recalls`
  WHERE year BETWEEN 2016 AND 2026
)
SELECT
  all_recalls,
  lithium_recalls,
  power_bank_recalls,
  ROUND(SAFE_DIVIDE(power_bank_recalls * 100.0, lithium_recalls), 1) AS pb_pct_of_lithium,
  ROUND(SAFE_DIVIDE(power_bank_recalls * 100.0, all_recalls), 1) AS pb_pct_of_all,
  ROUND(SAFE_DIVIDE(lithium_recalls * 100.0, all_recalls), 1) AS lithium_pct_of_all
FROM counts;
-- Result: all 3405, lithium 190, power banks 39
-- Power banks = 20.5% of lithium recalls, 1.1% of all recalls; lithium = 5.6% of all recalls

-- Q2: fire/burn recalls and injuries, power banks vs other lithium products
WITH counts AS (
  SELECT
    r.product_group,
    COUNT(DISTINCT r.recall_id) AS recalls,
    COUNT(DISTINCT CASE WHEN h.fire OR h.burn THEN r.recall_id END) AS fire_burn_recalls,
    COUNT(DISTINCT CASE WHEN (h.fire OR h.burn) AND i.injury_reported THEN r.recall_id END) AS fire_burn_injured
  FROM `cpsc_analysis.clean_recalls` AS r
  LEFT JOIN `cpsc_analysis.clean_hazards` AS h ON r.recall_id = h.recall_id
  LEFT JOIN `cpsc_analysis.clean_injuries` AS i ON r.recall_id = i.recall_id
  WHERE r.product_group IN ('power_bank', 'other_lithium')
  GROUP BY r.product_group
)
SELECT
  product_group,
  recalls,
  fire_burn_recalls,
  ROUND(SAFE_DIVIDE(fire_burn_recalls * 100.0, recalls), 1) AS fire_burn_pct,
  fire_burn_injured,
  ROUND(SAFE_DIVIDE(fire_burn_injured * 100.0, fire_burn_recalls), 1) AS injured_pct_of_fire_burn
FROM counts;
-- Result: power banks: 39 recalls, 38 fire/burn (97.4%), 19 of them with injuries (50.0%)
-- other lithium: 151 recalls, 134 fire/burn (88.7%), 36 of them with injuries (26.9%)

-- Q3a: units per recall (median and max), power banks vs other lithium
WITH per_recall AS (
  SELECT
    r.recall_id, r.product_group,
    SUM(p.units_us) AS units
  FROM `cpsc_analysis.clean_recalls` AS r
  INNER JOIN `cpsc_analysis.clean_products` AS p
  ON r.recall_id = p.recall_id
  WHERE r.product_group IN ('power_bank', 'other_lithium')
  GROUP BY r.recall_id, r.product_group
)
SELECT
  product_group,
  APPROX_QUANTILES(units, 2)[OFFSET(1)] AS median_units,
  MAX(units) AS max_units,
  COUNT(*) AS recalls,
  COUNT(units) AS recalls_with_units
FROM per_recall
GROUP BY product_group;
-- Result: power banks: median 14000, max 1158000, 39 recalls (all 39 with units)
-- other lithium: median 11500, max 2500000, 151 recalls (all 151 with units)
-- Max vs median for power banks: 1158000 / 14000 = 83x

-- Q3b: top 5 largest power bank recalls by US units
SELECT
  r.recall_id, r.year, r.title,
  SUM(p.units_us) AS units
FROM `cpsc_analysis.clean_recalls` AS r
INNER JOIN `cpsc_analysis.clean_products` AS p
ON r.recall_id = p.recall_id
WHERE r.product_group = 'power_bank'
GROUP BY r.recall_id, r.year, r.title
ORDER BY units DESC
LIMIT 5;
-- Result: 1) 10311 Anker (2025) 1,158,000 | 2) 9977 myCharge (2024) 567,000
-- 3) 10115 Charmast (2024) 488,000 | 4) 10241 Casely (2025) 429,200
-- 5) 9693 Ubio Labs (2023) 350,000
-- 5th largest vs median: 350000 / 14000 = 25x

-- Q4a: countries of manufacture, power banks vs other lithium
SELECT
  r.product_group, c.country,
  COUNT(DISTINCT r.recall_id) AS recalls
FROM `cpsc_analysis.clean_recalls` AS r
INNER JOIN `cpsc_analysis.clean_countries` AS c
ON r.recall_id = c.recall_id
WHERE r.product_group IN ('power_bank', 'other_lithium')
GROUP BY r.product_group, c.country
ORDER BY r.product_group, recalls DESC;
-- Result: power banks: China 38, Vietnam 2 (sum 40, one recall lists both countries)
-- other lithium: China 126, United States 9, South Korea 7, Taiwan 6, Japan 3, ...
-- Share of recalls with China: 38 / 39 = 97.4%; 126 / 151 = 83.4%

-- Check: power bank recalls with more than one country
SELECT
  r.recall_id,
  COUNT(c.country) AS countries
FROM `cpsc_analysis.clean_recalls` AS r
INNER JOIN `cpsc_analysis.clean_countries` AS c
ON r.recall_id = c.recall_id
WHERE r.product_group = 'power_bank'
GROUP BY r.recall_id
HAVING COUNT(c.country) > 1;
-- Result: only recall 10484 lists 2 countries (China + Vietnam), so 39 recalls give 40 country rows

-- Q4b: sales channels, power banks vs other lithium
SELECT
  r.product_group, s.channel,
  COUNT(DISTINCT r.recall_id) AS recalls
FROM `cpsc_analysis.clean_recalls` AS r
INNER JOIN `cpsc_analysis.clean_sales` AS s
ON r.recall_id = s.recall_id
WHERE r.product_group IN ('power_bank', 'other_lithium')
GROUP BY r.product_group, s.channel
ORDER BY r.product_group, recalls DESC;
-- Result: power banks: online_only 19, stores_and_online 12, stores_only 5, unknown 3 (sum 39)
-- other lithium: stores_and_online 82, online_only 47, stores_only 20, unknown 1
-- (sum 150 of 151, one recall has no sales row)
-- Online only: 19 / 39 = 48.7%; 47 / 151 = 31.1%
-- Stores and online: 12 / 39 = 30.8%; 82 / 151 = 54.3%

-- Check: company names in power bank recalls (look for duplicates)
SELECT DISTINCT
  rc.company_key,
  rc.company_name
FROM `cpsc_analysis.clean_recalls` AS r
INNER JOIN `cpsc_analysis.clean_recall_companies` AS rc
ON r.recall_id = rc.recall_id
WHERE r.product_group = 'power_bank'
ORDER BY rc.company_key;
-- Result: 45 rows. Duplicates found: belkin = belkininternationalinc, spectorco = spectorcoinc
-- IKEA Supply AG and IKEA US Retail LLC kept separate (different legal entities)

-- Q4c: companies with more than one power bank recall (duplicate names merged)
WITH merged AS (
  SELECT
    r.recall_id,
    CASE rc.company_key
      WHEN 'belkin' THEN 'belkininternationalinc'
      WHEN 'spectorco' THEN 'spectorcoinc'
      ELSE rc.company_key
    END AS company_key
  FROM `cpsc_analysis.clean_recalls` AS r
  INNER JOIN `cpsc_analysis.clean_recall_companies` AS rc
  ON r.recall_id = rc.recall_id
  WHERE r.product_group = 'power_bank'
)
SELECT
  company_key,
  COUNT(DISTINCT recall_id) AS recalls
FROM merged
GROUP BY company_key
HAVING COUNT(DISTINCT recall_id) > 1
ORDER BY recalls DESC;
-- Result: 6 companies: belkininternationalinc 3; spectorcoinc, rfabrandsllcdbamycharge,
-- shenzhenbaseustechnologycoltd, ankerinnovationslimited, waymeetlimited 2 each

-- Q5: recalls per year: all, lithium, power banks, lithium share
SELECT
  year,
  COUNT(DISTINCT recall_id) AS all_recalls,
  COUNTIF(product_group IN ('power_bank', 'other_lithium')) AS lithium_recalls,
  COUNTIF(product_group = 'power_bank') AS power_bank_recalls,
  ROUND(SAFE_DIVIDE(
    COUNTIF(product_group IN ('power_bank', 'other_lithium')) * 100.0,
    COUNT(*)
  ), 1) AS lithium_pct
FROM `cpsc_analysis.clean_recalls`
WHERE year BETWEEN 2016 AND 2026
GROUP BY year
ORDER BY year;
-- Result: lithium recalls 2023 = 13, 2025 = 32 (max in 2016-2026); power banks 2023 = 3, 2025 = 11
-- Growth 2023 -> 2025: lithium 32 / 13 = 2.5x; power banks 11 / 3 = 3.7x; all recalls 420 / 324 = 1.3x
-- Lithium share of all recalls: 4.0% in 2023 -> 7.6% in 2025
-- 2026 is incomplete (data to Oct 10)