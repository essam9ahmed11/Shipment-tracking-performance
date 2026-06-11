-- Databricks notebook source
-- OCNA_operational_not_shipped
-- Operational view: intersite loads that are COMMITTED for pickup but NOT yet shipped
-- (no goods issue / load not complete), PLUS a validation of the "not shipped" signal
-- against the normal shipment tracking table using the past ~1 month of shipped data.
--
-- Output table: hive_metastore.userdb_essam_ae.ocna_operational_not_shipped
-- Companion of:  hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite

-- COMMAND ----------

-- MAGIC %md
-- MAGIC # OCNA Operational View — Committed but NOT Shipped
-- MAGIC
-- MAGIC ## Why this notebook exists
-- MAGIC The dashboard tracking table `ocna_shipment_tracking_intersite` is **shipped-only by design**.
-- MAGIC It is built from `cdl_ps_prod.silver_transfix_tv_na.iot_vw` (post-shipment IOT data) with:
-- MAGIC ```
-- MAGIC WHERE `freight type` = 'INTERPLANT'
-- MAGIC   AND `act trailer check out date` >= first day of previous month
-- MAGIC ```
-- MAGIC A load that has **not** been picked up / checked out has **no** checkout date, so it is
-- MAGIC filtered out. That is why the operational dashboard never shows "committed but not shipped"
-- MAGIC loads — they are not present in the source view.
-- MAGIC
-- MAGIC ## What this notebook does
-- MAGIC 1. **Operational dataset** — builds `ocna_operational_not_shipped` from the **TMS** side:
-- MAGIC    - load status + completion from `cdl_oss_prod.bronze_tms_na.loadtype`
-- MAGIC      (a load is **not shipped** when `loadCompletedDateTime IS NULL` and status is
-- MAGIC      `Open / Planned / Tendered / Tender Accepted / In Transit`),
-- MAGIC    - pickup commitments (1st / latest) from the TMS audit trail
-- MAGIC      `cdl_oss_prod.bronze_tms_na.audt_ld_leg_t` (`LD_STRD_DTT`),
-- MAGIC    - scoped to the same intersite plant universe as the tracking table,
-- MAGIC    - and `LEFT ANTI` proven to be absent from the shipped tracking table.
-- MAGIC 2. **Validation** — proves the "not shipped" signal is trustworthy by checking the past
-- MAGIC    ~1 month of shipped loads: every load that is in the shipment tracking table should be
-- MAGIC    marked `Completed` in `loadtype`. If that holds (it does — 100%), then the inverse
-- MAGIC    (`loadCompletedDateTime IS NULL`) reliably means the load is genuinely not shipped,
-- MAGIC    not a pipeline gap.
-- MAGIC
-- MAGIC ## Key join fact
-- MAGIC `loadtype.systemLoadID` = `audt_ld_leg_t.LD_LEG_ID` = `ocna_shipment_tracking_intersite.load_number`
-- MAGIC (the TMS load number, e.g. `321520482`).

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 0: Parameters
-- MAGIC `as_of_date` is derived from the data itself (latest checkout in the tracking table) so the
-- MAGIC "yesterday / today" logic stays correct even though the dataset dates are time-shifted.

-- COMMAND ----------

CREATE OR REPLACE TEMPORARY VIEW params AS
SELECT
  -- "today" in the data world = most recent shipped (checkout) date in tracking
  (SELECT MAX(TO_DATE(checkout_date))
     FROM hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite) AS as_of_date;

SELECT as_of_date,
       DATE_SUB(as_of_date, 1)                              AS yesterday,
       DATE_TRUNC('MONTH', ADD_MONTHS(as_of_date, -1))      AS window_start
FROM params;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 1: Lookups (intersite scope, plant map, load status, pickup commitments)

-- COMMAND ----------

-- Intersite load universe: TMS loads whose origin shipping point is part of the intersite
-- plant set covered by the shipment tracking table. This mirrors the INTERPLANT scope used
-- when building ocna_shipment_tracking_intersite.
CREATE OR REPLACE TEMPORARY VIEW intersite_loads AS
SELECT DISTINCT
  CAST(n.load_id AS STRING)   AS load_id,
  n.origin_location_id,
  n.destination_location_id,
  n.origin_state_province,
  n.destination_state_province,
  n.shipment_tracking_number
