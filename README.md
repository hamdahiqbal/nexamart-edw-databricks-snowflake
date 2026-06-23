<div align="center">

# NEXAMART ENTERPRISE DATA WAREHOUSE
### One Marketplace, Many Truths

**PROJECT ARCHITECTURE AND IMPLEMENTATION REPORT**
Bronze Ingestion, Silver Transformation, Gold Dimensional Model

</div>

## Project Overview
The NexaMart Enterprise Data Warehouse project involves extracting data from legacy operational silos into a highly governed, fully scalable Medallion Architecture using Databricks PySpark for complex transformations and Snowflake NEXAMART_DB as the underlying data platform.

| Field | Detail |
|---|---|
| **Project Scope** | End to End Enterprise Data Warehouse Implementation |
| **Tech Stack** | Databricks PySpark and Snowflake NEXAMART_DB and Power BI |
| **Architecture** | Bronze to Silver to Gold Medallion \| Kimball Dimensional Model |
| **Bronze Layer** | 61 of 61 tables ingested \| 843304 rows \| 100% source to target parity |
| **Silver Layer** | 10 transformation pipelines \| 16 structural anomalies isolated \| 8 ambiguous patterns modelled |
| **Gold Layer** | 15 Conformed Dimensions \| 14 Fact Tables \| 750948 curated records |
| **Marts Layer** | Certainty segregated KPI views for Executive Dashboards |

## Repository Structure

The project is organized into modular directories representing the complete data engineering lifecycle:

```text
NexaMart-M1-M2 (dashboard)/
    nexamart_dashboard.pbix
    screenshots/
NexaMart-M1-M2 (html)/
    bronze-ingestion-m1.html
    silver-*.html
    gold-*.html
    anomaly-resolution-m2.html
    validation-m2.html
NexaMart-M1-M2 (report)/
    MILESTONE-1-REPORT.md
    MILESTONE-2-REPORT.md
    *.jpeg
NexaMart-M1-M2 (source)/
    nexamart_operations db.db
    nexamart_data_dictionary.xlsx
    Reference Documentation
NexaMart-M1-M2 (sql)/
    nexamart_setup.sql
    anomaly_discovery.sql
    anomaly_resolution.sql
    kpi_views.sql
    validation_suite.sql
```

## Key Deliverables and Documentation

This repository is heavily documented. Please refer to the primary milestone reports for deep dive technical breakdowns:

* **[Milestone 1 Report: Architecture and Medallion Pipeline](NexaMart-M1-M2%20(report)/MILESTONE-1-REPORT.md)**
  Includes pipeline configurations, schema mappings, NEXAMART_DB Snowflake setup, Bronze ingestion logic, Silver standardisation, and the Gold Kimball Model implementation.

* **[Milestone 2 Report: Anomaly Resolution and Dashboards](NexaMart-M1-M2%20(report)/MILESTONE-2-REPORT.md)**
  Details the resolution of 24 severe data anomalies without deleting records under the Zero Deletion Policy, Gold rebuild logic, certainty segregated KPI logic, and final Executive Dashboard outputs.

* **[Executive Briefing Presentation Script](nexamart_presentation_content.md)** and **[Executive Slide Deck (PPTX)](#insert_your_ppt_link_here)**
  A high level executive slide script and presentation deck mapping the business value of the data warehouse pipeline directly to dashboard outputs.

## Technical Constraints and Policies
* **Strict Isolation:** All testing and transformations occur logically separated.
* **Zero Deletion:** Logically malformed records are flagged and quarantined in Silver, never deleted.
* **Certainty Segregation:** Estimated metrics are modeled entirely separately from Confirmed Corporate Revenue to prevent cross channel double counting.
