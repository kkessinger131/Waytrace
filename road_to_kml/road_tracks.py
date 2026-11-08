#!/usr/bin/env python3
"""
road_tracks.py
--------------
Companion module for road_to_kml.py: turn GPS history into the roads you
actually traveled (road_to_kml.py --track ...).

Reads:
  * Google Maps Timeline exports
      - phone export (Timeline.json / location-history.json) with
        semanticSegments / rawSignals and "38.9123°, -77.0456°" points
      - iPhone array export with "geo:38.9123,-77.0456" points
      - older Google Takeout files: Records.json and
        Semantic Location History/YYYY/YYYY_MONTH.json
  * GPX tracks and routes, KML tracks/lines, GeoJSON lines

Then it keeps the dates and travel modes you ask for, splits the history into
trips (at stops, mode changes and long gaps), and map-matches each trip onto
the OpenStreetMap road network. The matcher is a hidden Markov model that
routes along the network between consecutive points, so sparse Timeline
points a few hundred meters to a few kilometers apart still follow the real
roads, ramps and turns rather than cutting corners.

Nothing is written to disk; downloaded road data lives only for the run.
"""

import bisect
import heapq
import json
import math
import os
import re
import xml.etree.ElementTree as ET
from collections import defaultdict, namedtuple
from datetime import date, datetime, timedelta, timezone

from pyproj import Transformer
from shapely.geometry import LineString, Point
from shapely.strtree import STRtree

TrackPoint = namedtuple("TrackPoint", "t lat lon acc mode seg act", defaults=(None,))
Trip = namedtuple("Trip", "category points")
Candidate = namedtuple("Candidate", "eid s d x y")
MatchResult = namedtuple("MatchResult", "lines nodes way_ids used breaks skipped")


# ===========================================================================
# Travel modes
# ===========================================================================
# Timeline / Takeout activity names -> the network a trip is matched on.
# Anything in SKIP_MODES (flights, trains, ferries...) is dropped.
DRIVE_MODES = {"IN_PASSENGER_VEHICLE", "IN_VEHICLE", "IN_ROAD_VEHICLE", "IN_CAR", "DRIVING",
               "DRIVE", "IN_BUS", "IN_TAXI", "MOTORCYCLING", "IN_FOUR_WHEELER_VEHICLE",
               "IN_TWO_WHEELER_VEHICLE"}
WALK_MODES = {"WALKING", "WALK", "ON_FOOT", "RUNNING", "HIKING"}
BIKE_MODES = {"CYCLING", "CYCLE", "ON_BICYCLE", "BIKING"}
SKIP_MODES = {"FLYING", "IN_TRAIN", "IN_RAIL_VEHICLE", "IN_SUBWAY", "IN_TRAM", "IN_FERRY",
              "SAILING", "BOATING", "IN_CABLECAR", "IN_FUNICULAR", "IN_GONDOLA_LIFT",
              "SKIING", "KAYAKING", "ROWING", "SURFING", "SWIMMING", "STILL"}

CATEGORIES = ("drive", "walk", "bike", "other")   # "other" = mode unknown

# OSM highway types each kind of trip can use.
_ROADS = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
          "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
          "residential", "living_street", "service", "road", "track", "busway"]
_FOOT = ["footway", "path", "pedestrian", "steps", "cycleway", "bridleway", "corridor"]
NETWORK_TYPES = {
    "drive": _ROADS,
    "walk": [t for t in _ROADS if not t.startswith("motorway")] + _FOOT,
    "bike": [t for t in _ROADS if not t.startswith("motorway")] + [t for t in _FOOT if t != "steps"],
    "other": _ROADS + _FOOT,
}
# Ways that don't count as a junction unless the trip actually used them.
MINOR_TYPES = {"service", "track", "footway", "path", "pedestrian", "steps", "cycleway",
               "bridleway", "corridor"}
_PED_TYPES = set(_FOOT)

# Matching parameters per category.
_SPACING = {"drive": 25.0, "bike": 12.0, "walk": 8.0, "other": 15.0}   # min m between points
_VMAX = {"drive": 60.0, "bike": 20.0, "walk": 8.0, "other": 60.0}     # m/s, sanity limit
END_STUB_M = 12.0     # trim pieces shorter than this at the ends of a matched stretch
NO_ACC_SIGMA = 35.0   # m: assumed GPS error for points that don't say (Google Timeline paths)

# When choosing a driving route between two GPS points, minor roads count as a
# little longer than they are, so a shortcut through side streets only wins
# when the GPS points actually lead there. (A point sitting on a side street
# still pulls the match onto it.)
ROAD_CLASS_COST = {
    "tertiary": 1.1, "tertiary_link": 1.1,
    "unclassified": 1.3, "residential": 1.3, "road": 1.3, "busway": 1.3,
    "living_street": 1.6, "service": 1.6, "track": 2.0,
}


def mode_category(raw):
    """'drive' / 'walk' / 'bike' / 'skip', or None when unknown."""
    if not raw:
        return None
    m = re.sub(r"[\s-]+", "_", str(raw).strip().upper())
    if m in SKIP_MODES:
        return "skip"
    if m in DRIVE_MODES:
        return "drive"
    if m in WALK_MODES:
        return "walk"
    if m in BIKE_MODES:
        return "bike"
    if m == "UNKNOWN_TRAVEL":
        return "other"
    return None


# ===========================================================================
# Parsing helpers
# ===========================================================================
_LATLNG_RE = re.compile(r"(-?\d+(?:\.\d+)?)\s*°?\s*,\s*(-?\d+(?:\.\d+)?)")