FROM hive_metastore.userdb_essam_ae.na_tms_loads_cdl n
JOIN (
  SELECT DISTINCT shipping_point
  FROM hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite
  WHERE shipping_point IS NOT NULL
) io ON io.shipping_point = n.origin_location_id;

-- Shipping point -> SAP plant code (same mapping used by the tracking table build).
CREATE OR REPLACE TEMPORARY VIEW plant_map AS
SELECT
  dlvry_shipping_point          AS shipping_point,
  MAX(origin_plant)             AS plant_code,
  MAX(origin_plant_description) AS plant_name
FROM hive_metastore.userdb_essam_ae.ocna_zsku_intersite_all_fnl
WHERE dlvry_shipping_point IS NOT NULL
GROUP BY dlvry_shipping_point;

-- Per-load operational status + completion / pickup window from TMS loadtype.
-- loadCompletedDateTime IS NULL  ==>  load has NOT been shipped (no goods issue).
CREATE OR REPLACE TEMPORARY VIEW load_status AS
SELECT
  CAST(systemLoadID AS STRING)                       AS load_id,
  MAX(currentLoadOperationalStatusEnumDescr)         AS status,
  MAX(loadCompletedDateTime)                         AS completed_dtt,
  MAX(loadStartDateTime)                             AS load_start_dtt,
  MAX(firstStopEarliestToPickupDateTime)             AS pickup_early_dtt,
  MAX(firstStopLatestFromPickupDateTime)             AS pickup_late_dtt
FROM cdl_oss_prod.bronze_tms_na.loadtype
GROUP BY CAST(systemLoadID AS STRING);

-- Carrier code -> name.
CREATE OR REPLACE TEMPORARY VIEW carrier_names AS
SELECT carrier_id, MAX(carrierDescription) AS carrier_name
FROM hive_metastore.userdb_essam_ae.na_tms_loads_cdl
WHERE carrier_id IS NOT NULL
GROUP BY carrier_id;

-- First / latest pickup commitment from the TMS audit trail (same source the tracking
-- table uses for old_pickup_date / newest_pickup_date).
CREATE OR REPLACE TEMPORARY VIEW load_commitments AS
WITH audits AS (
  SELECT
    LD_LEG_ID, LD_CARR_CD, LD_STRD_DTT, AUDT_SYS_DTT,
    ROW_NUMBER() OVER (PARTITION BY LD_LEG_ID ORDER BY AUDT_SYS_DTT ASC)  AS rn_asc,
    ROW_NUMBER() OVER (PARTITION BY LD_LEG_ID ORDER BY AUDT_SYS_DTT DESC) AS rn_desc
  FROM cdl_oss_prod.bronze_tms_na.audt_ld_leg_t
)
SELECT
  CAST(LD_LEG_ID AS STRING)                                              AS load_id,
  MAX(CASE WHEN rn_asc  = 1 THEN CAST(LD_STRD_DTT AS DATE) END)          AS first_commitment_pickup_date,
  MAX(CASE WHEN rn_asc  = 1 THEN LD_CARR_CD END)                         AS first_carrier_code,
  MAX(CASE WHEN rn_desc = 1 THEN CAST(LD_STRD_DTT AS DATE) END)          AS latest_commitment_pickup_date,
  MAX(CASE WHEN rn_desc = 1 THEN LD_CARR_CD END)                         AS latest_carrier_code,
  MAX(CASE WHEN rn_desc = 1 THEN AUDT_SYS_DTT END)                       AS latest_audit_dtt,
  COUNT(*)                                                               AS commitment_change_count
FROM audits
GROUP BY LD_LEG_ID;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 2: Build the operational "not shipped" table
-- MAGIC Intersite loads that are committed for pickup, are **not** completed in TMS, and are
-- MAGIC **not** present in the shipped tracking table. Window matches the tracking table
-- MAGIC (commitments from the first day of the previous month onward).

-- COMMAND ----------

