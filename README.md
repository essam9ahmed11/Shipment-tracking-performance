# Shipment Tracking Performance

A P&G-branded Flask web application for monitoring North America intersite transportation performance. It loads the OCNA shipment tracking table from Databricks and serves interactive analytics.

## Features

Three tabs:

1. **Performance Review**
   - Searchable, multi-select filters: Shipping Plant, Destination Plant, Lane (Plant → Plant), TMS Carrier, Service Type, Destination City, Is Oral Care?, Load Number.
   - KPI measures:
     - **SOT 1st** — % of loads shipped on/before the first committed pickup (`checkout_date ≤ old_pickup_date`)
     - **SOT Final** — % shipped on/before the final committed pickup (`checkout_date ≤ newest_pickup_date`)
     - **IOT** — % of loads with `iot_on_time = Yes`
     - **# Shipments** — count of loads
   - Carrier and Lane performance rows (side-by-side), each with SOT 1st / SOT Fnl / IOT / # Shipments and red/amber/green thresholds.
   - Trend Explorer — day-by-day SOT 1st / SOT Fnl / IOT for a selected Carrier, Lane, or Service Type, over the past week or month, with a reason-code breakdown (`csot_failure_reason_updated`).

2. **Order Analysis**
   - Per-load date timeline: Old Pickup (1st commitment) → New Pickup (final commitment) → Checkout (actual ship) → Requested Delivery → Actual Arrival.

3. **Operational Review** — coming soon.

## Project structure

```
transport_app/
├── app.py             # Flask backend + analytics APIs
├── data_loader.py     # Pulls tracking table from Databricks, caches to pickle
├── templates/
│   └── index.html     # Single-page UI (P&G branded, Chart.js)
└── .gitignore
```

## Data source

Table: `hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite` (Databricks).
Grain: one row per TMS load.

## Running locally

Requires Python 3 and `flask` + `requests`.

```powershell
# First run (fetches data from Databricks and builds the local cache)
python data_loader.py --refresh

# Start the app
python app.py
```

Then open http://127.0.0.1:5050

To refresh the data later, re-run `python data_loader.py --refresh` and restart the app.

## Notes

- Databricks credentials are read from a local `config.Json` (not included in this repo).
- The local data cache (`tracking_cache.pkl`) is git-ignored and regenerable.