def parse_latlng(v):
    """(lat, lon) from '38.9°, -77.0°', 'geo:38.9,-77.0', E7 dicts, etc."""
    if v is None:
        return None
    if isinstance(v, str):
        s = v.strip()
        if s.lower().startswith("geo:"):
            s = s[4:]
        m = _LATLNG_RE.search(s)
        if not m:
            return None
        lat, lon = float(m.group(1)), float(m.group(2))
    elif isinstance(v, dict):
        for la, lo, scale in (("latitudeE7", "longitudeE7", 1e7), ("latE7", "lngE7", 1e7),
                              ("lat", "lng", 1.0), ("lat", "lon", 1.0),
                              ("latitude", "longitude", 1.0)):
            if la in v and lo in v:
                try:
                    lat, lon = float(v[la]) / scale, float(v[lo]) / scale
                except (TypeError, ValueError):
                    return None
                break
        else:
            for key in ("latLng", "LatLng", "point", "placeLocation", "location"):
                if key in v:
                    return parse_latlng(v[key])
            return None
    else:
        return None
    if -90 <= lat <= 90 and -180 <= lon <= 180 and (lat, lon) != (0.0, 0.0):
        return lat, lon
    return None


def parse_time(v):
    """Timezone-aware datetime from ISO strings or epoch (s or ms)."""
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)) or (isinstance(v, str) and re.fullmatch(r"\d{10,16}", v.strip())):
        x = float(v)
        if x > 1e11:
            x /= 1000.0
        return datetime.fromtimestamp(x, timezone.utc)
    s = str(v).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    m = re.match(r"^(.*T\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$", s)
    if m and m.group(2):                       # normalise fractional seconds to 6 digits
        s = m.group(1) + (m.group(2) + "000000")[:7] + m.group(3)
    try:
        t = datetime.fromisoformat(s)
    except ValueError:
        return None
    return t if t.tzinfo else t.astimezone()


def local_date(t):
    """Calendar date of a timestamp as you lived it: in its own UTC offset when
    the file gives one (Timeline does), else in this computer's time zone."""
    off = t.utcoffset()
    if off is None or off == timedelta(0):
        return t.astimezone().date()
    return t.date()


def local_time(t):
    """A timestamp as wall-clock time where you were (see local_date)."""
    off = t.utcoffset()
    if off is None or off == timedelta(0):
        return t.astimezone()
    return t


def _localize(points, activities, visits, window=timedelta(hours=12)):
    """Give UTC-stamped points the local UTC offset of the nearest activity or
    visit. (The iPhone export stamps path points in UTC but activities and
    visits in local time, so dates and times would otherwise disagree.)"""
    refs = sorted(((t, t.tzinfo) for a in list(activities) + list(visits) for t in a[:2]
                   if t is not None and t.utcoffset() not in (None, timedelta(0))),
                  key=lambda r: r[0])
    if not refs:
        return points
    keys = [r[0] for r in refs]
    out = []
    for p in points:
        if p.t is not None and p.t.utcoffset() == timedelta(0):
            i = bisect.bisect_left(keys, p.t)
            near = [refs[j] for j in (i - 1, i) if 0 <= j < len(refs)]
            best = min(near, key=lambda r: abs(r[0] - p.t))
            if abs(best[0] - p.t) <= window:
                p = p._replace(t=p.t.astimezone(best[1]))
        out.append(p)
    return out


def parse_date_spec(spec):
    """'2026-10-30', '2026-10', '2026-10-01..2026-10-31', '..2026-10-31',
    '2026-10-01..', or 'all'. Returns (first, last) dates or None for all."""
    if spec is None:
        return None
    s = str(spec).strip().lower()
    if s in ("", "all"):
        return None

    def one(part, end=False):
        part = part.strip()
        if not part:
            return None
        if re.fullmatch(r"\d{4}-\d{2}", part):
            y, mth = map(int, part.split("-"))
            if not end:
                return date(y, mth, 1)
            nxt = date(y + (mth == 12), mth % 12 + 1, 1)
            return nxt - timedelta(days=1)
        return date.fromisoformat(part)

    try:
        if ".." in s:
            a, b = s.split("..", 1)
            return one(a), one(b, end=True)
        return one(s), one(s, end=True)
    except ValueError:
        raise ValueError(f"Can't read --date '{spec}'. Use YYYY-MM-DD, YYYY-MM, "
                         "a range like 2026-10-01..2026-10-31, or 'all'.")


def haversine(lat1, lon1, lat2, lon2):
    r = 6371008.8
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


# ===========================================================================
# File readers. Each returns (points, activities, visits):
#   points:     list of TrackPoint
#   activities: list of (start, end, mode)  -> modes for points without one
#   visits:     list of (start, end)         -> stationary periods, dropped
# ===========================================================================

def _add(points, t, ll, acc=None, mode=None, seg="timeline"):
    if ll:
        points.append(TrackPoint(t, ll[0], ll[1], acc, mode, seg))


def _offset_time(start, minutes):
    try:
        return start + timedelta(minutes=float(minutes)) if start else None
    except (TypeError, ValueError):
        return None


def _read_timeline_segments(items, points, activities, visits, raw_max_acc):
    """Phone export semanticSegments, or the iPhone array (same item shapes)."""
    for seg in items:
        if not isinstance(seg, dict):
            continue
        st, et = parse_time(seg.get("startTime")), parse_time(seg.get("endTime"))
        for p in seg.get("timelinePath") or []:
            t = parse_time(p.get("time")) or _offset_time(st, p.get("durationMinutesOffsetFromStartTime"))
            _add(points, t, parse_latlng(p.get("point")))
        act = seg.get("activity")
        if isinstance(act, dict):
            mode = (act.get("topCandidate") or {}).get("type") or act.get("type")
            if st and et:
                activities.append((st, et, mode))
            _add(points, st, parse_latlng(act.get("start")), mode=mode)
            _add(points, et, parse_latlng(act.get("end")), mode=mode)
        if isinstance(seg.get("visit"), dict) and st and et:
            visits.append((st, et))