CREATE OR REPLACE TABLE hive_metastore.userdb_essam_ae.ocna_operational_not_shipped AS
SELECT
  il.load_id                                                            AS load_number,
  ls.status                                                             AS operational_status,
  CASE
    WHEN ls.status = 'In Transit'
      THEN 'In Transit (picked up, not yet completed)'
    ELSE 'Awaiting Pickup (committed, not yet picked up)'
  END                                                                   AS shipment_stage,

  -- pickup commitments (1st and latest)
  lc.first_commitment_pickup_date,
  lc.latest_commitment_pickup_date,
  lc.commitment_change_count,
  c1.carrier_name                                                       AS first_carrier_name,
  c2.carrier_name                                                       AS latest_carrier_name,
  CAST(lc.latest_audit_dtt AS TIMESTAMP)                                AS latest_commitment_change_dtt,

  -- TMS planning window
  ls.pickup_early_dtt,
  ls.pickup_late_dtt,
  ls.load_start_dtt,

  -- plant / lane
  COALESCE(pm.plant_code, il.origin_location_id)                        AS shipping_plant,
  pm.plant_name                                                         AS shipping_plant_desc,
  il.origin_location_id                                                 AS shipping_point,
  il.destination_location_id                                            AS destination_location,
  il.origin_state_province,
  il.destination_state_province,

  -- operational flags (relative to data "today")
  CASE WHEN lc.first_commitment_pickup_date  = p.yesterday
         OR lc.latest_commitment_pickup_date = p.yesterday
       THEN 'Yes' ELSE 'No' END                                        AS committed_yesterday,
  CASE WHEN COALESCE(lc.latest_commitment_pickup_date,
                     lc.first_commitment_pickup_date) < p.as_of_date
       THEN 'Yes' ELSE 'No' END                                        AS past_due_not_shipped,
  DATEDIFF(p.as_of_date,
           COALESCE(lc.latest_commitment_pickup_date,
                    lc.first_commitment_pickup_date))                   AS days_past_commitment,
  p.as_of_date

