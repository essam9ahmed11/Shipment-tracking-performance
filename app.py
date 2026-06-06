"""
P&G Transportation Performance — Flask backend.
Loads the cached tracking table into memory and serves analytics APIs.

Measures:
  SOT 1st  = % shipped on/before the FIRST committed pickup (old_pickup_date)
  SOT fnl  = % shipped on/before the FINAL committed pickup (newest_pickup_date)
  IOT      = % of loads with iot_on_time = 'Yes'
  # Shipments = count of loads
"""
import os
from datetime import datetime, timedelta
from collections import defaultdict, OrderedDict

from flask import Flask, jsonify, request, render_template

import data_loader

app = Flask(__name__)

# ----------------------------------------------------------------------------
# Load data once into memory as list[dict]
# ----------------------------------------------------------------------------
COLS, ROWS, LOADED_AT = data_loader.load(refresh=False)


def _parse_date(s):
    if not s:
        return None
    try:
        return datetime.strptime(s[:10], '%Y-%m-%d').date()
    except (ValueError, TypeError):
        return None


# Pre-process rows into dicts with parsed dates + measure flags
DATA = []
for r in ROWS:
    d = dict(zip(COLS, r))
    co = _parse_date(d.get('checkout_date'))
    op = _parse_date(d.get('old_pickup_date'))
    np_ = _parse_date(d.get('newest_pickup_date'))
    d['_checkout'] = co
    d['_old_pickup'] = op
    d['_new_pickup'] = np_
    d['_iot_hit'] = 1 if (d.get('iot_on_time') == 'Yes') else 0
    d['_iot_meas'] = 1 if d.get('iot_on_time') in ('Yes', 'No') else 0
    d['_sot1_meas'] = 1 if (co and op) else 0
    d['_sot1_hit'] = 1 if (co and op and co <= op) else 0
    d['_sotf_meas'] = 1 if (co and np_) else 0
    d['_sotf_hit'] = 1 if (co and np_ and co <= np_) else 0
    # normalize carrier short name (had tabs)
    if d.get('carrier_short_name'):
        d['carrier_short_name'] = d['carrier_short_name'].strip()
    # Derived lane = Shipping Plant -> Destination Plant
    sp = (d.get('shipping_plant') or '').strip()
    dp = (d.get('destination_plant') or '').strip()
    d['lane_pd'] = f'{sp} \u2192 {dp}' if (sp or dp) else ''
    DATA.append(d)

# Anchor "today" to the latest checkout date in the data
ALL_CHECKOUTS = [d['_checkout'] for d in DATA if d['_checkout']]
ANCHOR_DATE = max(ALL_CHECKOUTS) if ALL_CHECKOUTS else datetime.today().date()

# ----------------------------------------------------------------------------
# Filter definitions
# ----------------------------------------------------------------------------
FILTER_FIELDS = OrderedDict([
    ('shipping_plant', 'Shipping Plant'),
    ('destination_plant', 'Destination Plant'),
    ('lane_pd', 'Lane (Plant \u2192 Plant)'),
    ('tms_carrier_name', 'TMS Carrier'),
    ('service_type', 'Service Type'),
    ('destination_city', 'Destination City'),
    ('is_oral_care', 'Is Oral Care?'),
    ('load_number', 'Load Number'),
])


def apply_filters(rows, filters):
    """filters = dict field -> list of selected values (or single value)."""
    out = rows
    for field, vals in filters.items():
        if not vals:
            continue
        if not isinstance(vals, list):
            vals = [vals]
        vals = [v for v in vals if v not in (None, '', '__ALL__')]
        if not vals:
            continue
        vset = set(vals)
        out = [r for r in out if (r.get(field) or '') in vset]
    return out


def compute_measures(rows):
    n = len(rows)
    s1m = sum(r['_sot1_meas'] for r in rows)
    s1h = sum(r['_sot1_hit'] for r in rows)
    sfm = sum(r['_sotf_meas'] for r in rows)
    sfh = sum(r['_sotf_hit'] for r in rows)
    im = sum(r['_iot_meas'] for r in rows)
    ih = sum(r['_iot_hit'] for r in rows)
    return {
        'sot_1st': round(s1h / s1m * 100, 1) if s1m else None,
        'sot_fnl': round(sfh / sfm * 100, 1) if sfm else None,
        'iot': round(ih / im * 100, 1) if im else None,
        'num_shipments': n,
    }


# ----------------------------------------------------------------------------
# Routes
# ----------------------------------------------------------------------------
@app.route('/')
def index():
    return render_template('index.html', loaded_at=LOADED_AT,
                           anchor=ANCHOR_DATE.isoformat())


@app.route('/api/filters')
def api_filters():
    """Distinct values for each filter dropdown."""
    result = {}
    for field in FILTER_FIELDS:
        vals = set()
        for r in DATA:
            v = r.get(field)
            if v not in (None, ''):
                vals.add(v)
        # Cap very large lists (load_number, lane) — still return all but sorted
        result[field] = sorted(vals)
    result['_labels'] = FILTER_FIELDS
    return jsonify(result)


def _read_filters():
    body = request.get_json(silent=True) or {}
    filters = body.get('filters', {})
    return body, filters