def _read_raw_signals(items, points, raw_max_acc):
    for sig in items or []:
        pos = sig.get("position") if isinstance(sig, dict) else None
        if not isinstance(pos, dict):
            continue
        acc = pos.get("accuracyMeters")
        try:
            acc = float(acc) if acc is not None else None
        except (TypeError, ValueError):
            acc = None
        if acc is not None and acc > raw_max_acc:
            continue
        _add(points, parse_time(pos.get("timestamp")),
             parse_latlng(pos.get("LatLng") or pos.get("latLng")), acc=acc)


def _read_records(locs, points, raw_max_acc):
    for r in locs or []:
        acc = r.get("accuracy")
        if acc is not None and acc > raw_max_acc:
            continue
        mode = None
        acts = r.get("activity") or []
        if acts and isinstance(acts[0], dict):
            inner = acts[0].get("activity") or []
            if inner:
                best = max(inner, key=lambda a: a.get("confidence", 0))
                mode = best.get("type")
        _add(points, parse_time(r.get("timestamp") or r.get("timestampMs")),
             parse_latlng(r), acc=acc, mode=mode)


def _read_semantic_history(objs, points, activities, visits):
    for o in objs or []:
        seg = o.get("activitySegment")
        if seg:
            dur = seg.get("duration") or {}
            st = parse_time(dur.get("startTimestamp") or dur.get("startTimestampMs"))
            et = parse_time(dur.get("endTimestamp") or dur.get("endTimestampMs"))
            mode = seg.get("activityType") or (seg.get("waypointPath") or {}).get("travelMode")
            if st and et:
                activities.append((st, et, mode))
            _add(points, st, parse_latlng(seg.get("startLocation")), mode=mode)
            raw = (seg.get("simplifiedRawPath") or {}).get("points") or []
            for p in raw:
                _add(points, parse_time(p.get("timestamp") or p.get("timestampMs")),
                     parse_latlng(p), mode=mode)
            wps = (seg.get("waypointPath") or {}).get("waypoints") or []
            if wps and st and et:
                n = len(wps)
                for i, wp in enumerate(wps):           # no times: spread evenly
                    _add(points, st + (et - st) * ((i + 1) / (n + 1)), parse_latlng(wp), mode=mode)
            _add(points, et, parse_latlng(seg.get("endLocation")), mode=mode)
        visit = o.get("placeVisit")
        if visit:
            dur = visit.get("duration") or {}
            st = parse_time(dur.get("startTimestamp") or dur.get("startTimestampMs"))
            et = parse_time(dur.get("endTimestamp") or dur.get("endTimestampMs"))
            if st and et:
                visits.append((st, et))


def _local(tag):
    return tag.rsplit("}", 1)[-1]


def _read_gpx(root, path, points):
    n = 0
    for trk in root.iter():
        name = _local(trk.tag)
        if name not in ("trkseg", "rte"):
            continue
        n += 1
        seg = f"{path}#{n}"
        for pt in trk:
            if _local(pt.tag) not in ("trkpt", "rtept"):
                continue
            try:
                lat, lon = float(pt.get("lat")), float(pt.get("lon"))
            except (TypeError, ValueError):
                continue
            t = None
            for child in pt:
                if _local(child.tag) == "time":
                    t = parse_time(child.text)
            points.append(TrackPoint(t, lat, lon, None, None, seg))


def _read_kml(root, path, points):
    n = 0
    for el in root.iter():
        name = _local(el.tag)
        if name == "Track":                                   # gx:Track
            n += 1
            whens = [parse_time(c.text) for c in el if _local(c.tag) == "when"]
            coords = [c.text for c in el if _local(c.tag) == "coord"]
            for i, c in enumerate(coords):
                parts = (c or "").split()
                if len(parts) >= 2:
                    t = whens[i] if i < len(whens) else None
                    points.append(TrackPoint(t, float(parts[1]), float(parts[0]), None, None, f"{path}#{n}"))
        elif name == "LineString":
            n += 1
            for child in el:
                if _local(child.tag) == "coordinates":
                    for c in (child.text or "").split():
                        parts = c.split(",")
                        if len(parts) >= 2:
                            points.append(TrackPoint(None, float(parts[1]), float(parts[0]),
                                                     None, None, f"{path}#{n}"))


def _read_geojson(data, path, points):
    feats = data.get("features") if data.get("type") == "FeatureCollection" else [data]
    n = 0
    for f in feats or []:
        geom = f.get("geometry", f) if isinstance(f, dict) else None
        if not geom:
            continue
        lines = []
        if geom.get("type") == "LineString":
            lines = [geom.get("coordinates") or []]
        elif geom.get("type") == "MultiLineString":
            lines = geom.get("coordinates") or []
        times = ((f.get("properties") or {}).get("coordTimes") or []) if isinstance(f, dict) else []
        for line in lines:
            n += 1
            for i, c in enumerate(line):
                t = parse_time(times[i]) if i < len(times) and isinstance(times[i], str) else None
                points.append(TrackPoint(t, float(c[1]), float(c[0]), None, None, f"{path}#{n}"))


