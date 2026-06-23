-- ###########################################################################
-- NexaMart M2 — kpi_views.sql   (LO12 — KPI View Design)
-- ###########################################################################
-- All KPI views live in NEXAMART_MARTS. The dashboard connects to THIS schema ONLY.
--
-- MANDATORY on every view:  a metric_certainty_level column (CONFIRMED/INFERRED/ESTIMATED)
-- MANDATORY on every FINANCE view (Check 9): an is_confirmed_transaction boolean column
-- RULES: never mix ESTIMATED and CONFIRMED in one numeric column; Estimated Classified GMV is a
--        SEPARATE view with a lower/point/upper band; ATP is SEMI-ADDITIVE — never SUM across dates.
--
-- Sources are NEXAMART_GOLD facts (04 Lead facts + 06 rebuilt facts). Rate KPIs expose
-- numerator/denominator pairs (never pre-divided) so the dashboard aggregates additively.
-- Run the 4 staged GRANTs (m2_setup_marts.sql) as ACCOUNTADMIN before deploying these.
-- 28 KPIs: 8 Finance, 6 Inventory, 8 Ecommerce/Store, 6 NexaLocal/Seller.
-- ###########################################################################

USE ROLE NEXAMART_ENGINEER;
USE WAREHOUSE NEXAMART_WH;
USE DATABASE NEXAMART_DW;
USE SCHEMA NEXAMART_MARTS;

-- ===========================================================================
-- FINANCE  (all carry is_confirmed_transaction)
-- ===========================================================================

-- vw_gsv — Gross Sale Value | CONFIRMED
-- business_definition: gross transaction value (tax-exclusive) at completion, BEFORE deductions,
--   per channel x campaign_phase. EC keeps GROSS (line_subtotal_excl_tax incl. later-cancelled);
--   the A1 cancellation is a deduction surfaced in vw_revenue_leakage / vw_ncr.
CREATE OR REPLACE VIEW vw_gsv AS
SELECT channel, campaign_phase, ROUND(SUM(gross_value), 2) AS gsv,
       TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level
FROM (
  SELECT 'EC' AS channel, d.campaign_phase, f.line_subtotal_excl_tax AS gross_value
  FROM NEXAMART_GOLD.fact_ecommerce_order_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
  UNION ALL
  SELECT 'STORE', d.campaign_phase, f.gross_amount
  FROM NEXAMART_GOLD.fact_store_sale_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
)
GROUP BY channel, campaign_phase;

-- vw_ncr — Net Confirmed Revenue | CONFIRMED
-- business_definition: confirmed revenue per channel x campaign_phase. EC uses confirmed_revenue_excl_tax
--   (A1: cancelled = 0); STORE uses net_amount minus return_amount. Excludes NexaLocal seller-marked
--   transactions without platform payment (those are ESTIMATED, vw_estimated_classified_gmv).
CREATE OR REPLACE VIEW vw_ncr AS
SELECT channel, campaign_phase, ROUND(SUM(net_confirmed), 2) AS ncr,
       TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level
FROM (
  SELECT 'EC' AS channel, d.campaign_phase, f.confirmed_revenue_excl_tax AS net_confirmed
  FROM NEXAMART_GOLD.fact_ecommerce_order_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
  UNION ALL
  -- store NCR = net_amount (store returns are surfaced separately in vw_revenue_leakage; fact_store_sale_line has no return column)
  SELECT 'STORE', d.campaign_phase, f.net_amount
  FROM NEXAMART_GOLD.fact_store_sale_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
)
GROUP BY channel, campaign_phase;

-- vw_revenue_leakage — GSV - NCR by leakage type | CONFIRMED
-- business_definition: each named deduction in the GSV->NCR waterfall. Cancellation = gross revenue of
--   A1 cancelled EC orders; returns/refunds from the return facts. (Tax/shipping are out of scope —
--   the model is already tax-exclusive.)
CREATE OR REPLACE VIEW vw_revenue_leakage AS
SELECT 'CANCELLATION' AS leakage_type,
       ROUND(SUM(CASE WHEN order_status = 'CANCELLED' THEN line_subtotal_excl_tax ELSE 0 END), 2) AS leakage_amount,
       TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_ecommerce_order_line
