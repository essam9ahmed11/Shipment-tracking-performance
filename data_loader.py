"""
Data loader for the P&G Transportation Performance app.
Pulls the tracking table from Databricks ONCE and caches to a local pickle.
Subsequent app restarts load from the pickle (fast) unless --refresh is passed.
"""
import json
import os
import time
import pickle
import requests

CFG_PATH = r'C:\Users\essam.ae\OneDrive - Procter and Gamble\Documents\MS copilot studio\config.Json'
CACHE_PATH = os.path.join(os.path.dirname(__file__), 'tracking_cache.pkl')
WAREHOUSE_ID = '2627fd4c01a8c5a2'

# Columns needed by the app (load-grain). Keeps payload small.
COLUMNS = [
    'order_number', 'load_number', 'customer_po',
    'shipping_plant', 'shipping_plant_desc', 'shipping_point',
    'destination_plant', 'destination_plant_desc', 'destination_city', 'destination_state',
    'lane', 'is_oral_care',
    'carrier_name', 'tms_carrier_name', 'carrier_short_name',
    'service_type', 'transport_mode',
    'old_carrier_name', 'old_pickup_date', 'old_pickup_time',
    'newest_carrier_name', 'newest_pickup_date', 'newest_pickup_time',
    'latest_change_date', 'change_user',
    'sap_original_ship_date',
    'load_ready_date', 'load_complete_date',
    'checkout_date', 'actual_arrival_date',
    'requested_delivery_date_from', 'requested_delivery_date_to',
    'iot_on_time', 'csot_failure_reason_updated', 'csot_failure_reason',
    'lot_status', 'gbu',
    'oc_shipped_su', 'non_oc_shipped_su',
]

TABLE = 'hive_metastore.userdb_essam_ae.ocna_shipment_tracking_intersite'


def _headers():
    cfg = json.load(open(CFG_PATH))
    return {
        'Authorization': 'Bearer ' + cfg['access_token'],
        'Content-Type': 'application/json',
    }, cfg['workspace_url'].rstrip('/')


def _fetch_all():
    """Run the SELECT and follow result chunks to get every row.

    Adds `sap_actual_gi_date` per load via the proper load->delivery->GI link:
      OCNA.load_number = na_tms_loads_cdl.load_id
      na_tms_loads_cdl.shipment_tracking_number = likp.vbeln (SAP delivery)
      likp.wadat_ist = actual goods issue (the true SAP ship date)
    """
    headers, base = _headers()
    url = base + '/api/2.0/sql/statements'
    col_list = ', '.join('t.' + c for c in COLUMNS)
    q = f'''
WITH link AS (
  SELECT CAST(load_id AS STRING) AS load_id,
         MAX(CAST(shipment_tracking_number AS STRING)) AS vbeln
  FROM hive_metastore.userdb_essam_ae.na_tms_loads_cdl
  WHERE shipment_tracking_number IS NOT NULL
  GROUP BY CAST(load_id AS STRING)
),
gi AS (
  SELECT CAST(vbeln AS STRING) AS vbeln, TO_DATE(wadat_ist, 'yyyyMMdd') AS sap_gi
  FROM cdl_oss_prod.silver_sap_n6p.likp
  WHERE wadat_ist IS NOT NULL AND wadat_ist <> '00000000'
)
SELECT {col_list},
       CAST(g.sap_gi AS STRING) AS sap_actual_gi_date
FROM {TABLE} t
LEFT JOIN link l ON l.load_id = CAST(t.load_number AS STRING)
LEFT JOIN gi   g ON g.vbeln   = l.vbeln
'''
    r = requests.post(url, headers=headers, json={
        'warehouse_id': WAREHOUSE_ID,
        'statement': q,
        'wait_timeout': '0s',
        'disposition': 'INLINE',
        'format': 'JSON_ARRAY',
    }, timeout=30)
    sid = r.json()['statement_id']

    # Poll until done
    for _ in range(60):
        time.sleep(3)
        rg = requests.get(f'{url}/{sid}', headers=headers, timeout=30)
        d = rg.json()
        state = d['status']['state']
        if state == 'SUCCEEDED':
            break
        if state in ('FAILED', 'CANCELED'):
            raise RuntimeError(d['status'].get('error', state))
    else:
        raise RuntimeError('Timed out waiting for query')

    cols = [c['name'] for c in d['manifest']['schema']['columns']]
    rows = []
    # First chunk
    result = d.get('result', {})
    rows.extend(result.get('data_array', []) or [])
    # Follow additional chunks
    total_chunks = d['manifest'].get('total_chunk_count', 1)
    next_idx = result.get('next_chunk_index')
    while next_idx is not None:
        rc = requests.get(f'{url}/{sid}/result/chunks/{next_idx}', headers=headers, timeout=30)
        dc = rc.json()
        rows.extend(dc.get('data_array', []) or [])
        next_idx = dc.get('next_chunk_index')

    return cols, rows


def load(refresh=False):
    """Return (cols, rows). Uses local cache unless refresh=True."""
    if not refresh and os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, 'rb') as f:
            data = pickle.load(f)
        return data['cols'], data['rows'], data.get('loaded_at', 'cache')

    cols, rows = _fetch_all()
    loaded_at = time.strftime('%Y-%m-%d %H:%M:%S')
    with open(CACHE_PATH, 'wb') as f:
        pickle.dump({'cols': cols, 'rows': rows, 'loaded_at': loaded_at}, f)
    return cols, rows, loaded_at


if __name__ == '__main__':
    import sys
    refresh = '--refresh' in sys.argv
    cols, rows, when = load(refresh=refresh)
    print(f'Loaded {len(rows)} rows, {len(cols)} columns (as of {when})')
    print('Columns:', cols)
    if rows:
        print('Sample:', dict(zip(cols, rows[0])))