def read_track_file(path, raw_max_acc=40.0):
    """Read one GPS/history file. Returns (points, activities, visits, kind)."""
    points, activities, visits = [], [], []
    with open(path, "rb") as fh:
        raw = fh.read()
    head = raw[:2000].lstrip()
    if head.startswith(b"<") or head.startswith(b"\xef\xbb\xbf<"):
        root = ET.fromstring(raw)
        if _local(root.tag) == "gpx":
            _read_gpx(root, path, points)
            return points, activities, visits, "GPX"
        _read_kml(root, path, points)
        return points, activities, visits, "KML"

    data = json.loads(raw.decode("utf-8-sig"))
    if isinstance(data, list):
        _read_timeline_segments(data, points, activities, visits, raw_max_acc)
        kind = "Google Timeline (iPhone export)"
    elif isinstance(data, dict) and ("semanticSegments" in data or "rawSignals" in data):
        _read_timeline_segments(data.get("semanticSegments") or [], points, activities, visits, raw_max_acc)
        _read_raw_signals(data.get("rawSignals"), points, raw_max_acc)
        kind = "Google Timeline (phone export)"
    elif isinstance(data, dict) and "locations" in data:
        _read_records(data["locations"], points, raw_max_acc)
        kind = "Google Takeout Records.json"
    elif isinstance(data, dict) and "timelineObjects" in data:
        _read_semantic_history(data["timelineObjects"], points, activities, visits)
        kind = "Google Takeout Semantic Location History"
    elif isinstance(data, dict) and data.get("type") in ("FeatureCollection", "Feature",
                                                          "LineString", "MultiLineString"):
        _read_geojson(data, path, points)
        kind = "GeoJSON"
    else:
        raise ValueError(f"Don't recognise the format of {path}.")
    return points, activities, visits, kind


# ===========================================================================
# From points to trips
# ===========================================================================

def _assign_modes(points, activities):
    if not activities:
        return points
    acts = sorted(a for a in activities if a[0] and a[1])
    starts = [a[0] for a in acts]
    out = []
    for p in points:
        if p.t is not None:
            i = bisect.bisect_right(starts, p.t) - 1
            while i >= 0 and acts[i][0] <= p.t:
                if acts[i][1] >= p.t:
                    p = p._replace(mode=p.mode or acts[i][2], act=i)
                    break
                i -= 1
        out.append(p)
    return out


VISIT_MOVE_M = 1000.0      # a "visit" whose points spread wider than this...
VISIT_MIN_SPEED = 0.8      # ...at an average of at least this many m/s (~3 km/h) was really travel


def _drop_visits(points, visits, margin=timedelta(minutes=2), activities=(), log=print):
    """
    Drop the points recorded while you were staying somewhere. Timeline
    sometimes labels a stretch of real travel as a visit (a stop), though;
    when the points inside a visit spread out over more than VISIT_MOVE_M,
    at an average of VISIT_MIN_SPEED or more, they are kept and given a
    travel mode instead (see _moving_visit_mode).
    """
    if not visits:
        return points
    vs = sorted(visits)
    starts = [v[0] for v in vs]
    where = []                       # visit index a point is dropped for, or None
    inside = defaultdict(list)       # visit index -> every point in its whole time span
    for k, p in enumerate(points):
        hit = None
        if p.t is not None:
            i = bisect.bisect_right(starts, p.t) - 1
            while i >= 0:
                s, e = vs[i]
                if s <= p.t <= e:
                    inside[i].append(k)
                    if hit is None and s + margin < p.t < e - margin:
                        hit = i
                if e < p.t - timedelta(days=2):
                    break
                i -= 1
        where.append(hit)

    def path_points(ks):
        """The plain path points among ks, in time order, without one-off
        jumps. (Timeline's activity start/end points are left out: they are
        sometimes placed kilometres from where the trip really began.)"""
        ps = sorted((points[k] for k in ks if not points[k].mode), key=lambda p: p.t)
        out = []
        for j, p in enumerate(ps):
            nb = [q for q in (ps[j - 1] if j else None, ps[j + 1] if j + 1 < len(ps) else None) if q]
            if nb and all(haversine(p.lat, p.lon, q.lat, q.lon)
                          > 60.0 * max(1.0, abs((p.t - q.t).total_seconds())) for q in nb):
                continue                 # faster than 60 m/s to every neighbour: a stray point
            out.append(p)
        return out

    def spread(ps):
        lats = [p.lat for p in ps]
        lons = [p.lon for p in ps]
        return haversine(min(lats), min(lons), max(lats), max(lons))

    def travelled(ks):
        ps = path_points(ks)
        if len(ps) < 3 or spread(ps) <= VISIT_MOVE_M:
            return False
        secs = max(1.0, (ps[-1].t - ps[0].t).total_seconds())
        return _length(ps) / secs >= VISIT_MIN_SPEED     # kept moving, not just arrived and left

    moving = sorted(i for i, ks in inside.items() if travelled(ks))
    # back-to-back mislabeled visits are one stretch of travel
    runs = []
    for i in moving:
        if runs and vs[i][0] <= runs[-1][2] + timedelta(minutes=2):
            runs[-1][1].append(i)
            runs[-1][2] = max(runs[-1][2], vs[i][1])
        else:
            runs.append([vs[i][0], [i], vs[i][1]])

    keep_as = {}                     # point index -> (mode, act id)
    for n, (r_start, idx, r_end) in enumerate(runs):
        ks = sorted({k for i in idx for k in inside[i]}, key=lambda k: points[k].t)
        clean = path_points(ks)
        dist = _length(clean)
        secs = max(1.0, (clean[-1].t - clean[0].t).total_seconds())
        mode = _moving_visit_mode(dist / secs, r_start, r_end, activities)
        for k in ks:
            # the points inside, plus the edge points kept by the margin
            if where[k] in idx or (where[k] is None and not points[k].mode):
                keep_as[k] = (mode, -(n + 1))
        cat = mode_category(mode) or "other"
        log(f"  Note: Timeline marked {local_time(r_start):%Y-%m-%d %H:%M}-{local_time(r_end):%H:%M} "
            f"as a stop, but the GPS moved {dist / 1000:.1f} km (about {dist / secs * 3.6:.0f} km/h); "
            f"treating it as {'unknown travel' if cat == 'other' else {'drive': 'driving', 'walk': 'walking', 'bike': 'cycling'}[cat]}.")

    out = []
    for k, p in enumerate(points):
        if k in keep_as:
            mode, act = keep_as[k]
            out.append(p if p.mode else p._replace(mode=mode, act=act))
        elif where[k] is None:
            out.append(p)
    return out