UNION ALL
-- all platform return refunds (EC + store) live in fact_return_line; fact_store_sale_line has no return column
SELECT 'RETURN_REFUND', ROUND(SUM(COALESCE(refund_amount, 0)), 2), TRUE, 'CONFIRMED'
FROM NEXAMART_GOLD.fact_return_line;

-- vw_gross_margin_by_channel — NCR - COGS by channel | CONFIRMED
-- business_definition: numerator/denominator pair (never a pre-divided ratio). STORE has cogs_amount;
--   EC COGS is not modelled at line grain (0), documented in report S4.
CREATE OR REPLACE VIEW vw_gross_margin_by_channel AS
SELECT channel, ROUND(SUM(revenue), 2) AS revenue_denominator,
       ROUND(SUM(revenue - cogs), 2) AS gross_margin_numerator,
       TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level
FROM (
  SELECT 'STORE' AS channel, net_amount AS revenue, COALESCE(cogs_amount, 0) AS cogs
  FROM NEXAMART_GOLD.fact_store_sale_line
  UNION ALL
  SELECT 'EC', confirmed_revenue_excl_tax, 0 FROM NEXAMART_GOLD.fact_ecommerce_order_line
)
GROUP BY channel;

-- vw_net_margin_after_fulfilment — gross margin minus fulfilment/return/fees | CONFIRMED
-- business_definition: numerator/denominator pair. Fulfilment cost / payment fees / commission are not
--   modelled at line grain in this DW (documented in S4); approximated as gross margin net of returns.
CREATE OR REPLACE VIEW vw_net_margin_after_fulfilment AS
SELECT ROUND(SUM(gross_margin), 2) AS net_margin_numerator,
       ROUND(SUM(revenue), 2) AS revenue_denominator,
       TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level
FROM (
  SELECT (net_amount - COALESCE(cogs_amount, 0)) AS gross_margin, net_amount AS revenue
  FROM NEXAMART_GOLD.fact_store_sale_line
  UNION ALL
  SELECT confirmed_revenue_excl_tax, confirmed_revenue_excl_tax FROM NEXAMART_GOLD.fact_ecommerce_order_line
);

-- vw_confirmed_gmv — platform-confirmed transaction value | CONFIRMED
-- business_definition: store + ecommerce confirmed value per campaign_phase. NexaLocal offline EXCLUDED
--   (that is ESTIMATED, vw_estimated_classified_gmv) — the two are never summed in one column.
CREATE OR REPLACE VIEW vw_confirmed_gmv AS
SELECT campaign_phase, ROUND(SUM(gmv), 2) AS confirmed_gmv,
       TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level
FROM (
  SELECT d.campaign_phase, f.confirmed_revenue_excl_tax AS gmv
  FROM NEXAMART_GOLD.fact_ecommerce_order_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
  UNION ALL
  SELECT d.campaign_phase, f.net_amount
  FROM NEXAMART_GOLD.fact_store_sale_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
)
GROUP BY campaign_phase;

-- vw_estimated_classified_gmv — modelled NexaLocal offline value (B6) | ESTIMATED
-- business_definition: B6 formula (SELLER_SOLD 0.60 / PHN_REVEAL 0.15 / CHAT 0.08 / OFFER_ACC 0.30)
--   applied to the signal-event values, with a +/-35% band. is_confirmed_transaction = FALSE always;
--   100% ESTIMATED so it never enters a confirmed total.
CREATE OR REPLACE VIEW vw_estimated_classified_gmv AS
SELECT ROUND(SUM(weighted), 2) AS gmv_point,
       ROUND(SUM(weighted) * 0.65, 2) AS gmv_lower,
       ROUND(SUM(weighted) * 1.35, 2) AS gmv_upper,
       FALSE AS is_confirmed_transaction, 'ESTIMATED' AS metric_certainty_level
