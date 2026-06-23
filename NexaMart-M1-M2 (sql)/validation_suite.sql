-- ###########################################################################
-- NexaMart M2 — validation_suite.sql   (LO13 — Data Warehouse Validation)
-- ###########################################################################
-- Run AFTER every Gold rebuild (and after anomaly resolution). Each check returns
-- the OFFENDING rows; target is 0 rows unless noted (Check 7 expects >= 1 per fact).
-- Expect failures on the first run — iterate Silver/Gold fixes and re-run. Record
-- every iteration in report Section 3 (which checks failed, what you fixed, final state).
--
-- A check "passes" when its SELECT returns zero rows (except Check 7, which passes when
-- every rows_in_window >= 1). Column names follow 04_gold_facts (Lead facts) + the 03
-- universal dim contract (<dim>_key). Confirm any member-fact column at runtime.
-- ###########################################################################

USE ROLE NEXAMART_ENGINEER;
USE WAREHOUSE NEXAMART_WH;
USE DATABASE NEXAMART_DW;
USE SCHEMA NEXAMART_GOLD;

-- ===========================================================================
-- CHECK 1 — COMPLETENESS: every Gold table non-empty (13 dims + 14 facts = 27).
-- Pass: no table reports row_count = 0.
-- ===========================================================================
SELECT 'dim_date' AS gold_table, COUNT(*) AS row_count FROM dim_date
UNION ALL SELECT 'dim_product', COUNT(*) FROM dim_product
UNION ALL SELECT 'dim_store', COUNT(*) FROM dim_store
UNION ALL SELECT 'dim_customer', COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_seller', COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_promotion', COUNT(*) FROM dim_promotion
UNION ALL SELECT 'dim_channel', COUNT(*) FROM dim_channel
UNION ALL SELECT 'dim_payment_method', COUNT(*) FROM dim_payment_method
UNION ALL SELECT 'dim_delivery_method', COUNT(*) FROM dim_delivery_method
UNION ALL SELECT 'dim_listing_condition', COUNT(*) FROM dim_listing_condition
UNION ALL SELECT 'dim_return_reason', COUNT(*) FROM dim_return_reason
UNION ALL SELECT 'dim_step', COUNT(*) FROM dim_step
UNION ALL SELECT 'dim_seller_risk_tier', COUNT(*) FROM dim_seller_risk_tier
UNION ALL SELECT 'fact_store_sale_line', COUNT(*) FROM fact_store_sale_line
UNION ALL SELECT 'fact_ecommerce_order_line', COUNT(*) FROM fact_ecommerce_order_line
UNION ALL SELECT 'fact_return_line', COUNT(*) FROM fact_return_line
UNION ALL SELECT 'fact_order_fulfilment', COUNT(*) FROM fact_order_fulfilment
UNION ALL SELECT 'fact_store_inventory_snapshot', COUNT(*) FROM fact_store_inventory_snapshot
UNION ALL SELECT 'fact_warehouse_inventory_snapshot', COUNT(*) FROM fact_warehouse_inventory_snapshot
UNION ALL SELECT 'fact_inventory_transaction', COUNT(*) FROM fact_inventory_transaction
UNION ALL SELECT 'fact_web_session', COUNT(*) FROM fact_web_session
UNION ALL SELECT 'fact_web_page_event', COUNT(*) FROM fact_web_page_event
UNION ALL SELECT 'fact_classified_listing_event', COUNT(*) FROM fact_classified_listing_event
UNION ALL SELECT 'fact_classified_listing_snapshot', COUNT(*) FROM fact_classified_listing_snapshot
UNION ALL SELECT 'fact_seller_performance_snapshot', COUNT(*) FROM fact_seller_performance_snapshot
UNION ALL SELECT 'fact_customer_review', COUNT(*) FROM fact_customer_review
UNION ALL SELECT 'fact_customer_complaint', COUNT(*) FROM fact_customer_complaint
ORDER BY row_count;
-- FAIL if any row_count = 0.