def _drop_spikes(pts, vmax=90.0):
    """Drop single points that are impossibly far from both their neighbours
    (faster than vmax m/s each way). Timeline sometimes puts an activity's
    start or end point kilometres away; left in, it splits the trip and
    leaves a gap in the road."""
    out = []
    for j, p in enumerate(pts):
        if 0 < j < len(pts) - 1:
            a, b = pts[j - 1], pts[j + 1]
            far = [haversine(p.lat, p.lon, q.lat, q.lon) > vmax * max(1.0, abs((p.t - q.t).total_seconds()))
                   for q in (a, b)]
            # ...and the neighbours themselves are close enough to join up
            if all(far) and haversine(a.lat, a.lon, b.lat, b.lon) <= vmax * max(1.0, (b.t - a.t).total_seconds()):
                continue
        out.append(p)
    return out


def _moving_visit_mode(speed, start, end, activities, near=timedelta(minutes=5)):
    """Travel mode for a mislabeled visit: from its average speed (m/s) and
    the activities just before and after it."""
    around = set()
    for a in activities:
        if a[0] and a[1] and len(a) > 2 and (abs(a[1] - start) <= near or abs(a[0] - end) <= near):
            c = mode_category(a[2])
            if c in ("drive", "walk", "bike"):
                around.add(c)
    if speed >= 8.0:                     # ~29 km/h average: not on foot or bike
        return "IN_PASSENGER_VEHICLE"
    if speed > 2.5 and "drive" in around:
        return "IN_PASSENGER_VEHICLE"
    if speed > 2.5 and "bike" in around:
        return "CYCLING"
    if speed <= 2.5:
        return "WALKING"
    return "UNKNOWN_TRAVEL"              # mapped as 'other' (any road or path)


def load_trips(paths, date_spec=None, travel_modes=CATEGORIES, gap_minutes=10.0,
               max_days_without_date=31, log=print):
    """Read files, filter by date/mode, and split into Trips."""
    points, activities, visits = [], [], []
    for path in paths:
        pts, acts, vis, kind = read_track_file(path)
        log(f"  {os.path.basename(path)}: {kind}, {len(pts)} point(s)")
        points += pts
        activities += acts
        visits += vis

    points = _localize(points, activities, visits)
    rng = parse_date_spec(date_spec)
    timed = [p for p in points if p.t is not None]
    if rng is None and date_spec is None and timed:
        days = {local_date(p.t) for p in timed}
        if len(days) > max_days_without_date:
            raise ValueError(
                f"These files cover {len(days)} days ({min(days)} to {max(days)}). "
                "Pick the dates to map with --date, e.g. --date 2026-10-30 or "
                "--date 2026-10-01..2026-10-31 (or --date all)."
            )

    if rng:
        first, last = rng
        if any(p.t is None for p in points):
            log("  Note: some points have no time, so --date can't filter them; they're kept.")
        points = [p for p in points if p.t is None
                  or ((first is None or local_date(p.t) >= first)
                      and (last is None or local_date(p.t) <= last))]

    points = _assign_modes(points, activities)
    points = _drop_visits(points, visits, activities=activities, log=log)

    wanted = set(travel_modes)
    groups = defaultdict(list)
    for p in points:
        groups[p.seg].append(p)

    trips = []
    for seg, pts in groups.items():
        if all(p.t is not None for p in pts):
            pts.sort(key=lambda p: p.t)
            pts = _drop_spikes(pts)
        cur, cat = [], None

        def flush():
            if len(cur) >= 2:
                c = cat or "other"
                if c in wanted:
                    trips.append(Trip(c, _downsample(cur, c)))

        prev = None
        for p in pts:
            pc = mode_category(p.mode)
            if pc == "skip":
                flush()
                cur, cat, prev = [], None, None
                continue
            split = False
            if prev is not None:
                d = haversine(prev.lat, prev.lon, p.lat, p.lon)
                if p.t is not None and prev.t is not None:
                    dt = (p.t - prev.t).total_seconds()
                    same_activity = p.act is not None and p.act == prev.act
                    if (dt > gap_minutes * 60 and not same_activity) \
                            or (dt > 0 and d / dt > 90) or (dt <= 0 and d > 2000):
                        split = True
                elif d > 5000:
                    split = True
                if pc and cat and pc != cat:
                    split = True
            if split:
                flush()
                cur, cat = [], None
            cur.append(p)
            if pc and cat is None:
                cat = pc
            prev = p
        flush()

    trips = [t for t in trips if len(t.points) >= 2 and _length(t.points) >= 50]
    trips.sort(key=lambda t: (t.points[0].t or datetime.min.replace(tzinfo=timezone.utc)))
    return trips


def _length(pts):
    return sum(haversine(a.lat, a.lon, b.lat, b.lon) for a, b in zip(pts, pts[1:]))


def _downsample(pts, category):
    spacing = _SPACING.get(category, 15.0)
    out = [pts[0]]
    for p in pts[1:]:
        if haversine(out[-1].lat, out[-1].lon, p.lat, p.lon) >= spacing:
            out.append(p)
    if out[-1] is not pts[-1] and len(pts) > 1:
        out.append(pts[-1])
    return out


def trip_length_km(trip):
    return _length(trip.points) / 1000.0


CELL_DEG = 0.005                      # ~550 m north-south, ~430-500 m east-west in the US
_RADIUS_STEPS = (150.0, 300.0, 600.0)