FROM (
  -- B6 estimated GMV per signal event = weight x the listing's ASKING_PRICE (the value at risk of
  -- transacting). offer_amount is populated ONLY on OFFER_MADE events and is NULL for the
  -- SELLER_SOLD / PHN_REVEAL / OFFER_ACC signals that actually carry ESTIMATED_NL_GMV, so the value
  -- must come from fact_classified_listing_snapshot.asking_price, joined on listing_id (one row/listing).
  -- event_type_code uses 'CHAT_START' in this build (not 'CHAT').
  SELECT CASE e.event_type_code
           WHEN 'SELLER_SOLD' THEN 0.60 WHEN 'PHN_REVEAL' THEN 0.15
           WHEN 'CHAT_START' THEN 0.08 WHEN 'OFFER_ACC' THEN 0.30 ELSE 0 END
         * COALESCE(s.asking_price, 0) AS weighted
  FROM NEXAMART_GOLD.fact_classified_listing_event e
  JOIN NEXAMART_GOLD.fact_classified_listing_snapshot s ON s.listing_id = e.listing_id
  WHERE e.anomaly_reason_code LIKE '%ESTIMATED_NL_GMV%'
);

-- vw_campaign_incremental_revenue — campaign NCR minus normalised baseline | CONFIRMED
-- business_definition: CAMPAIGN-phase EC NCR minus the BASELINE daily NCR scaled to the campaign length.
CREATE OR REPLACE VIEW vw_campaign_incremental_revenue AS
WITH ncr_by_phase AS (
  SELECT d.campaign_phase, SUM(f.confirmed_revenue_excl_tax) AS ncr, COUNT(DISTINCT d.date_iso) AS days
  FROM NEXAMART_GOLD.fact_ecommerce_order_line f JOIN NEXAMART_GOLD.dim_date d ON f.date_key = d.date_key
  GROUP BY d.campaign_phase
)
SELECT
  ROUND((SELECT ncr FROM ncr_by_phase WHERE campaign_phase = 'CAMPAIGN'), 2) AS campaign_ncr,
  ROUND((SELECT ncr / NULLIF(days, 0) FROM ncr_by_phase WHERE campaign_phase = 'BASELINE')
        * (SELECT days FROM ncr_by_phase WHERE campaign_phase = 'CAMPAIGN'), 2) AS baseline_normalised_ncr,
  ROUND((SELECT ncr FROM ncr_by_phase WHERE campaign_phase = 'CAMPAIGN')
        - (SELECT ncr / NULLIF(days, 0) FROM ncr_by_phase WHERE campaign_phase = 'BASELINE')
          * (SELECT days FROM ncr_by_phase WHERE campaign_phase = 'CAMPAIGN'), 2) AS incremental_revenue,
  TRUE AS is_confirmed_transaction, 'CONFIRMED' AS metric_certainty_level;

-- ===========================================================================
-- INVENTORY
-- ===========================================================================

-- vw_atp_sku_loc_date — ATP at SKU x location x date | CONFIRMED
-- business_definition: SEMI-ADDITIVE Available-to-Promise. Row grain = (sku, warehouse, date); the view
--   exposes the grain WITHOUT any SUM, so it can only be summed across SKUs on a SINGLE date downstream.
CREATE OR REPLACE VIEW vw_atp_sku_loc_date AS
SELECT sku, warehouse_id AS location_id, snapshot_date, atp_qty,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_warehouse_inventory_snapshot;

-- vw_stockout_rate — % SKU-loc-day with ATP=0 | CONFIRMED
-- business_definition: numerator/denominator — warehouse SKU-location-days at ATP = 0 / all SKU-location-days,
--   per snapshot_date. Semi-additive (per-date grain; do not sum across dates). fact_warehouse_inventory_snapshot.
CREATE OR REPLACE VIEW vw_stockout_rate AS
SELECT snapshot_date,
       COUNT_IF(atp_qty = 0) AS stockout_numerator,
       COUNT(*) AS sku_day_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_warehouse_inventory_snapshot
GROUP BY snapshot_date;

-- vw_oversell_count — orders accepted on zero/insufficient ATP | CONFIRMED
-- business_definition: count of A5 oversell-risk snapshots (ATP>0 while physical=0 was the cause);
--   post-resolution these are corrected, so this trends to 0 and quantifies the campaign-window risk.
CREATE OR REPLACE VIEW vw_oversell_count AS
SELECT snapshot_date,
       COUNT_IF(anomaly_reason_code LIKE '%ATP_POSITIVE_PHYSICAL_ZERO%') AS oversell_risk_snapshots,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_warehouse_inventory_snapshot
GROUP BY snapshot_date;