-- ===========================================================================
-- CHECK 2 — REFERENTIAL INTEGRITY: zero orphan FKs. date_key is computed identically
-- everywhere (surrogate_key(ISO date)) and dim_date is static, so it is the reliable
-- cross-fact RI probe; add per-fact dim FKs as their member dims are confirmed.
-- Pass: orphan_rows = 0 for every fact.
-- ===========================================================================
SELECT 'fact_ecommerce_order_line.date_key' AS fk, COUNT(*) AS orphan_rows
FROM fact_ecommerce_order_line f LEFT JOIN dim_date d ON f.date_key = d.date_key
WHERE f.date_key IS NOT NULL AND d.date_key IS NULL
UNION ALL
SELECT 'fact_order_fulfilment.placed_date_key', COUNT(*)
FROM fact_order_fulfilment f LEFT JOIN dim_date d ON f.placed_date_key = d.date_key
WHERE f.placed_date_key IS NOT NULL AND d.date_key IS NULL
UNION ALL
SELECT 'fact_store_inventory_snapshot.date_key', COUNT(*)
FROM fact_store_inventory_snapshot f LEFT JOIN dim_date d ON f.date_key = d.date_key
WHERE f.date_key IS NOT NULL AND d.date_key IS NULL
UNION ALL
SELECT 'fact_inventory_transaction.date_key', COUNT(*)
FROM fact_inventory_transaction f LEFT JOIN dim_date d ON f.date_key = d.date_key
WHERE f.date_key IS NOT NULL AND d.date_key IS NULL
UNION ALL
SELECT 'fact_web_page_event.date_key', COUNT(*)
FROM fact_web_page_event f LEFT JOIN dim_date d ON f.date_key = d.date_key
WHERE f.date_key IS NOT NULL AND d.date_key IS NULL
UNION ALL
SELECT 'fact_customer_complaint.date_key', COUNT(*)
FROM fact_customer_complaint f LEFT JOIN dim_date d ON f.date_key = d.date_key
WHERE f.date_key IS NOT NULL AND d.date_key IS NULL;
-- FAIL if orphan_rows > 0 for any FK.

-- ===========================================================================
-- CHECK 3 — GRAIN VIOLATIONS: no duplicate rows at the declared grain (per 04 assert_grain).
-- Pass: every block returns 0 rows.
-- ===========================================================================
SELECT 'fact_ecommerce_order_line' AS fact, COUNT(*) AS dup_groups FROM (
  SELECT order_id, line_id FROM fact_ecommerce_order_line GROUP BY order_id, line_id HAVING COUNT(*) > 1)
UNION ALL SELECT 'fact_order_fulfilment', COUNT(*) FROM (
  SELECT order_id FROM fact_order_fulfilment GROUP BY order_id HAVING COUNT(*) > 1)
UNION ALL SELECT 'fact_store_inventory_snapshot', COUNT(*) FROM (
  SELECT store_id, product_code, snapshot_date FROM fact_store_inventory_snapshot
  GROUP BY store_id, product_code, snapshot_date HAVING COUNT(*) > 1)
UNION ALL SELECT 'fact_inventory_transaction', COUNT(*) FROM (
  SELECT movement_id, node_type FROM fact_inventory_transaction GROUP BY movement_id, node_type HAVING COUNT(*) > 1)
UNION ALL SELECT 'fact_web_page_event', COUNT(*) FROM (
  SELECT session_id, event_id FROM fact_web_page_event GROUP BY session_id, event_id HAVING COUNT(*) > 1)
UNION ALL SELECT 'fact_classified_listing_snapshot', COUNT(*) FROM (
  SELECT listing_id FROM fact_classified_listing_snapshot GROUP BY listing_id HAVING COUNT(*) > 1)
UNION ALL SELECT 'fact_customer_complaint', COUNT(*) FROM (
  SELECT case_id FROM fact_customer_complaint GROUP BY case_id HAVING COUNT(*) > 1);
-- FAIL if any dup_groups > 0.

-- ===========================================================================
-- CHECK 4 — ADDITIVE FACT SANITY: net = gross - discount (fact_store_sale_line).
-- The member-built fact_store_sale_line carries gross_amount, discount_amount and net_amount
-- (plus tax_amount held separately — NULL on these POS lines — and cogs_amount). It has NO
-- return column: store/EC return refunds live in fact_return_line.refund_amount. The additive
-- identity that holds at this grain is therefore net_amount = gross_amount - discount_amount.
-- ===========================================================================
SELECT COUNT(*) AS broken_rows
FROM fact_store_sale_line
WHERE ABS(net_amount - (gross_amount - discount_amount)) > 0.01;
-- FAIL if broken_rows > 0.