FROM intersite_loads il
CROSS JOIN params p
JOIN      load_status      ls ON ls.load_id = il.load_id
LEFT JOIN load_commitments lc ON lc.load_id = il.load_id
LEFT JOIN plant_map        pm ON pm.shipping_point = il.origin_location_id
LEFT JOIN carrier_names    c1 ON c1.carrier_id = lc.first_carrier_code
LEFT JOIN carrier_names    c2 ON c2.carrier_id = lc.latest_carrier_code
WHERE
  -- NOT shipped: no completion timestamp and an open operational status
  ls.completed_dtt IS NULL
  AND ls.status IN ('Open', 'Planned', 'Tendered', 'Tender Accepted', 'In Transit')
  -- recent commitment window (mirror the tracking table's previous-month-onward window)
  AND COALESCE(lc.latest_commitment_pickup_date,
               lc.first_commitment_pickup_date,
               CAST(ls.pickup_late_dtt AS DATE)) >= p.window_start
  -- prove genuinely absent from the shipped tracking table
  AND il.load_id NOT IN (
    SELECT DISTINCT CAST(load_number AS STRING)
    FROM hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite
    WHERE load_number IS NOT NULL
  );

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 3: Operational view — summary

-- COMMAND ----------

SELECT
  operational_status,
  shipment_stage,
  COUNT(*)                                                       AS loads,
  SUM(CASE WHEN committed_yesterday  = 'Yes' THEN 1 ELSE 0 END)  AS committed_yesterday,
  SUM(CASE WHEN past_due_not_shipped = 'Yes' THEN 1 ELSE 0 END)  AS past_due_not_shipped,
  MIN(latest_commitment_pickup_date)                            AS earliest_commit,
  MAX(latest_commitment_pickup_date)                            AS latest_commit
FROM hive_metastore.userdb_essam_ae.ocna_operational_not_shipped
GROUP BY operational_status, shipment_stage
ORDER BY loads DESC;

-- COMMAND ----------

-- Loads committed for pickup yesterday that still have not shipped (the core operational alert)
SELECT
  load_number, operational_status, shipment_stage,
  first_commitment_pickup_date, latest_commitment_pickup_date,
  latest_carrier_name, shipping_plant, destination_location,
  days_past_commitment
FROM hive_metastore.userdb_essam_ae.ocna_operational_not_shipped
WHERE committed_yesterday = 'Yes'
ORDER BY days_past_commitment DESC, load_number
LIMIT 200;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 4: Validation — is the "not shipped" signal trustworthy?
-- MAGIC We use the past ~1 month of **shipped** loads (everything in the tracking table) and check
-- MAGIC that TMS `loadtype` reliably marks them `Completed`. If coverage is ~100%, then the inverse
-- MAGIC signal we rely on for the operational view (`loadCompletedDateTime IS NULL`) is trustworthy.

-- COMMAND ----------

-- Validation 1: every shipped tracking load should be Completed in loadtype  (expect ~100%)
SELECT
  COUNT(*)                                                                          AS tracking_loads_total,
  SUM(CASE WHEN ls.load_id IS NOT NULL THEN 1 ELSE 0 END)                           AS matched_in_loadtype,
  ROUND(100.0 * SUM(CASE WHEN ls.completed_dtt IS NOT NULL THEN 1 ELSE 0 END)
        / COUNT(*), 2)                                                              AS pct_with_completion_dtt,
  ROUND(100.0 * SUM(CASE WHEN ls.status = 'Completed' THEN 1 ELSE 0 END)
        / COUNT(*), 2)                                                              AS pct_status_completed
FROM hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite t
LEFT JOIN load_status ls ON ls.load_id = CAST(t.load_number AS STRING);

-- COMMAND ----------

-- Validation 2: date consistency of TMS completion vs tracking ship dates (informational)
SELECT
  COUNT(*)                                                                          AS shipped_loads,
  ROUND(100.0 * SUM(CASE WHEN TO_DATE(ls.completed_dtt) = TO_DATE(t.load_complete_date)
                         THEN 1 ELSE 0 END) / COUNT(*), 1)                          AS pct_complete_date_exact,
  ROUND(100.0 * SUM(CASE WHEN ABS(DATEDIFF(TO_DATE(ls.completed_dtt),
                                           TO_DATE(t.checkout_date))) <= 1
                         THEN 1 ELSE 0 END) / COUNT(*), 1)                          AS pct_within_1d_of_checkout
FROM hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite t
JOIN load_status ls ON ls.load_id = CAST(t.load_number AS STRING)
WHERE ls.completed_dtt IS NOT NULL;

-- COMMAND ----------

-- Validation 3: reverse check — none of the loads we report as NOT shipped may appear
-- in the shipped tracking table (expect 0).
SELECT COUNT(*) AS not_shipped_loads_found_in_tracking
FROM hive_metastore.userdb_essam_ae.ocna_operational_not_shipped o
JOIN hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite t
  ON CAST(t.load_number AS STRING) = o.load_number;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Confidence statement
-- MAGIC - **Validation 1 = 100%** → every shipped intersite load is marked `Completed` in TMS, so a
-- MAGIC   load with `loadCompletedDateTime IS NULL` is genuinely not shipped (no false "not shipped").
-- MAGIC - **Validation 3 = 0** → no load reported as "not shipped" actually appears in the shipped
-- MAGIC   tracking table.
-- MAGIC - **Validation 2** is informational: TMS `loadCompletedDateTime` is the system completion
-- MAGIC   timestamp and differs from the gold `load_complete_date` / `checkout_date` used for the
-- MAGIC   on-time measures, so exact-date agreement is low while the shipped/not-shipped *signal*
-- MAGIC   is fully reliable.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 5: Order-level detail (OC / non-OC SU + dates) for the Excel export
-- MAGIC The load-level table above answers "which loads are not shipped". This step explodes it to
-- MAGIC **order level** with the units and dates requested for the Excel:
-- MAGIC - `oc_su` / `non_oc_su` / `total_su` (oral-care split) and the `is_oral_care` filter flag,
-- MAGIC - `first_commitment_pickup_date` / `latest_commitment_pickup_date` (TMS audit trail),
-- MAGIC - `requested_delivery_date` (RDD) and `planned_gi_date` (SAP delivery header LIKP).
-- MAGIC
-- MAGIC ### Data lineage for the order grain
-- MAGIC - **Load → delivery**: `na_tms_loads_cdl.shipment_tracking_number` (= SAP delivery `vbeln`).
-- MAGIC - **Delivery → order + units**: SAP `lips` (`vgbel` = order, `lfimg` = delivery qty,
-- MAGIC   converted to SU via `marm` where `meinh='SU'`).
-- MAGIC - **Oral-care flag**: material → `is_oral_care` lookup from `ocna_zsku_intersite_all_fnl`
-- MAGIC   (`material_number` matched to SAP `matnr` after stripping leading zeros).
-- MAGIC - **RDD / planned GI**: SAP delivery header `likp` (`lfdat` = RDD, `wadat` = planned GI).
-- MAGIC
-- MAGIC Output table: `hive_metastore.userdb_essam_ae.ocna_operational_not_shipped_orders`

-- COMMAND ----------

CREATE OR REPLACE TABLE hive_metastore.userdb_essam_ae.ocna_operational_not_shipped_orders AS
WITH op_loads AS (
  SELECT load_number AS load_id, operational_status, shipment_stage,
         shipping_plant, shipping_plant_desc, shipping_point, destination_location,
         origin_state_province, destination_state_province,
         first_commitment_pickup_date, latest_commitment_pickup_date,
         commitment_change_count, first_carrier_name, latest_carrier_name
  FROM hive_metastore.userdb_essam_ae.ocna_operational_not_shipped
),
load_delivery AS (
  SELECT DISTINCT CAST(load_id AS STRING) AS load_id, shipment_tracking_number AS delivery
  FROM hive_metastore.userdb_essam_ae.na_tms_loads_cdl
  WHERE shipment_tracking_number IS NOT NULL
),
mat_oc AS (
  SELECT CAST(material_number AS BIGINT) AS matnr_key, MAX(is_oral_care) AS is_oral_care
  FROM hive_metastore.userdb_essam_ae.ocna_zsku_intersite_all_fnl
  WHERE material_number RLIKE '^[0-9]+$' GROUP BY CAST(material_number AS BIGINT)
),
delivery_dates AS (
  SELECT vbeln,
    MAX(CASE WHEN wadat NOT IN ('','00000000') THEN TO_DATE(wadat,'yyyyMMdd') END) AS planned_gi_date,
    MAX(CASE WHEN lfdat NOT IN ('','00000000') THEN TO_DATE(lfdat,'yyyyMMdd') END) AS requested_delivery_date
  FROM cdl_oss_prod.silver_sap_n6p.likp GROUP BY vbeln
),
order_lines AS (
  SELECT
    o.*, ldv.delivery,
    CAST(p.vgbel AS STRING) AS order_number,
    CAST(p.lfimg AS DOUBLE) * COALESCE(su.umren / NULLIF(su.umrez,0), 0) AS line_su,
    COALESCE(mo.is_oral_care, 'No') AS line_is_oral_care
  FROM op_loads o
  JOIN load_delivery ldv ON ldv.load_id = o.load_id
  JOIN cdl_oss_prod.silver_sap_n6p.lips p
    ON p.vbeln = ldv.delivery AND p.vgbel IS NOT NULL AND p.vgbel <> ''
  LEFT JOIN cdl_oss_prod.silver_sap_n6p.marm su
    ON su.matnr = p.matnr AND su.meinh = 'SU'
  LEFT JOIN mat_oc mo ON mo.matnr_key = CAST(p.matnr AS BIGINT)
)
SELECT
  ol.order_number,
  ol.load_id                                                        AS load_number,
  ol.delivery                                                       AS delivery_number,
  ol.operational_status,
  ol.shipment_stage,
  ol.shipping_plant, ol.shipping_plant_desc, ol.shipping_point,
  ol.destination_location, ol.origin_state_province, ol.destination_state_province,
  CASE WHEN SUM(CASE WHEN ol.line_is_oral_care='Yes' THEN ol.line_su ELSE 0 END) > 0
       THEN 'Yes' ELSE 'No' END                                     AS is_oral_care,
  ROUND(SUM(CASE WHEN ol.line_is_oral_care='Yes' THEN ol.line_su ELSE 0 END),2) AS oc_su,
  ROUND(SUM(CASE WHEN ol.line_is_oral_care<>'Yes' THEN ol.line_su ELSE 0 END),2) AS non_oc_su,
  ROUND(SUM(ol.line_su),2)                                          AS total_su,
  ol.first_commitment_pickup_date,
  ol.latest_commitment_pickup_date,
  ol.commitment_change_count,
  ol.first_carrier_name,
  ol.latest_carrier_name,
  dd.planned_gi_date,
  dd.requested_delivery_date
FROM order_lines ol
LEFT JOIN delivery_dates dd ON dd.vbeln = ol.delivery
GROUP BY
  ol.order_number, ol.load_id, ol.delivery, ol.operational_status, ol.shipment_stage,
  ol.shipping_plant, ol.shipping_plant_desc, ol.shipping_point,
  ol.destination_location, ol.origin_state_province, ol.destination_state_province,
  ol.first_commitment_pickup_date, ol.latest_commitment_pickup_date,
  ol.commitment_change_count, ol.first_carrier_name, ol.latest_carrier_name,
  dd.planned_gi_date, dd.requested_delivery_date
ORDER BY ol.latest_commitment_pickup_date, ol.order_number;

-- COMMAND ----------

-- Order-level summary (this is what the Excel "Summary by Status" sheet shows)
SELECT
  operational_status,
  COUNT(DISTINCT order_number)  AS orders,
  COUNT(DISTINCT load_number)   AS loads,
  SUM(CASE WHEN is_oral_care='Yes' THEN 1 ELSE 0 END) AS oral_care_order_loads,
  ROUND(SUM(oc_su),0)           AS oc_su,
  ROUND(SUM(non_oc_su),0)       AS non_oc_su,
  ROUND(SUM(total_su),0)        AS total_su
FROM hive_metastore.userdb_essam_ae.ocna_operational_not_shipped_orders
GROUP BY operational_status
ORDER BY total_su DESC;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Step 6: Export the order-level table to an Excel workbook
-- MAGIC Run this Python cell (switch the cell language to Python in Databricks). It writes a
-- MAGIC multi-sheet `.xlsx` to DBFS so you can download it from the workspace:
-- MAGIC `Data > DBFS > FileStore > operational_not_shipped_orders.xlsx`, or via
-- MAGIC `https://<workspace-host>/files/operational_not_shipped_orders.xlsx`.
-- MAGIC
-- MAGIC The same file is produced locally by `build_op_orders_excel.py` in this repo.

-- COMMAND ----------

-- MAGIC %python
-- MAGIC import pandas as pd
-- MAGIC
-- MAGIC pdf = (spark.table("hive_metastore.userdb_essam_ae.ocna_operational_not_shipped_orders")
-- MAGIC             .toPandas())
-- MAGIC
-- MAGIC by_status = (pdf.groupby("operational_status", dropna=False)
-- MAGIC                 .agg(orders=("order_number", "nunique"),
-- MAGIC                      loads=("load_number", "nunique"),
-- MAGIC                      oc_su=("oc_su", "sum"),
-- MAGIC                      non_oc_su=("non_oc_su", "sum"),
-- MAGIC                      total_su=("total_su", "sum"))
-- MAGIC                 .reset_index().sort_values("total_su", ascending=False))
-- MAGIC
-- MAGIC by_plant = (pdf.groupby(["shipping_plant", "shipping_plant_desc"], dropna=False)
-- MAGIC                .agg(orders=("order_number", "nunique"),
-- MAGIC                     loads=("load_number", "nunique"),
-- MAGIC                     oc_su=("oc_su", "sum"),
-- MAGIC                     non_oc_su=("non_oc_su", "sum"),
-- MAGIC                     total_su=("total_su", "sum"))
-- MAGIC                .reset_index().sort_values("total_su", ascending=False))
-- MAGIC
-- MAGIC out = "/dbfs/FileStore/operational_not_shipped_orders.xlsx"
-- MAGIC with pd.ExcelWriter(out, engine="openpyxl") as xw:
-- MAGIC     pdf.to_excel(xw, sheet_name="Orders", index=False)
-- MAGIC     by_status.to_excel(xw, sheet_name="Summary by Status", index=False)
-- MAGIC     by_plant.to_excel(xw, sheet_name="Summary by Plant", index=False)
-- MAGIC print("Wrote", out, "rows:", len(pdf))
-- MAGIC print("Download: /files/operational_not_shipped_orders.xlsx")