def _corridor_radius(gap_m):
    """How far from the straight line between two points the real road may
    run: wider when points are far apart."""
    want = 120.0 + 0.3 * gap_m
    return next((r for r in _RADIUS_STEPS if r >= want), _RADIUS_STEPS[-1])


def trip_cells(trip):
    """Grid cells (row, col) of CELL_DEG degrees covering a trip's corridor."""
    cells = set()
    pts = trip.points
    if len(pts) == 1:
        pts = pts * 2
    for a, b in zip(pts, pts[1:]):
        gap = haversine(a.lat, a.lon, b.lat, b.lon)
        r = _corridor_radius(gap)
        n = max(1, int(gap / 100.0))
        for k in range(n + 1):
            lat = a.lat + (b.lat - a.lat) * k / n
            lon = a.lon + (b.lon - a.lon) * k / n
            dlat = r / 111320.0
            dlon = r / (111320.0 * max(0.2, math.cos(math.radians(lat))))
            for row in range(math.floor((lat - dlat) / CELL_DEG), math.floor((lat + dlat) / CELL_DEG) + 1):
                for col in range(math.floor((lon - dlon) / CELL_DEG), math.floor((lon + dlon) / CELL_DEG) + 1):
                    cells.add((row, col))
    return cells


def cells_to_boxes(cells):
    """Merge cells into (south, west, north, east) boxes, one per run of
    neighbouring cells in a row."""
    rows = defaultdict(list)
    for r, c in cells:
        rows[r].append(c)
    boxes = []
    for r in sorted(rows):
        cols = sorted(rows[r])
        start = prev = cols[0]
        for c in cols[1:] + [None]:
            if c is not None and c == prev + 1:
                prev = c
                continue
            boxes.append((round(r * CELL_DEG, 6), round(start * CELL_DEG, 6),
                          round((r + 1) * CELL_DEG, 6), round((prev + 1) * CELL_DEG, 6)))
            if c is not None:
                start = prev = c
    return boxes


def point_cell(lat, lon):
    return (math.floor(lat / CELL_DEG), math.floor(lon / CELL_DEG))


def line_cells(coords, step_m=100.0):
    """Grid cells a polyline of (lat, lon) points passes through (sampled
    every ~step_m, so a long straight segment still marks each cell)."""
    cells = set()
    for a, b in zip(coords, coords[1:]):
        n = max(1, int(haversine(a[0], a[1], b[0], b[1]) / step_m))
        for k in range(n + 1):
            cells.add(point_cell(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n))
    if len(coords) == 1:
        cells.add(point_cell(*coords[0]))
    return cells


def dilate_cells(cells, steps=1):
    out = set(cells)
    for _ in range(steps):
        out |= {(r + dr, c + dc) for r, c in out for dr in (-1, 0, 1) for dc in (-1, 0, 1)}
    return out


def box_area_km2(box):
    s, w, n, e = box
    return (n - s) * 111.32 * (e - w) * 111.32 * math.cos(math.radians((n + s) / 2))


MAX_REQUEST_KM2 = 80.0                # most map area asked of Overpass in one request


def batch_boxes(boxes, max_km2=MAX_REQUEST_KM2):
    """Split boxes into requests of at most ~max_km2 each."""
    batches, cur, area = [], [], 0.0
    for b in boxes:
        a = box_area_km2(b)
        if cur and area + a > max_km2:
            batches.append(cur)
            cur, area = [], 0.0
        cur.append(b)
        area += a
    if cur:
        batches.append(cur)
    return batches


def group_trips(trips, max_km=60.0, max_jump_km=100.0):
    """Group consecutive trips so each group needs one road download."""
    groups, cur, km = [], [], 0.0
    for t in trips:
        tk = trip_length_km(t)
        jump = 0.0
        if cur:
            a, b = cur[-1].points[-1], t.points[0]
            jump = haversine(a.lat, a.lon, b.lat, b.lon) / 1000.0
        if cur and (km + tk > max_km or jump > max_jump_km):
            groups.append(cur)
            cur, km = [], 0.0
        cur.append(t)
        km += tk
    if cur:
        groups.append(cur)
    return groups


def utm_epsg(lons):
    lon = sum(lons) / len(lons)
    return f"EPSG:{32600 + int((lon + 180) / 6) + 1}"


# ===========================================================================
# Road network + HMM map matching
# ===========================================================================

def parse_overpass_network(data):
    """Overpass JSON ('out body; >; out skel') -> (ways, nodes)."""
    nodes, ways = {}, []
    for el in data.get("elements", []):
        if el.get("type") == "node":
            nodes[el["id"]] = (el["lat"], el["lon"])
        elif el.get("type") == "way":
            ways.append({"id": el["id"], "tags": el.get("tags", {}), "nodes": el.get("nodes", [])})
    return ways, nodes


def _query_tree(tree, geoms, geom):
    hits = tree.query(geom)
    if len(hits) and not isinstance(hits[0], (int,)) and hasattr(hits[0], "geom_type"):
        ids = {id(g): i for i, g in enumerate(geoms)}          # Shapely 1.8
        return [ids[id(g)] for g in hits]
    return [int(i) for i in hits]