-- ===========================================================================
-- CHECK 5 — SEMI-ADDITIVE GUARD: no MARTS view SUMs ATP across dates.
-- Code/review check over the view DDL: flag SUM(...atp...) without a per-date GROUP BY.
-- ===========================================================================
SELECT table_name AS suspect_view
FROM NEXAMART_DW.INFORMATION_SCHEMA.VIEWS
WHERE table_schema = 'NEXAMART_MARTS'
  AND UPPER(view_definition) LIKE '%SUM%ATP%'
  AND UPPER(view_definition) NOT LIKE '%GROUP BY%DATE%';
-- FAIL if any view sums ATP across dates. (Manually confirm each flagged view.)

-- ===========================================================================
-- CHECK 6 — METRIC CERTAINTY COMPLETENESS: no NULL metric_certainty_level in any fact.
-- Pass: null_certainty = 0 for every fact.
-- ===========================================================================
SELECT 'fact_store_sale_line' AS fact, COUNT(*) AS null_certainty FROM fact_store_sale_line WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_ecommerce_order_line', COUNT(*) FROM fact_ecommerce_order_line WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_return_line', COUNT(*) FROM fact_return_line WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_order_fulfilment', COUNT(*) FROM fact_order_fulfilment WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_store_inventory_snapshot', COUNT(*) FROM fact_store_inventory_snapshot WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_warehouse_inventory_snapshot', COUNT(*) FROM fact_warehouse_inventory_snapshot WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_inventory_transaction', COUNT(*) FROM fact_inventory_transaction WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_web_session', COUNT(*) FROM fact_web_session WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_web_page_event', COUNT(*) FROM fact_web_page_event WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_classified_listing_event', COUNT(*) FROM fact_classified_listing_event WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_classified_listing_snapshot', COUNT(*) FROM fact_classified_listing_snapshot WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_seller_performance_snapshot', COUNT(*) FROM fact_seller_performance_snapshot WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_customer_review', COUNT(*) FROM fact_customer_review WHERE metric_certainty_level IS NULL
UNION ALL SELECT 'fact_customer_complaint', COUNT(*) FROM fact_customer_complaint WHERE metric_certainty_level IS NULL;
-- FAIL if null_certainty > 0 anywhere.

-- ===========================================================================
-- CHECK 7 — CAMPAIGN PERIOD COVERAGE: >= 1 row per campaign-accepting fact in 8-28 Aug 2024.
-- PASSES when every rows_in_window >= 1 (opposite polarity to the others).
-- Joins the fact's date FK to dim_date.date_iso to test the window.
-- ===========================================================================
SELECT 'fact_ecommerce_order_line' AS fact,
       COUNT_IF(d.date_iso BETWEEN '2024-08-08' AND '2024-08-28') AS rows_in_window
FROM fact_ecommerce_order_line f JOIN dim_date d ON f.date_key = d.date_key
UNION ALL
SELECT 'fact_order_fulfilment',
       COUNT_IF(d.date_iso BETWEEN '2024-08-08' AND '2024-08-28')
FROM fact_order_fulfilment f JOIN dim_date d ON f.placed_date_key = d.date_key
UNION ALL
SELECT 'fact_store_inventory_snapshot',
       COUNT_IF(d.date_iso BETWEEN '2024-08-08' AND '2024-08-28')
FROM fact_store_inventory_snapshot f JOIN dim_date d ON f.date_key = d.date_key
UNION ALL
SELECT 'fact_web_session',
       COUNT_IF(d.date_iso BETWEEN '2024-08-08' AND '2024-08-28')
FROM fact_web_session f JOIN dim_date d ON f.date_key = d.date_key;
-- FAIL if any rows_in_window = 0.