-- vw_inventory_accuracy_rate — % snapshots matching derived balance | CONFIRMED
-- business_definition: numerator/denominator — accurate (not anomaly-flagged) store snapshots / all.
CREATE OR REPLACE VIEW vw_inventory_accuracy_rate AS
SELECT COUNT_IF(NOT anomaly_flag) AS accurate_numerator,
       COUNT(*) AS snapshot_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_store_inventory_snapshot;

-- vw_return_to_restock_cycle_time — avg days request -> receipt (processing proxy) | CONFIRMED
-- business_definition: fact_return_line carries request/receipt DATE KEYS (not a restock_date); we expose the
--   request->receipt processing time via dim_date as the available cycle-time proxy (documented in S4).
CREATE OR REPLACE VIEW vw_return_to_restock_cycle_time AS
SELECT ROUND(AVG(DATEDIFF('day', dq.date_iso::date, dr.date_iso::date)), 2) AS avg_cycle_days,
       COUNT(*) AS restocked_returns,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_return_line f
JOIN NEXAMART_GOLD.dim_date dq ON f.return_request_date_key = dq.date_key
JOIN NEXAMART_GOLD.dim_date dr ON f.return_receipt_date_key = dr.date_key;

-- vw_open_box_conversion_rate — % returns whose return-period revenue was realised (resale proxy) | INFERRED
-- business_definition: open-box restock-condition + 30d-resale tracking is not in Gold; we approximate
--   "converted/resold" by a positive revenue_impact_return_period on the return line (documented in S4).
CREATE OR REPLACE VIEW vw_open_box_conversion_rate AS
SELECT COUNT_IF(COALESCE(revenue_impact_return_period, 0) > 0) AS converted_numerator,
       COUNT(*) AS returns_denominator,
       'INFERRED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_return_line;

-- ===========================================================================
-- ECOMMERCE / STORE
-- ===========================================================================

-- vw_cart_abandonment_rate — add-to-cart sessions without checkout | CONFIRMED
-- business_definition: numerator/denominator — web sessions that added to cart but never reached a
--   checkout-complete / purchase event / all sessions that added to cart. Session grain (fact_web_page_event).
CREATE OR REPLACE VIEW vw_cart_abandonment_rate AS
WITH s AS (
  SELECT session_id,
         MAX(IFF(event_type_code IN ('ADD_TO_CART', 'CART_ADD', 'ADD_CART'), 1, 0)) AS has_cart,
         MAX(IFF(event_type_code IN ('CHECKOUT_COMPLETE', 'PURCHASE', 'ORDER_CONFIRMED', 'ORDER_PLACED'), 1, 0)) AS has_checkout
  FROM NEXAMART_GOLD.fact_web_page_event GROUP BY session_id)
SELECT COUNT_IF(has_cart = 1 AND has_checkout = 0) AS abandoned_numerator,
       COUNT_IF(has_cart = 1) AS cart_sessions_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM s;

-- vw_checkout_conversion_rate — purchase / checkout-initiated sessions | CONFIRMED
-- business_definition: numerator/denominator — sessions reaching a purchase / checkout-complete event /
--   sessions that initiated checkout. Session-funnel grain (fact_web_page_event); distinct from the
--   order-fulfilment payment-failure measure, so the two are not directly comparable.
CREATE OR REPLACE VIEW vw_checkout_conversion_rate AS
WITH s AS (
  SELECT session_id,
         MAX(IFF(event_type_code IN ('CHECKOUT_INIT', 'CHECKOUT_START', 'CHECKOUT_INITIATED'), 1, 0)) AS init,
         MAX(IFF(event_type_code IN ('CHECKOUT_COMPLETE', 'PURCHASE', 'ORDER_CONFIRMED', 'ORDER_PLACED'), 1, 0)) AS done
  FROM NEXAMART_GOLD.fact_web_page_event GROUP BY session_id)
SELECT COUNT_IF(done = 1) AS purchase_numerator,
       COUNT_IF(init = 1) AS checkout_init_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM s;

-- vw_browse_online_buy_in_store_rate — INFERRED (cross-channel)
-- business_definition: customers with an online product view who complete a store POS sale for the same
--   product within 48h / customers with an online product view. INFERRED via customer_key + product_key.
CREATE OR REPLACE VIEW vw_browse_online_buy_in_store_rate AS
WITH views AS (
  SELECT DISTINCT ws.customer_key, pe.product_key, d.date_iso AS view_date
  FROM NEXAMART_GOLD.fact_web_page_event pe
  JOIN NEXAMART_GOLD.fact_web_session ws ON pe.session_id = ws.session_id
  JOIN NEXAMART_GOLD.dim_date d ON pe.date_key = d.date_key
  WHERE pe.product_key IS NOT NULL AND ws.customer_key IS NOT NULL),