@app.route('/api/performance', methods=['POST'])
def api_performance():
    body, filters = _read_filters()
    rows = apply_filters(DATA, filters)
    overall = compute_measures(rows)

    # Carrier performance cards
    by_carrier = defaultdict(list)
    for r in rows:
        c = r.get('tms_carrier_name') or r.get('carrier_name') or 'UNKNOWN'
        by_carrier[c].append(r)
    cards = []
    for c, crows in by_carrier.items():
        m = compute_measures(crows)
        cards.append({'carrier': c, **m})
    cards.sort(key=lambda x: x['num_shipments'], reverse=True)

    # Lane performance cards (lane = shipping_plant -> destination_plant)
    by_lane = defaultdict(list)
    for r in rows:
        lk = r.get('lane_pd') or 'UNKNOWN'
        by_lane[lk].append(r)
    lane_cards = []
    for lk, lrows in by_lane.items():
        m = compute_measures(lrows)
        lane_cards.append({'lane': lk, **m})
    lane_cards.sort(key=lambda x: x['num_shipments'], reverse=True)

    return jsonify({'overall': overall, 'carrier_cards': cards,
                    'lane_cards': lane_cards})


def _window_dates(granularity):
    days = 7 if granularity == 'week' else 30
    start = ANCHOR_DATE - timedelta(days=days - 1)
    return [start + timedelta(days=i) for i in range(days)], start


@app.route('/api/trend', methods=['POST'])
def api_trend():
    """Day-by-day SOT1st / SOTfnl / IOT for a selected dimension value.
    body: { filters, dimension: 'carrier'|'lane'|'service', value: <str>,
            granularity: 'week'|'month' }
    """
    body, filters = _read_filters()
    dimension = body.get('dimension', 'carrier')
    value = body.get('value')
    granularity = body.get('granularity', 'week')

    field = {
        'carrier': 'tms_carrier_name',
        'lane': 'lane_pd',
        'service': 'service_type',
    }.get(dimension, 'tms_carrier_name')

    rows = apply_filters(DATA, filters)
    if value and value != '__ALL__':
        rows = [r for r in rows if (r.get(field) or '') == value]

    days, start = _window_dates(granularity)
    rows = [r for r in rows if r['_checkout'] and r['_checkout'] >= start]

    # Bucket by checkout day
    buckets = defaultdict(list)
    for r in rows:
        buckets[r['_checkout']].append(r)

    labels, sot1, sotf, iot, counts = [], [], [], [], []
    for day in days:
        drows = buckets.get(day, [])
        m = compute_measures(drows)
        labels.append(day.isoformat())
        sot1.append(m['sot_1st'])
        sotf.append(m['sot_fnl'])
        iot.append(m['iot'])
        counts.append(m['num_shipments'])

    # Reason-code breakdown (misses / all) for the selected value
    reasons = defaultdict(int)
    for r in rows:
        rc = r.get('csot_failure_reason_updated') or '(blank)'
        reasons[rc] += 1
    reason_rows = sorted(
        [{'reason': k, 'count': v} for k, v in reasons.items()],
        key=lambda x: x['count'], reverse=True
    )

    return jsonify({
        'labels': labels,
        'sot_1st': sot1,
        'sot_fnl': sotf,
        'iot': iot,
        'counts': counts,
        'reasons': reason_rows,
        'value': value or '(all)',
    })


@app.route('/api/dimension_values', methods=['POST'])
def api_dimension_values():
    """Distinct values for a dimension (carrier/lane/service), respecting filters."""
    body, filters = _read_filters()
    dimension = body.get('dimension', 'carrier')
    field = {
        'carrier': 'tms_carrier_name',
        'lane': 'lane_pd',
        'service': 'service_type',
    }.get(dimension, 'tms_carrier_name')
    rows = apply_filters(DATA, filters)
    counts = defaultdict(int)
    for r in rows:
        v = r.get(field)
        if v not in (None, ''):
            counts[v] += 1
    vals = sorted(counts.items(), key=lambda x: x[1], reverse=True)
    return jsonify([{'value': v, 'count': c} for v, c in vals])


@app.route('/api/orders', methods=['POST'])
def api_orders():
    """Order Analysis timeline. Returns per-load date milestones."""
    body, filters = _read_filters()
    rows = apply_filters(DATA, filters)
    # Sort by checkout desc, cap to a reasonable number for the visual
    rows = sorted(rows, key=lambda r: (r['_checkout'] or datetime.min.date()), reverse=True)
    limit = int(body.get('limit', 60))
    out = []
    for r in rows[:limit]:
        out.append({
            'order_number': r.get('order_number'),
            'load_number': r.get('load_number'),
            'lane': r.get('lane_pd'),
            'carrier': r.get('tms_carrier_name') or r.get('carrier_name'),
            'service_type': r.get('service_type'),
            'is_oral_care': r.get('is_oral_care'),
            'old_pickup_date': r.get('old_pickup_date'),
            'old_pickup_time': r.get('old_pickup_time'),
            'newest_pickup_date': r.get('newest_pickup_date'),
            'newest_pickup_time': r.get('newest_pickup_time'),
            'checkout_date': r.get('checkout_date'),
            'requested_delivery_date': r.get('requested_delivery_date_from'),
            'actual_arrival_date': r.get('actual_arrival_date'),
            'iot_on_time': r.get('iot_on_time'),
            'reason': r.get('csot_failure_reason_updated'),
        })
    return jsonify({'orders': out, 'total': len(rows)})


if __name__ == '__main__':
    print(f'Loaded {len(DATA)} rows (cache from {LOADED_AT}). Anchor date: {ANCHOR_DATE}')
    app.run(host='127.0.0.1', port=5050, debug=False)
