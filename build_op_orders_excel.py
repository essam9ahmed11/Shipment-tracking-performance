"""Download the operational not-shipped order-level table from Databricks and write an Excel workbook.

Sheets:
  - Orders            : one row per order x load x plant (OC/non-OC SU, oral care, dates)
  - Summary by Status : roll-up by operational status
  - Summary by Plant  : roll-up by shipping plant
  - Readme            : what each column means

Run:  python build_op_orders_excel.py
"""
import json
import os
import time
import urllib.request

import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
TABLE = "hive_metastore.userdb_essam_ae.ocna_operational_not_shipped_orders"
WAREHOUSE_ID = "2627fd4c01a8c5a2"
OUT_XLSX = os.path.join(HERE, "operational_not_shipped_orders_interplant_oralcare.xlsx")


def _env():
    host = token = None
    with open(os.path.join(HERE, ".env"), "r", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("DATABRICKS_HOST="):
                host = line.split("=", 1)[1].strip()
            elif line.startswith("DATABRICKS_TOKEN="):
                token = line.split("=", 1)[1].strip()
    return host, token


def _post(url, token, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def _get(url, token):
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def fetch_all(sql):
    host, token = _env()
    resp = _post(f"{host}/api/2.0/sql/statements", token, {
        "warehouse_id": WAREHOUSE_ID,
        "statement": sql,
        "wait_timeout": "50s",
        "format": "JSON_ARRAY",
        "disposition": "EXTERNAL_LINKS",
    })
    sid = resp["statement_id"]
    state = resp["status"]["state"]
    while state in ("PENDING", "RUNNING"):
        time.sleep(2)
        resp = _get(f"{host}/api/2.0/sql/statements/{sid}", token)
        state = resp["status"]["state"]
    if state != "SUCCEEDED":
        raise RuntimeError(f"Query state={state}: {resp.get('status')}")

    cols = [c["name"] for c in resp["manifest"]["schema"]["columns"]]
    rows = []
    chunk = resp["result"]
    while True:
        for link in chunk.get("external_links", []):
            with urllib.request.urlopen(link["external_link"], timeout=300) as r:
                rows.extend(json.loads(r.read().decode("utf-8")))
        nxt = chunk.get("next_chunk_index")
        if nxt is None:
            break
        chunk = _get(
            f"{host}/api/2.0/sql/statements/{sid}/result/chunks/{nxt}", token)
    return pd.DataFrame(rows, columns=cols)


def main():
    print("Downloading order-level rows ...")
    df = fetch_all(f"SELECT * FROM {TABLE}")
    print(f"  {len(df):,} rows x {len(df.columns)} cols")

    num_cols = ["oc_su", "non_oc_su", "total_su", "commitment_change_count"]
    for c in num_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors="coerce")

    date_cols = ["first_commitment_pickup_date", "latest_commitment_pickup_date",
                 "planned_gi_date", "requested_delivery_date"]
    for c in date_cols:
        if c in df.columns:
            df[c] = pd.to_datetime(df[c], errors="coerce")

    by_status = (df.groupby("operational_status", dropna=False)
                   .agg(orders=("order_number", "nunique"),
                        loads=("load_number", "nunique"),
                        oc_su=("oc_su", "sum"),
                        non_oc_su=("non_oc_su", "sum"),
                        total_su=("total_su", "sum"))
                   .reset_index()
                   .sort_values("total_su", ascending=False))

    by_plant = (df.groupby(["destination_plant", "destination_plant_desc"], dropna=False)
                  .agg(orders=("order_number", "nunique"),
                       loads=("load_number", "nunique"),
                       oc_su=("oc_su", "sum"),
                       non_oc_su=("non_oc_su", "sum"),
                       total_su=("total_su", "sum"))
                  .reset_index()
                  .sort_values("total_su", ascending=False))

    readme = pd.DataFrame({
        "column": [
            "order_number", "load_number", "delivery_number",
            "operational_status", "shipment_stage",
            "shipping_plant", "shipping_plant_desc", "shipping_point",
            "destination_plant", "destination_plant_desc",
            "destination_location", "origin_state_province",
            "destination_state_province", "is_oral_care",
            "oc_su", "non_oc_su", "total_su",
            "first_commitment_pickup_date", "latest_commitment_pickup_date",
            "commitment_change_count", "first_carrier_name", "latest_carrier_name",
            "planned_gi_date", "requested_delivery_date"],
        "meaning": [
            "SAP order / STO number (vgbel)",
            "TMS load number (systemLoadID)",
            "SAP delivery number (vbeln)",
            "TMS operational status (Open/Planned/Tendered/Tender Accepted/In Transit)",
            "Awaiting Pickup vs In Transit",
            "SAP origin plant code",
            "Origin plant description",
            "TMS origin shipping point",
            "Destination plant code (ship-to mapped to plant, e.g. PB360)",
            "Destination plant description",
            "Destination location id (raw TMS)",
            "Origin state/province",
            "Destination state/province",
            "Yes if any oral-care SU on the order-load",
            "Oral-care shipped units (SU) committed on the order-load",
            "Non oral-care shipped units (SU)",
            "Total SU = oc_su + non_oc_su",
            "First committed pickup date (TMS audit trail)",
            "Latest committed pickup date (TMS audit trail)",
            "Number of audit changes to the load",
            "Carrier on first commitment",
            "Carrier on latest commitment",
            "Planned goods-issue date (SAP LIKP.wadat)",
            "Requested delivery date / RDD (SAP LIKP.lfdat)"],
    })

    print(f"Writing {OUT_XLSX} ...")
    with pd.ExcelWriter(OUT_XLSX, engine="openpyxl") as xw:
        df.to_excel(xw, sheet_name="Orders", index=False)
        by_status.to_excel(xw, sheet_name="Summary by Status", index=False)
        by_plant.to_excel(xw, sheet_name="Summary by Dest Plant", index=False)
        readme.to_excel(xw, sheet_name="Readme", index=False)
    print("Done.")
    print(by_status.to_string(index=False))


if __name__ == "__main__":
    main()