-- ===========================================================================
-- CHECK 8 — INVENTORY BALANCE RECONCILIATION: per store x product, the change in physical_qty
-- between the first and last campaign-window snapshot should equal the net signed movement.
-- Lists the offending SKU + location (tolerance 0 units). Sampled to store inventory.
-- ===========================================================================
WITH snap AS (
  SELECT store_id, product_code, snapshot_date, physical_qty,
         ROW_NUMBER() OVER (PARTITION BY store_id, product_code ORDER BY snapshot_date)      AS rn_asc,
         ROW_NUMBER() OVER (PARTITION BY store_id, product_code ORDER BY snapshot_date DESC) AS rn_desc
  FROM fact_store_inventory_snapshot
  WHERE snapshot_date BETWEEN '2024-08-08' AND '2024-08-28'
),
bounds AS (
  SELECT store_id, product_code,
         MAX(CASE WHEN rn_asc  = 1 THEN physical_qty END) AS opening_qty,
         MAX(CASE WHEN rn_desc = 1 THEN physical_qty END) AS closing_qty
  FROM snap GROUP BY store_id, product_code
),
moves AS (
  -- quantity_delta is already signed (PICK/DMG negative, RCVD/RET positive), so SUM = net signed
  -- movement. Window the movements to the SAME campaign period as the snapshot bounds above
  -- (the un-windowed all-time sum was the original bug — it could never match a window delta).
  SELECT node_id AS store_id, product_code, SUM(quantity_delta) AS net_delta
  FROM fact_inventory_transaction
  WHERE node_type = 'STORE'
    AND mdate BETWEEN '2024-08-08' AND '2024-08-28'
  GROUP BY node_id, product_code
)
SELECT b.store_id, b.product_code, b.opening_qty, b.closing_qty,
       COALESCE(m.net_delta, 0) AS net_movement,
       (b.closing_qty - b.opening_qty) AS observed_change
FROM bounds b LEFT JOIN moves m ON m.store_id = b.store_id AND m.product_code = b.product_code
WHERE (b.closing_qty - b.opening_qty) <> COALESCE(m.net_delta, 0);
-- Residual is EXPECTED and documented in report S3 (tolerance 0 is deliberately strict): the
-- store physical-count snapshots and the movement ledger are independently sourced — store POS
-- sell-through is NOT recorded in fact_inventory_transaction (only PICK/RCVD/RET/DMG are), so the
-- two cannot reconcile to unit tolerance. ~237/1100 store x product pairs reconcile exactly; the
-- rest are a data-sourcing observation, not an anomaly-resolution defect.

-- ===========================================================================
-- CHECK 9 — CLASSIFIED CERTAINTY SEGREGATION: no Finance MARTS row is ESTIMATED while still
-- marked a confirmed transaction. ESTIMATED must never enter confirmed totals.
-- ===========================================================================
SELECT 'vw_confirmed_gmv' AS finance_view, COUNT(*) AS bad_rows
FROM NEXAMART_MARTS.vw_confirmed_gmv
WHERE metric_certainty_level = 'ESTIMATED' AND is_confirmed_transaction <> FALSE
UNION ALL SELECT 'vw_gsv', COUNT(*) FROM NEXAMART_MARTS.vw_gsv
  WHERE metric_certainty_level = 'ESTIMATED' AND is_confirmed_transaction <> FALSE
UNION ALL SELECT 'vw_ncr', COUNT(*) FROM NEXAMART_MARTS.vw_ncr
  WHERE metric_certainty_level = 'ESTIMATED' AND is_confirmed_transaction <> FALSE
UNION ALL SELECT 'vw_estimated_classified_gmv', COUNT(*) FROM NEXAMART_MARTS.vw_estimated_classified_gmv
  WHERE metric_certainty_level <> 'ESTIMATED';  -- the estimated view must be 100% ESTIMATED
-- FAIL if bad_rows > 0.

-- ===========================================================================
-- CHECK 10 — TEMPORAL CONSISTENCY: post-A14, no auto-correctable delivered-before-shipped left.
-- fact_order_fulfilment stores picked_to_delivered_hours; < 0 = delivered before picked. After the
-- +36h correction the auto-fixable (<=72h) cases are non-negative; the >72h residual is manual-review.
-- ===========================================================================
SELECT COUNT(*) AS uncorrected_violations
FROM fact_order_fulfilment
WHERE picked_to_delivered_hours < 0
  AND ABS(picked_to_delivered_hours) <= 72
  AND COALESCE(metric_certainty_level, '') <> 'UNRELIABLE';
-- FAIL if uncorrected_violations > 0. (>72h rows remain, flagged UNRELIABLE / manual-review.)

-- ###########################################################################
-- After all 10 pass, record the iteration count + per-iteration failures in report S3.
-- ###########################################################################