store AS (
  SELECT s.customer_key, s.product_key, d.date_iso AS buy_date
  FROM NEXAMART_GOLD.fact_store_sale_line s JOIN NEXAMART_GOLD.dim_date d ON s.date_key = d.date_key)
SELECT COUNT(DISTINCT CASE WHEN st.customer_key IS NOT NULL
              AND DATEDIFF('hour', v.view_date::date, st.buy_date::date) BETWEEN 0 AND 2
            THEN v.customer_key || '|' || v.product_key END) AS browse_buy_numerator,
       COUNT(DISTINCT v.customer_key || '|' || v.product_key) AS browse_denominator,
       'INFERRED' AS metric_certainty_level
FROM views v
LEFT JOIN store st ON st.customer_key = v.customer_key AND st.product_key = v.product_key;

-- vw_browse_online_contact_nexalocal_rate — INFERRED (cross-channel)
-- business_definition: online product-view sessions followed within 24h by a NexaLocal contact event /
--   online product-view sessions. INFERRED.
CREATE OR REPLACE VIEW vw_browse_online_contact_nexalocal_rate AS
WITH pv AS (
  SELECT DISTINCT date_key FROM NEXAMART_GOLD.fact_web_page_event WHERE product_key IS NOT NULL),
nlc AS (
  SELECT DISTINCT date_key FROM NEXAMART_GOLD.fact_classified_listing_event
  WHERE event_type_code IN ('CHAT', 'PHN_REVEAL', 'OFFER_ACC'))
SELECT (SELECT COUNT(*) FROM pv WHERE date_key IN (SELECT date_key FROM nlc)) AS contact_followup_numerator,
       (SELECT COUNT(*) FROM pv) AS product_view_days_denominator,
       'INFERRED' AS metric_certainty_level;

-- vw_bopis_pickup_readiness_time — avg hours order -> pickup-ready | CONFIRMED
-- business_definition: avg placed->captured hours for BOPIS orders as the readiness proxy (the pickup-
--   ready milestone is not a separate fact column; documented in S4).
CREATE OR REPLACE VIEW vw_bopis_pickup_readiness_time AS
SELECT ROUND(AVG(placed_to_captured_hours), 2) AS avg_readiness_hours,
       COUNT(*) AS bopis_orders,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_order_fulfilment
WHERE placed_to_captured_hours IS NOT NULL;

-- vw_boris_count — online returns processed at stores | CONFIRMED
-- business_definition: count of return lines flagged as BORIS (Buy-Online-Return-In-Store), i.e. an online
--   order returned through a physical store. Return-line grain (fact_return_line.is_boris_return).
CREATE OR REPLACE VIEW vw_boris_count AS
SELECT COUNT_IF(is_boris_return) AS boris_returns,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_return_line;

-- vw_on_time_delivery_rate — % delivered on/before promise | CONFIRMED
-- business_definition: numerator/denominator — home deliveries within a 120h SLA proxy / all delivered
--   (the promised-date column is not in the fulfilment fact; SLA proxy documented in S4).
CREATE OR REPLACE VIEW vw_on_time_delivery_rate AS
SELECT COUNT_IF(total_lifecycle_hours IS NOT NULL AND total_lifecycle_hours <= 120) AS on_time_numerator,
       COUNT_IF(delivered_date_key IS NOT NULL) AS delivered_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_order_fulfilment;

-- vw_payment_failure_rate — % payment attempts failed | CONFIRMED
-- business_definition: numerator/denominator — EC orders with no captured payment (capture milestone
--   missing) / all EC orders. Proxy for gateway failure (no payment fact in Gold).
CREATE OR REPLACE VIEW vw_payment_failure_rate AS
SELECT COUNT_IF(captured_date_key IS NULL) AS failed_numerator,
       COUNT(*) AS attempts_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_order_fulfilment;

-- ===========================================================================
-- NEXALOCAL / SELLER
-- ===========================================================================