class RoadNetwork:
    """Directed road graph for one kind of trip, in a projected CRS (meters)."""

    def __init__(self, ways, nodes, category, epsg):
        self.category = category
        self.epsg = epsg
        allowed = set(NETWORK_TYPES.get(category, NETWORK_TYPES["other"]))
        tf = Transformer.from_crs("EPSG:4326", epsg, always_xy=True)
        self.xy = {}
        self.edges = []                     # eid -> (u, v, way_id, length, fwd cost x, bwd cost x)
        self.adj = defaultdict(list)        # node -> [(nbr, cost, eid)]
        self.nbrs = defaultdict(set)        # node -> {(nbr, way_id)}
        self.way_tags = {}
        for w in ways:
            tags = w.get("tags", {})
            hw = tags.get("highway")
            if hw not in allowed:
                continue
            ns = [n for n in w["nodes"] if n in nodes]
            if len(ns) < 2:
                continue
            self.way_tags[w["id"]] = tags
            ffac, bfac = self._cost_factors(tags, hw)
            for a, b in zip(ns, ns[1:]):
                if a == b:
                    continue
                for n in (a, b):
                    if n not in self.xy:
                        lat, lon = nodes[n]
                        self.xy[n] = tf.transform(lon, lat)
                (x1, y1), (x2, y2) = self.xy[a], self.xy[b]
                length = math.hypot(x2 - x1, y2 - y1)
                if length == 0:
                    continue
                eid = len(self.edges)
                self.edges.append((a, b, w["id"], length, ffac, bfac))
                self.adj[a].append((b, length * ffac, eid))
                self.adj[b].append((a, length * bfac, eid))
                self.nbrs[a].add((b, w["id"]))
                self.nbrs[b].add((a, w["id"]))
        self.segments = [LineString([self.xy[e[0]], self.xy[e[1]]]) for e in self.edges]
        self.tree = STRtree(self.segments) if self.segments else None

    def _cost_factors(self, tags, hw):
        """Cost multipliers for (forward, backward) travel along a way.
        Going against a one-way street is allowed but expensive, so a bad
        one-way tag or a mislabelled trip can't derail the whole match."""
        base = 1.5 if self.category == "other" and hw in _PED_TYPES else 1.0
        if self.category in ("drive", "other"):
            base *= ROAD_CLASS_COST.get(hw, 1.0)
        if self.category == "walk":
            return base, base
        if self.category == "bike" and str(tags.get("oneway:bicycle", "")).lower() == "no":
            return base, base
        ow = str(tags.get("oneway", "")).lower()
        if ow in ("yes", "true", "1"):
            fwd, bwd = True, False
        elif ow in ("-1", "reverse"):
            fwd, bwd = False, True
        elif ow == "no":
            fwd, bwd = True, True
        elif tags.get("junction") in ("roundabout", "circular") or hw == "motorway":
            fwd, bwd = True, False
        else:
            fwd, bwd = True, True
        wrong = 3.0 if self.category == "other" else 5.0
        return base * (1 if fwd else wrong), base * (1 if bwd else wrong)

    # -- candidates
    def candidates(self, x, y, radius, k=5):
        if self.tree is None:
            return []
        p = Point(x, y)
        best = {}
        for i in _query_tree(self.tree, self.segments, p.buffer(radius)):
            seg = self.segments[i]
            d = seg.distance(p)
            if d > radius:
                continue
            wid = self.edges[i][2]
            if wid not in best or d < best[wid][0]:
                best[wid] = (d, i)
        out = []
        for d, i in sorted(best.values())[:k]:
            seg = self.segments[i]
            s = seg.project(Point(x, y))
            q = seg.interpolate(s)
            out.append(Candidate(i, s, d, q.x, q.y))
        return out

    # -- routing
    def _sources(self, c):
        u, v, _, length, fwd, bwd = self.edges[c.eid]
        src = {}
        src[v] = (length - c.s) * fwd
        src[u] = min(src.get(u, math.inf), c.s * bwd)
        return src

    def _dijkstra(self, sources, cutoff, targets=None):
        dist = dict(sources)
        pred = {n: None for n in sources}
        heap = [(d, n) for n, d in sources.items()]
        heapq.heapify(heap)
        remaining = set(targets) if targets else None
        done = set()
        while heap:
            d, n = heapq.heappop(heap)
            if n in done or d > dist.get(n, math.inf):
                continue
            done.add(n)
            if remaining is not None:
                remaining.discard(n)
                if not remaining:
                    break
            if d > cutoff:
                break
            for m, cost, eid in self.adj.get(n, ()):
                nd = d + cost
                if nd <= cutoff and nd < dist.get(m, math.inf):
                    dist[m] = nd
                    pred[m] = (n, eid)
                    heapq.heappush(heap, (nd, m))
        return dist, pred

    def _arrivals(self, a, c, dist):
        """Cheapest way to reach candidate c: (cost, entry node or None, direct)."""
        best = (math.inf, None)
        if c.eid == a.eid:
            _, _, _, _, fwd, bwd = self.edges[a.eid]
            if c.s >= a.s:
                best = min(best, ((c.s - a.s) * fwd, "direct"), key=lambda z: z[0])
            else:
                best = min(best, ((a.s - c.s) * bwd, "direct"), key=lambda z: z[0])
        cu, cv, _, cl, cf, cb = self.edges[c.eid]
        if cu in dist:
            best = min(best, (dist[cu] + c.s * cf, cu), key=lambda z: z[0])
        if cv in dist:
            best = min(best, (dist[cv] + (cl - c.s) * cb, cv), key=lambda z: z[0])
        return best

    def route_costs(self, a, cands, cutoff):
        targets = set()
        for c in cands:
            targets.add(self.edges[c.eid][0])
            targets.add(self.edges[c.eid][1])
        dist, _ = self._dijkstra(self._sources(a), cutoff, targets)
        return [self._arrivals(a, c, dist)[0] for c in cands]

    def route_path(self, a, b, cutoff):
        """Straight pieces [(way_id, (x1,y1), (x2,y2))] from a to b, plus the
        graph nodes passed through."""
        dist, pred = self._dijkstra(self._sources(a), cutoff,
                                    {self.edges[b.eid][0], self.edges[b.eid][1]})
        cost, entry = self._arrivals(a, b, dist)
        if cost == math.inf:
            return None, []
        wa, wb = self.edges[a.eid][2], self.edges[b.eid][2]
        if entry == "direct":
            return [(wa, (a.x, a.y), (b.x, b.y))], []
        chain = []
        n = entry
        while pred.get(n) is not None:
            prev, eid = pred[n]
            chain.append((prev, n, eid))
            n = prev
        chain.reverse()
        start = n                                       # where we left a's edge
        pieces = [(wa, (a.x, a.y), self.xy[start])]
        for p, q, eid in chain:
            pieces.append((self.edges[eid][2], self.xy[p], self.xy[q]))
        pieces.append((wb, self.xy[entry], (b.x, b.y)))
        nodes = [start] + [q for _, q, _ in chain]
        return pieces, nodes

    # -- junctions
    def junction_nodes(self, nodes, used_ways):
        """Nodes along the path where 3+ road directions meet."""
        out = []
        for n in set(nodes):
            ways = {w for _, w in self.nbrs.get(n, ())
                    if w in used_ways or self.way_tags[w].get("highway") not in MINOR_TYPES}
            if len(ways) < 2:
                continue
            dirs = {m for m, w in self.nbrs[n] if w in ways}
            if len(dirs) >= 3:
                out.append((n, sorted(ways)))
        return out


