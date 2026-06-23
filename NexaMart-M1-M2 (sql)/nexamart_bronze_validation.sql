USE DATABASE NEXAMART_DB;
USE WAREHOUSE NEXAMART_WH;
USE SCHEMA NEXAMART_BRONZE;

WITH expected_counts (table_name, expected_rows) AS (
    -- Define the expected row counts for all 61 tables as per the data dictionary
    SELECT * FROM VALUES
    ('CL_CUSTOMERS', 2501), ('CL_LOYALTY_TIERS', 4), ('CL_LOYALTY_TRANSACTIONS', 2860),
    ('CS_AGENTS', 25), ('CS_CASE_EVENTS', 225), ('CS_CASES', 129), ('CS_COMPLAINT_CATEGORIES', 12),
    ('DC_CARRIERS', 5), ('DC_DELIVERY_EVENTS', 3542), ('DC_EVENT_TYPES', 10), ('DC_SHIPMENTS', 771),
    ('EC_DELIVERY_METHODS', 5), ('EC_ORDER_LINES', 1840), ('EC_ORDER_STATUS_CODES', 9),
    ('EC_ORDER_STATUS_HISTORY', 3307), ('EC_ORDERS', 963), ('NL_CATEGORIES', 13), ('NL_EVENT_TYPES', 14),
    ('NL_LISTING_EVENTS', 38706), ('NL_LISTINGS', 1253), ('NL_USER_ACCOUNTS', 356),
    ('PC_BRANDS', 30), ('PC_CATEGORIES', 27), ('PC_CONDITION_CODES', 10), ('PC_PRICE_HISTORY', 0),
    ('PC_PRODUCTS', 65), ('PG_INSTRUMENT_TYPES', 12), ('PG_STATUS_CODES', 8), ('PG_TRANSACTIONS', 963),
    ('POS_CASHIERS', 160), ('POS_PAYMENT_METHODS', 7), ('POS_STATUS_CODES', 6), ('POS_STORES', 20),
    ('POS_TRANSACTION_LINES', 24507), ('POS_TRANSACTIONS', 10868), ('RR_REFUND_EVENTS', 74),
    ('RR_RETURN_REASONS', 12), ('RR_RETURN_RECEIPTS', 74), ('RR_RETURN_REQUESTS', 74), ('RV_REVIEWS', 377),
    ('SI_INVENTORY_MOVEMENTS', 438018), ('SI_INVENTORY_SNAPSHOTS', 216645), ('SI_MOVEMENT_TYPES', 10),
    ('TS_FULFILMENT_EVENTS', 593), ('TS_MARKETPLACE_ORDERS', 252), ('TS_REPORT_REASONS', 11),
    ('TS_RISK_SIGNALS', 58), ('TS_SAFETY_REPORTS', 91), ('TS_SELLER_LISTINGS', 400),
    ('TS_SELLER_STATUS_CODES', 5), ('TS_SELLER_TYPES', 4), ('TS_SELLERS', 100), ('TS_SIGNAL_TYPES', 10),
    ('WH_INBOUND_RECEIPTS', 57), ('WH_INVENTORY_MOVEMENTS', 30437), ('WH_INVENTORY_SNAPSHOTS', 38610),
    ('WH_MOVEMENT_TYPES', 12), ('WH_WAREHOUSES', 3), ('WS_EVENT_TYPES', 17), ('WS_PAGE_EVENTS', 20757),
    ('WS_SESSIONS', 3370)
),
actual_counts AS (
    -- Retrieve the actual row counts from Snowflake's system metadata (INFORMATION_SCHEMA)
    SELECT table_name, row_count AS actual_rows
    FROM INFORMATION_SCHEMA.TABLES
    WHERE table_schema = 'NEXAMART_BRONZE'
)
-- Join expected and actual counts to determine the PASS/FAIL validation status
SELECT 
    e.table_name,
    e.expected_rows,
    COALESCE(a.actual_rows, 0) AS actual_rows,
    CASE 
        WHEN e.expected_rows = COALESCE(a.actual_rows, 0) THEN 'PASS'
        ELSE 'FAIL'
    END AS validation_status
FROM expected_counts e
LEFT JOIN actual_counts a ON e.table_name = a.table_name
ORDER BY 
    CASE WHEN validation_status = 'FAIL' THEN 0 ELSE 1 END,
    e.table_name;