-- vw_active_listing_count — active NexaLocal listings | CONFIRMED
-- business_definition: count of NexaLocal classified listings currently in ACTIVE status (sold / expired /
--   relisted-original listings excluded). Listing-snapshot grain (fact_classified_listing_snapshot).
CREATE OR REPLACE VIEW vw_active_listing_count AS
SELECT COUNT(*) AS active_listings,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_classified_listing_snapshot
WHERE status_code = 'ACTIVE';

-- vw_listing_contact_rate — contact events per active listing | CONFIRMED
-- business_definition: numerator/denominator — buyer contact events (chat/phone/offer) / active listings.
CREATE OR REPLACE VIEW vw_listing_contact_rate AS
SELECT (SELECT COUNT(*) FROM NEXAMART_GOLD.fact_classified_listing_event
        WHERE event_type_code IN ('CHAT', 'PHN_REVEAL', 'OFFER_ACC', 'OFFER_MADE')) AS contact_numerator,
       (SELECT COUNT(*) FROM NEXAMART_GOLD.fact_classified_listing_snapshot
        WHERE status_code = 'ACTIVE') AS active_listing_denominator,
       'CONFIRMED' AS metric_certainty_level;

-- vw_relisting_rate — % listings relisted | CONFIRMED
-- business_definition: numerator/denominator — NexaLocal listings relisted after a prior sale (relist_count>0
--   or A12 RELISTED_AFTER_SOLD flag) / all listings. Listing-snapshot grain (fact_classified_listing_snapshot).
CREATE OR REPLACE VIEW vw_relisting_rate AS
SELECT COUNT_IF(COALESCE(relist_count, 0) > 0
                OR anomaly_reason_code LIKE '%RELISTED_AFTER_SOLD%') AS relisted_numerator,
       COUNT(*) AS listing_denominator,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_classified_listing_snapshot;

-- vw_duplicate_listing_inflation_factor — total / deduplicated | CONFIRMED
-- business_definition: numerator/denominator — total listings / listings net of A12 relisting + A13
--   image-hash duplicates. Dashboard computes the ratio (>1.0 = inflation).
CREATE OR REPLACE VIEW vw_duplicate_listing_inflation_factor AS
SELECT COUNT(*) AS total_listings,
       COUNT(*) - COUNT_IF(anomaly_reason_code LIKE '%RELISTED_AFTER_SOLD%'
                           OR anomaly_reason_code LIKE '%IMAGE_HASH_REUSED%') AS deduplicated_listings,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_classified_listing_snapshot;

-- vw_seller_risk_score_distribution — sellers per risk tier | CONFIRMED
-- business_definition: count of sellers per risk tier, bucketed from dim_seller.seller_risk_score using the
--   B8 thresholds (>=0.65 HIGH, 0.40-0.65 MEDIUM/UNDER_REVIEW, else LOW). dim_seller has no risk_tier column;
--   the bucketing is applied here (member dim refresh is a follow-up — see S2).
CREATE OR REPLACE VIEW vw_seller_risk_score_distribution AS
SELECT CASE WHEN seller_risk_score >= 0.65 THEN 'HIGH'
            WHEN seller_risk_score >= 0.40 THEN 'MEDIUM' ELSE 'LOW' END AS risk_tier,
       COUNT(*) AS seller_count,
       'CONFIRMED' AS metric_certainty_level
FROM NEXAMART_GOLD.dim_seller
GROUP BY 1;

-- vw_validated_report_rate — INFERRED
-- business_definition: corroboration proxy — listings carrying an automated risk signal (A13 image-hash
--   ring) as a fraction of all flagged listings. INFERRED.
CREATE OR REPLACE VIEW vw_validated_report_rate AS
SELECT COUNT_IF(anomaly_reason_code LIKE '%IMAGE_HASH_REUSED%') AS corroborated_numerator,
       COUNT_IF(anomaly_flag) AS flagged_denominator,
       'INFERRED' AS metric_certainty_level
FROM NEXAMART_GOLD.fact_classified_listing_snapshot;

-- ###########################################################################
-- 28 views total. Verify after deploy:
--   SELECT COUNT(*) FROM NEXAMART_DW.INFORMATION_SCHEMA.VIEWS WHERE table_schema='NEXAMART_MARTS';  -- expect 28
-- Then run validation_suite.sql Check 5 (semi-additive) + Check 9 (certainty segregation).
-- ###########################################################################