def match_trip(net, trip, log=print):
    """Map-match one Trip on `net`. Returns MatchResult with
    lines: [(LineString, tags)] in net.epsg."""
    tf = Transformer.from_crs("EPSG:4326", net.epsg, always_xy=True)
    obs = []
    for p in trip.points:
        x, y = tf.transform(p.lon, p.lat)
        sigma = min(50.0, max(8.0, p.acc if p.acc else NO_ACC_SIGMA))
        obs.append((x, y, p.t, sigma))

    vmax = _VMAX.get(trip.category, 60.0)
    chains, layers = [], []          # layers: [(cands, scores, back)]
    fails = skipped = 0

    def finish():
        if not layers:
            return
        cands, scores, _ = layers[-1]
        j = max(range(len(scores)), key=lambda k: scores[k])
        seq = []
        for li in range(len(layers) - 1, -1, -1):
            cands_l, _, back_l = layers[li]
            seq.append(cands_l[j])
            j = back_l[j] if back_l is not None else 0
        seq.reverse()
        chains.append(seq)

    prev_xy = prev_t = None
    for x, y, t, sigma in obs:
        radius = min(200.0, max(40.0, 4 * sigma))
        cands = net.candidates(x, y, radius) or net.candidates(x, y, radius * 2)
        if not cands:
            skipped += 1
            continue
        emis = [-0.5 * (c.d / sigma) ** 2 for c in cands]
        if not layers:
            layers.append((cands, emis, None))
            prev_xy, prev_t = (x, y), t
            continue
        p_cands, p_scores, _ = layers[-1]
        gc = math.hypot(x - prev_xy[0], y - prev_xy[1])
        dt = (t - prev_t).total_seconds() if (t and prev_t) else None
        beta = 4.0 + 0.15 * gc
        cutoff = 2.5 * gc + 400.0
        new_scores = [-math.inf] * len(cands)
        back = [0] * len(cands)
        for i, pc in enumerate(p_cands):
            if p_scores[i] == -math.inf:
                continue
            for j, cost in enumerate(net.route_costs(pc, cands, cutoff)):
                if cost == math.inf:
                    continue
                if dt and dt > 0 and cost / dt > vmax * 1.5:
                    continue
                sc = p_scores[i] - abs(cost - gc) / beta + emis[j]
                if sc > new_scores[j]:
                    new_scores[j], back[j] = sc, i
        if all(s == -math.inf for s in new_scores):
            fails += 1
            if fails <= 2:                      # probably a stray point: skip it
                skipped += 1
                continue
            finish()
            layers = [(cands, emis, None)]
            fails = 0
        else:
            fails = 0
            layers.append((cands, new_scores, back))
        prev_xy, prev_t = (x, y), t
    finish()

    lines, path_nodes, way_ids = [], [], set()
    for seq in chains:
        pieces = []
        for a, b in zip(seq, seq[1:]):
            gc = math.hypot(b.x - a.x, b.y - a.y)
            pcs, ns = net.route_path(a, b, 3.0 * gc + 1000.0)
            if pcs:
                pieces += pcs
                path_nodes += ns
        merged = _merge_pieces(pieces, net.way_tags, with_ids=True)
        # GPS noise at the very start/end of a stretch can poke a few meters
        # into a cross street; trim those stubs.
        while len(merged) > 1 and merged[0][0].length < END_STUB_M:
            merged.pop(0)
        while len(merged) > 1 and merged[-1][0].length < END_STUB_M:
            merged.pop()
        lines += [(line, tags) for line, tags, _ in merged]
        way_ids |= {wid for _, _, wid in merged}
    return MatchResult(lines, path_nodes, way_ids, len(obs) - skipped,
                       max(0, len(chains) - 1), skipped)


def _merge_pieces(pieces, way_tags, with_ids=False):
    """Join consecutive straight pieces of the same way into LineStrings."""
    lines, cur, cur_way = [], [], None

    def emit():
        if len(cur) >= 2:
            item = (LineString(cur), way_tags.get(cur_way, {}))
            lines.append(item + (cur_way,) if with_ids else item)

    for wid, p, q in pieces:
        if math.hypot(q[0] - p[0], q[1] - p[1]) < 0.01:
            continue
        if cur and wid == cur_way and math.hypot(cur[-1][0] - p[0], cur[-1][1] - p[1]) < 0.01:
            cur.append(q)
            continue
        emit()
        cur, cur_way = [p, q], wid
    emit()
    return lines
