#!/usr/bin/env python3
"""
test_road_to_kml.py
-------------------
Offline regression tests for road_to_kml.py, road_aliases.py and
road_tracks.py. Nothing touches the network: Overpass, Nominatim and the
Census downloads are replaced by fakes built from a small synthetic street
grid in northwest DC.

Run after editing the alias tables or upgrading packages:

    python test_road_to_kml.py            (or: python -m pytest test_road_to_kml.py)

Tests that need geopandas (TIGER/Line) are skipped if it isn't installed.
"""

import contextlib
import csv
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from datetime import date, datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# Keep the real Overpass mirror tally out of the tests (subprocesses inherit this).
STATS_DIR = tempfile.mkdtemp(prefix="r2k_stats_")
os.environ["ROAD_TO_KML_MIRROR_STATS"] = os.path.join(STATS_DIR, "overpass_mirror_stats.txt")

import mirror_stats as ms          # noqa: E402
import road_aliases as ra          # noqa: E402
import road_tracks as rt           # noqa: E402
import road_to_kml as rk           # noqa: E402
from shapely.geometry import LineString, Point, Polygon   # noqa: E402
from shapely.ops import unary_union                        # noqa: E402

try:
    import geopandas as gpd       # noqa: F401
    HAVE_GPD = True
except ImportError:
    HAVE_GPD = False


# ===========================================================================
# Synthetic world: a 6 x 6 grid of 200 m blocks in northwest DC
# ===========================================================================
LAT0, LON0 = 38.930, -77.070
DLAT = 200 / 111320.0
DLON = 200 / (111320.0 * math.cos(math.radians(LAT0)))
M_LON = 1 / (111320.0 * math.cos(math.radians(LAT0)))   # degrees per meter east
M_LAT = 1 / 111320.0                                      # degrees per meter north

ROWS = ["Cathedral", "Macomb", "Newark", "Ordway", "Porter", "Quebec"]     # streets, south->north
COLS = [("36th", "Street", "residential"), ("35th", "Street", "residential"),
        ("Wisconsin", "Avenue", "secondary"), ("Connecticut", "Avenue", "primary"),
        ("Reno", "Road", "tertiary"), ("Nebraska", "Avenue", "secondary")]


def node_id(r, c):
    return 1000 + r * 10 + c


def ll(r, c):
    return LAT0 + r * DLAT, LON0 + c * DLON


NODES = {node_id(r, c): ll(r, c) for r in range(6) for c in range(6)}
WAYS = []        # dicts: id, tags, nodes
AREA_POLYS = []  # (id, [(lat, lon), ...]) area:highway outlines


def _way(wid, tags, nodes):
    WAYS.append({"id": wid, "tags": tags, "nodes": nodes})


wid = 1
for r, name in enumerate(ROWS):
    kind = "Avenue" if name == "Cathedral" else "Street"
    tags = {"highway": "residential", "name": f"{name} {kind} Northwest"}
    if name == "Porter":
        tags["old_name"] = "Lee Highway"
    _way(wid, dict(tags), [node_id(r, c) for c in range(0, 4)]); wid += 1
    _way(wid, dict(tags), [node_id(r, c) for c in range(3, 6)]); wid += 1
for c, (name, kind, hw) in enumerate(COLS):
    _way(wid, {"highway": hw, "name": f"{name} {kind} Northwest"}, [node_id(r, c) for r in range(6)]); wid += 1

# Sidewalk beside Connecticut (driving must never use it)
NODES[5001] = (LAT0, LON0 + 3 * DLON + 9 * M_LON)
NODES[5002] = (LAT0 + 5 * DLAT, LON0 + 3 * DLON + 9 * M_LON)
_way(90, {"highway": "footway", "footway": "sidewalk"}, [5001, 5002])

# A freeway east of the grid with a two-piece ramp to Nebraska Ave at row 2
for i in range(4):
    NODES[6000 + i] = (LAT0 + i * 1.5 * DLAT, LON0 + 6.5 * DLON)
NODES[6100] = (LAT0 + 2 * DLAT, LON0 + 6.0 * DLON + 40 * M_LON)
_way(91, {"highway": "motorway", "ref": "I 95", "oneway": "yes"}, [6000, 6001, 6002, 6003])
_way(92, {"highway": "motorway_link", "oneway": "yes"}, [6001, 6100])
_way(93, {"highway": "motorway_link", "oneway": "yes"}, [6100, node_id(2, 5)])

# Mapped pavement outline: Connecticut between Macomb and Newark, 20 m wide
_lat1, _lat2 = LAT0 + 1 * DLAT + 10 * M_LAT, LAT0 + 2 * DLAT - 10 * M_LAT
_lonc = LON0 + 3 * DLON
AREA_POLYS.append((700, [(_lat1, _lonc - 10 * M_LON), (_lat1, _lonc + 10 * M_LON),
                         (_lat2, _lonc + 10 * M_LON), (_lat2, _lonc - 10 * M_LON),
                         (_lat1, _lonc - 10 * M_LON)]))

MD_WAY = {"id": 300, "tags": {"highway": "primary", "name": "Rockville Pike", "ref": "MD 355"},
          "nodes": [8001, 8002]}
NODES[8001] = (39.04, -77.10)
NODES[8002] = (39.06, -77.11)
WAYS.append(MD_WAY)

AREA_WAYS = {"1": {w["id"] for w in WAYS if w["id"] != 300}, "2": {300}}
WAY_BY_ID = {w["id"]: w for w in WAYS}
QUERIES = []
FAULTS = {"big_track_requests": False, "all_track_requests": False, "name_once": False,
          "hide_ways": set()}
_BBOX_RE = re.compile(r'\]\((-?[\d.]+),(-?[\d.]+),(-?[\d.]+),(-?[\d.]+)\);')
_OOM = {"elements": [], "remark": "runtime error: Query run out of memory using about 2048 MB of RAM."}


def _way_geometry(w):
    return [{"lat": NODES[n][0], "lon": NODES[n][1]} for n in w["nodes"]]


def _fake_overpass(url, query, timeout=130):
    """Stand-in for Overpass that understands the queries road_to_kml builds."""
    QUERIES.append(query)
    elements = []

    if "area:highway" in query:                       # pavement outlines
        for aid, ring in AREA_POLYS:
            elements.append({"type": "way", "id": aid, "tags": {"area:highway": "primary"},
                             "geometry": [{"lat": a, "lon": b} for a, b in ring]})
        return {"elements": elements}

    if "way(bn.n)" in query:                          # junction / ramp context
        ids = {int(i) for i in re.search(r"way\(id:([\d,]+)\)", query).group(1).split(",")}
        road_nodes = {n for i in ids if i in WAY_BY_ID for n in WAY_BY_ID[i]["nodes"]}
        x = [w for w in WAYS if set(w["nodes"]) & road_nodes]
        out = {w["id"]: w for w in x}
        if "_link$" in query:
            frontier = [w for w in x if w["tags"].get("highway", "").endswith("_link")]
            for _ in range(2):
                fn = {n for w in frontier for n in w["nodes"]}
                frontier = [w for w in WAYS if w["tags"].get("highway", "").endswith("_link")
                            and set(w["nodes"]) & fn and w["id"] not in out]
                out.update({w["id"]: w for w in frontier})
        for w in out.values():
            elements.append({"type": "way", "id": w["id"], "tags": w["tags"],
                             "nodes": w["nodes"], "geometry": _way_geometry(w)})
        return {"elements": elements}

    boxes = [tuple(map(float, b)) for b in _BBOX_RE.findall(query)]
    if boxes and "(area:" not in query:               # --track road network (boxes)
        if FAULTS["all_track_requests"] or (FAULTS["big_track_requests"] and len(boxes) > 1):
            return dict(_OOM)
        types = set(re.search(r'\["highway"~"\^\((.*?)\)\$"\]', query).group(1).split("|"))
        inside = lambda n: any(s <= NODES[n][0] <= nn and w <= NODES[n][1] <= e for s, w, nn, e in boxes)
        used = set()
        for w in WAYS:
            if w["id"] in FAULTS["hide_ways"]:
                continue
            if w["tags"].get("highway") in types and any(inside(n) for n in w["nodes"]):
                elements.append({"type": "way", "id": w["id"], "tags": w["tags"], "nodes": w["nodes"]})
                used |= set(w["nodes"])
        elements += [{"type": "node", "id": n, "lat": NODES[n][0], "lon": NODES[n][1]} for n in used]
        return {"elements": elements}

    if FAULTS["name_once"]:                           # one failed reply, then fine
        FAULTS["name_once"] = False
        return dict(_OOM)

    # named-road search
    clauses = re.findall(r'\["(\w+)"~"(.*?)",i\]\(area:(\d+)\)', query)
    assert clauses, query
    area = clauses[0][2]
    used = set()
    for w in WAYS:
        if w["id"] not in AREA_WAYS.get(area, set()):
            continue
        if any(re.search(rx, w["tags"].get(k, ""), re.I) for k, rx, _ in clauses):
            elements.append({"type": "way", "id": w["id"], "tags": w["tags"], "nodes": w["nodes"]})
            used |= set(w["nodes"])
    elements += [{"type": "node", "id": n, "lat": NODES[n][0], "lon": NODES[n][1]} for n in used]
    return {"version": 0.6, "elements": elements}


# TIGER: the same grid with Census-style names, plus Rockville Pike in MD
def _tiger_rows():
    rows11001, featnames11001 = [], []
    lid = 1
    for r, name in enumerate(ROWS):
        kind = "Ave" if name == "Cathedral" else "St"
        rows11001.append(dict(LINEARID=str(lid), FULLNAME=f"{name} {kind} NW", MTFCC="S1400",
                              geometry=LineString([ll(r, c)[::-1] for c in range(6)])))
        lid += 1
    mt = {"residential": "S1400", "secondary": "S1200", "primary": "S1200", "tertiary": "S1400"}
    for c, (name, kind, hw) in enumerate(COLS):
        k = {"Street": "St", "Avenue": "Ave", "Road": "Rd"}[kind]
        rows11001.append(dict(LINEARID=str(lid), FULLNAME=f"{name} {k} NW", MTFCC=mt[hw],
                              geometry=LineString([ll(r, c)[::-1] for r in range(6)])))
        lid += 1
    rows24031 = [dict(LINEARID="240", FULLNAME="Rockville Pike", MTFCC="S1200",
                      geometry=LineString([NODES[8001][::-1], NODES[8002][::-1]])),
                 dict(LINEARID="241", FULLNAME="State Rte 35", MTFCC="S1200",
                      geometry=LineString([(-77.2, 39.1), (-77.21, 39.11)]))]
    feat24031 = [dict(LINEARID="240", FULLNAME="State Rte 355")]
    return {"11001": (rows11001, featnames11001), "24031": (rows24031, feat24031)}


DOWNLOADS = []


def _make_zip(kind, rows):
    d = tempfile.mkdtemp()
    try:
        if kind == "roads":
            gpd.GeoDataFrame(rows, geometry="geometry", crs="EPSG:4269").to_file(
                os.path.join(d, "tl_x_roads.shp"))
        else:
            rows = rows or [dict(LINEARID="0", FULLNAME="")]
            gpd.GeoDataFrame(rows, geometry=[None] * len(rows)).to_file(
                os.path.join(d, "tl_x_featnames.dbf"))
        b = io.BytesIO()
        with zipfile.ZipFile(b, "w") as z:
            for f in os.listdir(d):
                z.write(os.path.join(d, f), f)
        return b.getvalue()
    finally:
        shutil.rmtree(d, ignore_errors=True)


_TIGER_CACHE = {}


def _fake_tiger(layer, fips, year):
    DOWNLOADS.append((layer, fips, year))
    if year > 2024:                    # pretend newer years aren't published yet
        return None
    data = _tiger_rows().get(fips)
    if not data:
        return None
    key = (layer, fips)
    if key not in _TIGER_CACHE:
        rows = data[0] if layer == "ROADS" else data[1]
        _TIGER_CACHE[key] = _make_zip(layer.lower(), rows)
    return _TIGER_CACHE[key]


_COUNTY_ZIP = {}


def _fake_county_shapes(year):
    """County outlines: DC around the grid, Montgomery County MD up north."""
    DOWNLOADS.append(("COUNTY", "us", year))
    if year > 2024:
        return None
    if "zip" not in _COUNTY_ZIP:
        from shapely.geometry import box
        rows = [dict(GEOID="11001", STATEFP="11", NAME="District of Columbia",
                     NAMELSAD="District of Columbia",
                     geometry=box(LON0 - 0.03, LAT0 - 0.03, LON0 + 0.05, LAT0 + 0.03)),
                dict(GEOID="24031", STATEFP="24", NAME="Montgomery", NAMELSAD="Montgomery County",
                     geometry=box(-77.3, 39.0, -77.0, 39.3))]
        d = tempfile.mkdtemp()
        try:
            gpd.GeoDataFrame(rows, geometry="geometry", crs="EPSG:4269").to_file(os.path.join(d, "cb.shp"))
            b = io.BytesIO()
            with zipfile.ZipFile(b, "w") as z:
                for f in os.listdir(d):
                    z.write(os.path.join(d, f), f)
            _COUNTY_ZIP["zip"] = b.getvalue()
        finally:
            shutil.rmtree(d, ignore_errors=True)
    return _COUNTY_ZIP["zip"]


def install_fakes():
    rk._overpass_post = _fake_overpass
    rk._download_tiger = _fake_tiger
    rk._download_county_shapes = _fake_county_shapes
    rk.get_state_area_id = lambda s: {"District of Columbia": 1, "Maryland": 2,
                                      "Virginia": 3, "Pennsylvania": 4}[s]
    rk.get_county_area_id = lambda c, s: 2 if s == "Maryland" else 5
    rk.get_city_area_id = lambda c, s: 1


def read_kml(path):
    """Union of the polygons in a KML written by road_to_kml."""
    text = open(path, encoding="utf-8").read()
    polys = []
    for pm in re.findall(r"<Polygon.*?</Polygon>", text, re.S):
        def ring(block):
            pts = re.search(r"<coordinates>(.*?)</coordinates>", block, re.S).group(1).split()
            return [tuple(map(float, p.split(",")[:2])) for p in pts]
        outer = ring(re.search(r"<outerBoundaryIs>.*?</outerBoundaryIs>", pm, re.S).group(0))
        inner = [ring(b) for b in re.findall(r"<innerBoundaryIs>.*?</innerBoundaryIs>", pm, re.S)]
        polys.append(Polygon(outer, inner))
    return unary_union(polys)


def at(r, c, east_m=0.0, north_m=0.0):
    lat, lon = ll(r, c)
    return Point(lon + east_m * M_LON, lat + north_m * M_LAT)


def run_main(argv):
    """Run road_to_kml.main quietly; returns (exit code, output text, result)."""
    QUERIES.clear()
    DOWNLOADS.clear()
    rk._TIGER_YEAR_FOUND = None
    rk._COUNTY_SHAPES = None          # each command-line run starts fresh
    rk._TIGER_ROADS.clear()
    buf, err = io.StringIO(), io.StringIO()
    code, result = 0, None
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err):
        try:
            result = rk.main(argv)
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
    return code, buf.getvalue() + err.getvalue(), result


class TempDirTest(unittest.TestCase):
    def setUp(self):
        install_fakes()
        self._old = os.getcwd()
        self.tmp = tempfile.mkdtemp()
        os.chdir(self.tmp)

    def tearDown(self):
        os.chdir(self._old)
        shutil.rmtree(self.tmp, ignore_errors=True)


# ===========================================================================
# 1. Aliases
# ===========================================================================
REGEX_CASES = [
    ("Cathedral Ave NW", "dc",
     ["Cathedral Avenue Northwest", "Cathedral Ave NW", "Cathedral Ave. N.W.", "cathedral avenue nw",
      "foo;Cathedral Avenue Northwest"],
     ["Cathedral Avenue Northeast", "Cathedral Street Northwest", "Old Cathedral Avenue Northwest"]),
    ("MD 355", "md", ["MD 355", "MD-355", "MD355", "Maryland Route 355", "Md. Rte. 355", "Route 355",
                      "US 29;MD 355"], ["MD 35", "MD 3555", "US 355", "VA 355"]),
    ("MD 355", "va", ["MD 355", "Maryland Route 355"], ["Route 355", "VA 355"]),
    ("I-95", None, ["I 95", "I-95", "I95", "I- 95", "Interstate 95", "IH 95"], ["I 9", "I 395", "US 95"]),
    ("US 1", "md", ["US 1", "U.S. Route 1", "US Hwy 1", "Route 1"], ["US 15", "US 1A", "MD 1"]),
    ("Route 7", "va", ["VA 7", "Virginia Route 7", "SR 7", "US 7"], ["MD 7", "VA 77"]),
    ("FM 1960", "tx", ["Farm to Market Road 1960", "Farm-to-Market Road 1960", "RM 1960"], ["FM 196"]),
    ("N St NW", "dc", ["N Street Northwest", "N St NW"], ["North Street Northwest", "M Street Northwest"]),
    ("St Paul St", "md", ["Saint Paul Street", "St. Paul St."], ["Saint Paul Avenue"]),
    ("Mass Ave NW", "dc", ["Massachusetts Avenue Northwest"], ["Massachusetts Avenue Southeast"]),
    ("1st St NE", "dc", ["First Street Northeast", "1st Street Northeast"], ["21st Street Northeast"]),
    ("MLK Jr Ave SE", "dc", ["Martin Luther King Junior Avenue Southeast"], ["Martin Luther Avenue SE"]),
    ("GW Pkwy", "va", ["George Washington Memorial Parkway", "G.W. Parkway"], ["George Washington Boulevard"]),
    ("M-14", "mi", ["M 14", "M-14", "Michigan State Trunkline 14"], ["M 140"]),
    ("Prince George's Blvd", "md", ["Prince Georges Boulevard", "Prince George’s Boulevard"], []),
    ("CA 1", "ca", ["CA 1", "Highway 1", "California State Route 1"], ["CA 101", "US 1"]),
]

MATCH_CASES = [
    ("Cathedral Avenue Northwest", "dc", ["Cathedral Ave NW"], ["Cathedral Ave NE"]),
    ("MD 355", "md", ["State Rte 355", "MD- 355", "Rte 355"], ["State Rte 35", "US Hwy 355"]),
    ("US 1", "md", ["US Hwy 1", "US Hwy 1 Bus"], ["US Hwy 15", "Old Domain St"]),
    ("I-95", "md", ["I- 95", "Interstate 95"], ["I- 395", "I- 9"]),
    ("TX 71", "tx", ["State Hwy 71", "Hwy 71"], ["US Hwy 71", "Fm 71"]),
    ("Main St", "tx", ["Main St", "N Main St"], ["Domain St", "Main Ave"]),
    ("MD 355", "va", [], ["State Rte 355"]),
]


class AliasTests(unittest.TestCase):
    def test_overpass_regex_python(self):
        for q, st, pos, neg in REGEX_CASES:
            rx = re.compile(ra.overpass_tag_regex(q, st), re.I)
            for s in pos:
                self.assertTrue(rx.search(s), f"{q!r} [{st}] should match {s!r}")
            for s in neg:
                self.assertFalse(rx.search(s), f"{q!r} [{st}] should not match {s!r}")

    @unittest.skipUnless(shutil.which("grep"), "POSIX grep not available")
    def test_overpass_regex_posix(self):
        """Overpass uses POSIX regexes; GNU grep -E is a close stand-in."""
        for q, st, pos, neg in REGEX_CASES:
            rx = ra.overpass_tag_regex(q, st)
            p = subprocess.run(["grep", "-E", "-i", "--", rx], input="\n".join(pos + neg) + "\n",
                               capture_output=True, text=True)
            self.assertNotEqual(p.returncode, 2, p.stderr)
            got = set(p.stdout.splitlines())
            self.assertEqual(got & set(pos), set(pos), q)
            self.assertFalse(got & set(neg), q)

    def test_matcher(self):
        for q, st, pos, neg in MATCH_CASES:
            m = ra.RoadMatcher(q, st)
            for c in pos:
                self.assertTrue(m.matches(c), f"{q} -> {c}")
            for c in neg:
                self.assertFalse(m.matches(c), f"{q} -/-> {c}")
        self.assertFalse(ra.RoadMatcher("x").matches(float("nan")))

    def test_renames_are_county_scoped(self):
        self.assertTrue(ra.RoadMatcher("Langston Blvd", "va", "51013").matches("Lee Hwy"))
        self.assertFalse(ra.RoadMatcher("Langston Blvd", "va").matches("Lee Hwy"))
        self.assertFalse(ra.RoadMatcher("Lee Highway", "va", "51059").matches("Langston Blvd"))
        self.assertIn("--county", ra.rename_hint("Lee Hwy", "va"))
        self.assertIsNone(ra.rename_hint("Lee Hwy", "va", "51013"))

    def test_every_table_entry_parses(self):
        for forms in ra.NAMED_ROADS:
            for f in forms:
                self.assertTrue(ra.parse(f), f)
        for abbr in ra.STATES:
            self.assertEqual(ra.resolve_state(ra.STATES[abbr][0]), abbr)
            self.assertEqual(ra.resolve_state(abbr.upper()), abbr)


# ===========================================================================
# 2. Planning, filenames, geometry helpers, upkeep
# ===========================================================================
class PlanningTests(unittest.TestCase):
    def test_states(self):
        self.assertEqual([s.abbr for s in rk._parse_states("Washington, DC")], ["dc"])
        self.assertEqual([s.abbr for s in rk._parse_states("WA, DC")], ["wa", "dc"])
        self.assertEqual([s.abbr for s in rk._parse_states("texas, Calif., N.Y., Penn, D.C.")],
                         ["tx", "ca", "ny", "pa", "dc"])

    def test_counties(self):
        for name, st, want in [("Prince Georges County", "md", "24033"), ("St. Mary's", "md", "24037"),
                               ("Saint Louis City", "mo", "29510"), ("Fairfax", "va", "51059"),
                               ("Fairfax City", "va", "51600"), ("Alexandria", "va", "51510"),
                               ("Baltimore City", "md", "24510"), ("Orleans", "la", "22071"),
                               ("anything", "dc", "11001")]:
            self.assertEqual(rk._lookup_county(name, st)[0], want, name)
        self.assertIsNone(rk._lookup_county("King", "va")[0])

    def test_area_plan(self):
        md_dc = rk._parse_states("MD, DC")
        areas = rk._plan_search_areas(md_dc, "Montgomery County")
        self.assertEqual([(a.state.abbr, a.fips) for a in areas], [("md", "24031"), ("dc", "11001")])
        with self.assertRaises(ValueError):
            rk._plan_search_areas(rk._parse_states("MD, PA"), "Montgomery County")
        areas = rk._plan_search_areas(rk._parse_states("MD, PA"), "Montgomery County (MD)")
        self.assertEqual([(a.state.abbr, a.county) for a in areas],
                         [("md", "Montgomery County"), ("pa", None)])
        areas = rk._plan_search_areas(rk._parse_states("Maryland"), "Montgomery County, MD")
        self.assertEqual(len(areas), 1)

    def test_filenames(self):
        st = [rk.StateInfo("dc", "District of Columbia", "DC")]
        self.assertEqual(rk.default_output_name("Cathedral Ave NW", "", st, [], ["tiger"]),
                         "Cathedral_Ave_NW_DC_tiger.kml")
        long = rk.default_output_name("A Very Long Road " * 20, "", st, [], ["osm", "tiger"])
        self.assertLessEqual(len(long), rk.MAX_FILENAME_LEN)
        self.assertTrue(long.endswith("_osm_tiger.kml"))

    def test_offset_buffer(self):
        line = LineString([(0, 0), (100, 0)])                  # heading east; left = north
        band = rk._offset_buffer(line, 8, -5)                   # sidewalk 5..8 m left
        self.assertAlmostEqual(band.area, 300, delta=1)
        self.assertTrue(band.contains(Point(50, 6.5)))
        self.assertFalse(band.contains(Point(50, 2)))
        both = rk._offset_buffer(line, 5, 2)
        self.assertAlmostEqual(both.area, 700, delta=1)
        right = rk._offset_buffer(line, -2, 6)                  # 2..6 m right
        self.assertTrue(right.contains(Point(50, -4)))
        self.assertAlmostEqual(right.area, 400, delta=1)

    def test_fips_age_reminder(self):
        class M:
            _COUNTY_FIPS_UPDATED = "2026-10-31"
        self.assertIsNone(rk._check_county_fips_age(M, date(2027, 10, 30)))
        self.assertIn("days ago", rk._check_county_fips_age(M, date(2027, 11, 2)))
        import county_fips
        self.assertTrue(hasattr(county_fips, "_COUNTY_FIPS_UPDATED"))

    def test_tiger_years(self):
        rk._TIGER_YEAR_FOUND = None
        years = rk._tiger_years()
        self.assertEqual(years[0], date.today().year)
        self.assertEqual(years[-1], rk.TIGER_OLDEST_YEAR)
        rk._TIGER_YEAR_FOUND = 2024
        self.assertEqual(rk._tiger_years()[0], 2024)
        rk._TIGER_YEAR_FOUND = None


# ===========================================================================
# 3. Named roads end to end (fake Overpass / Census)
# ===========================================================================
class NamedRoadTests(TempDirTest):
    def test_alias_osm_and_outline(self):
        code, out, path = run_main(["--road", "Conn Ave NW", "--state", "DC", "--source", "osm",
                                    "--no-junctions"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "Conn_Ave_NW_DC_osm.kml")
        g = read_kml(path)
        self.assertTrue(g.contains(at(4, 3, east_m=5)))
        # The mapped outline is 20 m wide between Macomb and Newark; elsewhere 14 m
        self.assertTrue(g.contains(at(1.5, 3, east_m=9)), "outline should be used")
        self.assertFalse(g.contains(at(3.5, 3, east_m=9)), "buffer elsewhere")
        code, out, path = run_main(["--road", "Conn Ave NW", "--state", "DC", "--source", "osm",
                                    "--no-junctions", "--no-outlines", "--output", "x.kml"])
        self.assertFalse(read_kml("x.kml").contains(at(1.5, 3, east_m=9)))
        code, out, _ = run_main(["--road", "Conn Ave NW", "--state", "DC", "--source", "osm",
                                 "--no-junctions", "--outlines", "both", "--output", "b.kml"])
        self.assertEqual(code, 0, out)
        self.assertIn("Combining 1 pavement outline(s) with the buffered centerlines", out)
        g = read_kml("b.kml")
        self.assertTrue(g.contains(at(1.5, 3, east_m=9)), "outline kept")
        self.assertTrue(g.contains(at(4, 3, east_m=5)), "centerline kept")

    def test_outline_modes(self):
        """on: the outline replaces the centerline it covers; both: union of the two."""
        def layer():
            return rk.Layer([(LineString([(0, 0), (100, 0)]), {"highway": "primary"})], "EPSG:32618", "osm")
        to_wgs = lambda poly: rk._reproject(poly, "EPSG:32618", "EPSG:4326")
        narrow = to_wgs(Polygon([(10, -3), (90, -3), (90, 3), (10, 3)]))    # 6 m, narrower than 14 m
        on, both = layer(), layer()
        self.assertEqual(rk.apply_outlines([on], [narrow]), 1)
        self.assertEqual(rk.apply_outlines([both], [narrow], keep_lines=True), 1)
        self.assertAlmostEqual(sum(l.length for l, _ in on.lines), 20, delta=1)
        self.assertAlmostEqual(sum(l.length for l, _ in both.lines), 100, delta=0.01)
        self.assertEqual(len(on.polys), 1)
        self.assertEqual(len(both.polys), 1)
        p = rk.build_parser()
        self.assertEqual(p.parse_args([]).outlines, "on")
        self.assertEqual(p.parse_args(["--outlines"]).outlines, "on")
        self.assertEqual(p.parse_args(["--outlines", "Both"]).outlines, "both")
        self.assertEqual(p.parse_args(["--no-outlines"]).outlines, "off")
        self.assertEqual(p.parse_args(["--outlines", "off"]).outlines, "off")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            p.parse_args(["--outlines", "maybe"])
        self.assertEqual(rk._batch_row_args({"outlines": "both"}), ["--outlines", "both"])
        self.assertEqual(rk._batch_row_args({"outlines": "no"}), ["--no-outlines"])
        self.assertEqual(rk._batch_row_args({"outlines": "yes"}), ["--outlines"])

    def test_junction_trim(self):
        """Like a turn between a wide road and a narrower one: the circle's
        bulge is cut off with a straight edge, the notch between the two
        flat road ends stays filled, and a failed trim leaves the circle."""
        a = LineString([(-60, 20), (0, 0)]).buffer(10, cap_style=2, join_style=2)
        b = LineString([(0, 0), (0, -60)]).buffer(6, cap_style=2, join_style=2)
        disc = rk._junction_disc((0, 0), [20, 12])
        (fill,), trimmed, kept = rk.trim_junction_fill([disc], [a, b])
        self.assertEqual((trimmed, kept), (1, 0))
        self.assertTrue(fill.within(disc.buffer(1e-6)))
        self.assertTrue(fill.contains(Point(2, 2)), "notch between the road ends")
        self.assertFalse(a.union(b).contains(Point(2, 2)))
        self.assertTrue(disc.contains(Point(8, 8)))
        self.assertFalse(fill.contains(Point(8, 8)), "bulge beyond the roads")
        left = []
        self.assertEqual(rk.trim_junction_fill([disc], [], left), ([disc], 0, 1), "nothing to trim to")
        self.assertEqual(len(left), 1)
        self.assertAlmostEqual(left[0][0], 0, delta=1e-6)
        self.assertAlmostEqual(left[0][1], 0, delta=1e-6)
        self.assertIn("No drawn road", left[0][2])
        real = rk.road_tracks._query_tree
        rk.road_tracks._query_tree = lambda *a: (_ for _ in ()).throw(RuntimeError("GEOS error"))
        try:
            self.assertEqual(rk.trim_junction_fill([disc], [a, b]), ([disc], 0, 1), "failure keeps the circle")
        finally:
            rk.road_tracks._query_tree = real

    def test_pins_for_junctions_left_round(self):
        def pins(path):
            text = open(path, encoding="utf-8").read()
            out = []
            for pm in re.findall(r"<Placemark.*?</Placemark>", text, re.S):
                c = re.search(r"<Point[ >].*?<coordinates>(.*?)</coordinates>", pm, re.S)
                if c:
                    lon, lat = map(float, c.group(1).split(",")[:2])
                    out.append((lon, lat, re.search(r"<description>(.*?)</description>", pm, re.S).group(1)))
            return out
        args = ["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm", "--no-outlines"]
        code, out, path = run_main(args + ["--output", "ok.kml"])
        self.assertEqual(code, 0, out)
        self.assertEqual(pins("ok.kml"), [], "every junction trimmed: no pins")
        real = rk.road_tracks._query_tree
        rk.road_tracks._query_tree = lambda *a: (_ for _ in ()).throw(RuntimeError("TopologyException"))
        try:
            code, out, _ = run_main(args + ["--output", "round.kml"])
        finally:
            rk.road_tracks._query_tree = real
        self.assertEqual(code, 0, out)
        self.assertIn("each marked with a pin in the KML", out)
        got = pins("round.kml")
        self.assertTrue(got)
        self.assertIn("Junctions left round (", open("round.kml", encoding="utf-8").read())
        newark = at(2, 3)                                # Connecticut x Newark
        self.assertTrue(any(abs(lon - newark.x) < 1e-5 and abs(lat - newark.y) < 1e-5 for lon, lat, _ in got))
        self.assertTrue(all("Trimming failed: TopologyException" in d for _, _, d in got))
        # the polygons are unaffected by the pins, and the circles really are round
        self.assertTrue(read_kml("round.kml").contains(at(2, 3, east_m=7.3, north_m=1.5)))

    def test_junctions_and_ramps(self):
        corner = at(2, 3, east_m=7.3, north_m=1.5)        # just past a 14 m road, into Newark St
        code, out, _ = run_main(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                 "--no-outlines", "--output", "j.kml"])
        self.assertIn("Intersection fill trimmed to the roads", out)
        run_main(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                  "--no-outlines", "--no-junctions", "--output", "nj.kml"])
        # the circle's bulge into the cross street (not drawn) is trimmed off
        self.assertFalse(read_kml("j.kml").contains(corner))
        self.assertFalse(read_kml("nj.kml").contains(corner))
        self.assertTrue(read_kml("j.kml").contains(at(2, 3, east_m=6.5)))
        ramp_mid = Point((NODES[6100][1] + NODES[1025][1]) / 2, (NODES[6100][0] + NODES[1025][0]) / 2)
        code, out, _ = run_main(["--road", "I-95", "--state", "DC", "--source", "osm", "--ramps",
                                 "--no-outlines", "--output", "r.kml"])
        self.assertEqual(code, 0, out)
        self.assertTrue(read_kml("r.kml").contains(ramp_mid))
        run_main(["--road", "I-95", "--state", "DC", "--source", "osm", "--no-outlines",
                  "--output", "nr.kml"])
        self.assertFalse(read_kml("nr.kml").contains(ramp_mid))

    def test_old_name(self):
        code, out, path = run_main(["--road", "Lee Hwy", "--state", "DC", "--source", "osm",
                                    "--no-outlines"])
        self.assertEqual(code, 0, out)
        self.assertTrue(read_kml(path).contains(at(4, 2.5)))

    def test_clip_osm(self):
        code, out, path = run_main(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                    "--from", "Macomb St NW", "--to", "Ordway St NW", "--no-outlines"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "Connecticut_Ave_NW_Macomb_St_NW_to_Ordway_St_NW_DC_osm.kml")
        g = read_kml(path)
        self.assertTrue(g.contains(at(2, 3)))
        self.assertTrue(g.contains(at(1, 3, north_m=-10)), "pad past the cross street")
        self.assertFalse(g.contains(at(0.5, 3)))
        self.assertFalse(g.contains(at(4, 3)))

    def test_clip_points(self):
        a, b = ll(1, 3), ll(2, 3)
        code, out, path = run_main(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                    "--from", f"{a[0]},{a[1]}", "--to", f"{b[0]},{b[1]}",
                                    "--no-outlines", "--output", "p.kml"])
        self.assertEqual(code, 0, out)
        g = read_kml("p.kml")
        self.assertTrue(g.contains(at(1.5, 3)))
        self.assertFalse(g.contains(at(3, 3)))

    def test_bad_cross_street(self):
        code, out, _ = run_main(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                 "--from", "Nowhere St NW", "--to", "Ordway St NW"])
        self.assertEqual(code, 1)
        self.assertIn("Couldn't find 'Nowhere St NW' near the road", out)

    def test_source_errors(self):
        self.assertEqual(run_main(["--road", "x", "--state", "DC", "--source", "auto,osm"])[0], 2)
        self.assertEqual(run_main(["--road", "x", "--state", "DC", "--source", "bing"])[0], 2)
        code, out, _ = run_main(["--road", "Main St", "--state", "MD, VA", "--city", "Rockville"])
        self.assertIn("single --state", out)

    def test_error_reply_rotates_to_next_server(self):
        FAULTS["name_once"] = True
        code, out, path = run_main(["--road", "Cathedral Ave NW", "--state", "DC", "--source", "osm",
                                    "--no-outlines", "--no-junctions"])
        self.assertEqual(code, 0, out)
        self.assertIn("couldn't finish the query", out)
        self.assertIn("Attempt 2", out)
        self.assertIn("Found 2 OSM way(s)", out)

    def test_list_aliases_offline(self):
        code, out, _ = run_main(["--road", "Cathedral Ave NW", "--state", "DC", "--list-aliases"])
        self.assertIn("Cathedral Avenue Northwest", out)
        self.assertFalse(QUERIES)


@unittest.skipUnless(HAVE_GPD, "geopandas not installed")
class TigerTests(TempDirTest):
    def test_dc_without_county(self):
        code, out, path = run_main(["--road", "Cathedral Ave NW", "--state", "DC", "--source", "tiger"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "Cathedral_Ave_NW_DC_tiger.kml")
        self.assertIn(("ROADS", "11001", 2024), DOWNLOADS)
        self.assertIn(("ROADS", "11001", date.today().year), DOWNLOADS)

    def test_featnames_alias_and_multistate(self):
        code, out, path = run_main(["--road", "MD 355", "--state", "MD, DC", "--county",
                                    "Montgomery County", "--source", "osm,tiger", "--no-outlines"])
        self.assertEqual(code, 0, out)
        self.assertIn("Rockville Pike; 1 found via TIGER alternate names", out)
        self.assertEqual(path, "MD_355_Montgomery_County_MD_DC_osm_tiger.kml")

    def test_tiger_needs_county_outside_dc(self):
        code, out, _ = run_main(["--road", "Main St", "--state", "MD, DC", "--source", "tiger"])
        self.assertEqual(code, 1)
        self.assertIn("requires --county for: Maryland", out)

    def test_tiger_clip_and_junctions(self):
        code, out, path = run_main(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "tiger",
                                    "--from", "Macomb St NW", "--to", "Ordway St NW"])
        self.assertEqual(code, 0, out)
        g = read_kml(path)
        self.assertTrue(g.contains(at(2, 3)))
        self.assertFalse(g.contains(at(4, 3)))
        self.assertFalse(g.contains(at(2, 3, east_m=7.3, north_m=1.5)), "junction bulge trimmed")
        self.assertTrue(g.contains(at(2, 3, east_m=6.5)))

    def test_combined_sources_warning(self):
        code, out, path = run_main(["--road", "Cathedral Ave NW", "--state", "DC", "--source",
                                    "tiger,osm", "--no-outlines"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "Cathedral_Ave_NW_DC_osm_tiger.kml")


# ===========================================================================
# 4. GPS tracks
# ===========================================================================
def grid_network(category):
    ways = [w for w in WAYS if w["id"] != 300]
    return rt.RoadNetwork(ways, NODES, category, rt.utm_epsg([LON0]))


def walk_points(cells, step_m):
    pts = []
    for (r1, c1), (r2, c2) in zip(cells, cells[1:]):
        a, b = ll(r1, c1), ll(r2, c2)
        n = max(1, int(rt.haversine(*a, *b) / step_m))
        pts += [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(n)]
    return pts + [ll(*cells[-1])]


def make_trip(pts, category, noise=0.0, secs=2):
    import random
    random.seed(3)
    t0 = datetime(2026, 10, 30, 9, 0, tzinfo=timezone(timedelta(hours=-4)))
    out = [rt.TrackPoint(t0 + timedelta(seconds=secs * i),
                         la + random.gauss(0, noise) * M_LAT, lo + random.gauss(0, noise) * M_LON,
                         None, None, "x") for i, (la, lo) in enumerate(pts)]
    return rt.Trip(category, rt._downsample(out, category))


def names_of(res, min_len=5):
    return {t.get("name") for l, t in res.lines if l.length > min_len}


class MatchingTests(unittest.TestCase):
    def test_dense_noisy_drive(self):
        net = grid_network("drive")
        res = rt.match_trip(net, make_trip(walk_points([(0, 0), (0, 3), (4, 3), (4, 5)], 10), "drive", 6))
        self.assertEqual(names_of(res), {"Cathedral Avenue Northwest", "Connecticut Avenue Northwest",
                                         "Porter Street Northwest"})
        self.assertAlmostEqual(sum(l.length for l, _ in res.lines), 1800, delta=40)
        self.assertEqual(res.breaks, 0)
        self.assertNotIn(90, res.way_ids, "sidewalk used while driving")
        self.assertGreaterEqual(len(net.junction_nodes(res.nodes, res.way_ids)), 3)

    def test_sparse_points_route_around_corners(self):
        net = grid_network("drive")
        sparse = [ll(0, 0), (LAT0 + 1.2 * DLAT, LON0 + 1.6 * DLON),
                  (LAT0 + 3.5 * DLAT, LON0 + 2.6 * DLON), ll(5, 3)]
        res = rt.match_trip(net, rt.Trip("drive", [rt.TrackPoint(None, a, b, None, None, "x")
                                                   for a, b in sparse]))
        self.assertAlmostEqual(sum(l.length for l, _ in res.lines), 1600, delta=120)
        self.assertEqual(res.breaks, 0)

    def test_walk_uses_sidewalk_when_on_it(self):
        net = grid_network("walk")
        pts = [(NODES[5001][0] + i * DLAT / 4, NODES[5001][1]) for i in range(17)]
        res = rt.match_trip(net, make_trip(pts, "walk", 1.5, 20))
        self.assertIn(90, res.way_ids)


class CornerCutTests(unittest.TestCase):
    """US 1 -> MD 410 on Nov 5: with a point a minute, a smoothed Timeline
    point drifting toward a side street used to pull the match through
    Sheridan St and 44th Ave. Real side-street driving must still be kept."""
    LAT0, LON0 = 38.9660, -76.9375

    def ll(self, east, north):
        return (self.LAT0 + north / 111_000.0,
                self.LON0 + east / (111_000.0 * math.cos(math.radians(self.LAT0))))

    def net(self):
        nodes = {}

        def node(e, n):
            nodes[len(nodes) + 1] = self.ll(e, n)
            return len(nodes)
        x0, xs, x44n, x44s = node(0, 0), node(4, 70), node(-480, 70), node(-480, -110)
        us1_n, us1_s, mid, w410 = node(25, 600), node(-12, -400), node(-250, -55), node(-900, -200)
        b1, b2 = node(-240, 160), node(4, 160)           # a residential block north of Sheridan
        ways = [
            {"id": 1, "nodes": [us1_s, x0, xs, b2, us1_n], "tags": {"highway": "primary", "ref": "US 1"}},
            {"id": 2, "nodes": [x0, mid, x44s, w410], "tags": {"highway": "primary", "ref": "MD 410"}},
            {"id": 3, "nodes": [xs, x44n], "tags": {"highway": "residential", "name": "Sheridan St"}},
            {"id": 4, "nodes": [x44n, x44s], "tags": {"highway": "residential", "name": "44th Ave"}},
            {"id": 5, "nodes": [b2, b1], "tags": {"highway": "residential", "name": "Tuckerman St"}},
            {"id": 6, "nodes": [b1, node(-240, 70)], "tags": {"highway": "residential", "name": "42nd Ave"}},
        ]
        # 42nd Ave meets Sheridan St mid-block
        ways[2]["nodes"] = [xs, len(nodes), x44n]
        return rt.RoadNetwork(ways, nodes, "drive", "EPSG:32618")

    def match(self, gps, minutes=1.0):
        t0 = datetime(2026, 11, 5, 22, 6, tzinfo=timezone(timedelta(hours=-5)))
        pts = [rt.TrackPoint(t0 + timedelta(minutes=minutes * i), *self.ll(e, n), None, "in passenger vehicle", "timeline", 1)
               for i, (e, n) in enumerate(gps)]
        return rt.match_trip(self.net(), rt.Trip("drive", pts), log=lambda *a: None).way_ids

    def test_smoothed_point_doesnt_cut_the_corner(self):
        for north in (-122, -92, -62, -30, -10):         # 410 is at -122, Sheridan St at +70
            self.assertEqual(self.match([(22, 500), (-60, 5), (-560, north), (-900, -200)]), {1, 2}, north)

    def test_real_side_street_trip_is_kept(self):
        self.assertTrue({3, 4} <= self.match([(22, 500), (-250, 72), (-900, -200)]))
        self.assertTrue({3, 4} <= self.match([(22, 500), (-250, 72), (-478, -20), (-900, -200)]))

    def test_roundabout_route_is_kept(self):
        """Down US 1, a loop round a residential block, then on to 410."""
        got = self.match([(22, 500), (-120, 162), (-242, 120), (-120, 68), (-560, -122)], minutes=0.5)
        self.assertTrue({5, 6, 3} <= got, got)


class TimelineQuirkTests(unittest.TestCase):
    """Google Timeline sometimes labels a drive as a stop, and puts an
    activity's start or end point kilometres away."""
    T0 = datetime(2026, 11, 5, 16, 40, tzinfo=timezone(timedelta(hours=-5)))

    def pt(self, minute, lat, lon, mode=None, act=None):
        return rt.TrackPoint(self.T0 + timedelta(minutes=minute), lat, lon, None, mode, "timeline", act)

    def drive_up_16th(self, start, end, step=1):
        return [self.pt(m, 38.917 + 0.0042 * (m - start), -77.0364) for m in range(start, end + 1, step)]

    def test_drive_labelled_as_a_stop_is_kept(self):
        walk = [self.pt(m, 38.9185 - 0.0002 * m, -77.0343, "walking", 0) for m in range(0, 7)]
        moving = self.drive_up_16th(8, 36)                      # 16:48-17:16, ~13 km north
        after = [self.pt(37 + m, 39.0352 + 0.004 * m, -77.0364, "in passenger vehicle", 1) for m in range(10)]
        acts = [(self.T0, self.T0 + timedelta(minutes=7), "walking"),
                (self.T0 + timedelta(minutes=36, seconds=16), self.T0 + timedelta(minutes=47), "in passenger vehicle")]
        visits = [(self.T0 + timedelta(minutes=7, seconds=10), self.T0 + timedelta(minutes=29)),
                  (self.T0 + timedelta(minutes=29), self.T0 + timedelta(minutes=36, seconds=16))]
        log = []
        kept = rt._drop_visits(walk + moving + after, visits, activities=acts, log=log.append)
        self.assertEqual(len(kept), len(walk) + len(moving) + len(after))
        drove = [p for p in kept if self.T0 + timedelta(minutes=8) <= p.t <= self.T0 + timedelta(minutes=36)]
        self.assertTrue(drove and all(rt.mode_category(p.mode) == "drive" for p in drove), [p.mode for p in drove])
        self.assertEqual(len(log), 1)
        self.assertIn("as a stop, but the GPS moved", log[0])
        self.assertIn("treating it as driving", log[0])

    def test_real_stop_is_still_dropped(self):
        # arrive, stay an hour (GPS barely moves), leave: the edge points are
        # already 1.4 km apart, but nothing moved in between
        pts = [self.pt(0, 39.7944, -75.5470), self.pt(1, 39.7981, -75.5475),
               self.pt(5, 39.7966, -75.5475), self.pt(30, 39.7967, -75.5474),
               self.pt(65, 39.7856, -75.5462), self.pt(66, 39.7746, -75.5444)]
        visits = [(self.T0 + timedelta(seconds=50), self.T0 + timedelta(minutes=65, seconds=1))]
        log = []
        kept = rt._drop_visits(pts, visits, log=log.append)
        self.assertEqual(log, [])
        self.assertNotIn(pts[2], kept)
        self.assertNotIn(pts[3], kept)

    def test_stray_activity_point_is_ignored(self):
        pts = self.drive_up_16th(0, 10)
        stray = self.pt(5.25, 39.168, -76.884, "in passenger vehicle")   # 25 km away for 15 s
        pts = sorted(pts + [stray], key=lambda p: p.t)
        self.assertNotIn(stray, rt._drop_spikes(pts))
        self.assertEqual(len(rt._drop_spikes(pts)), 11)
        # a real long jump after a long gap stays
        far = self.pt(120, 39.5, -77.0)
        self.assertIn(far, rt._drop_spikes(self.drive_up_16th(0, 3) + [far]))

    def test_timeline_file_end_to_end(self):
        """iPhone export: walk, then a drive Google labelled as two stops,
        then the drive Google did label, with a stray start point."""
        day = "2026-11-05T"
        segs = [
            {"startTime": day + "16:40:00.000-05:00", "endTime": day + "16:47:10.000-05:00",
             "activity": {"start": "geo:38.918500,-77.034300", "end": "geo:38.917100,-77.033100",
                          "topCandidate": {"type": "walking"}, "distanceMeters": "297"}},
            {"startTime": day + "16:47:10.000-05:00", "endTime": day + "17:09:02.000-05:00",
             "visit": {"topCandidate": {"semanticType": "Unknown", "placeLocation": "geo:38.995119,-77.036975"}}},
            {"startTime": day + "17:09:02.000-05:00", "endTime": day + "17:16:16.000-05:00",
             "visit": {"topCandidate": {"semanticType": "Unknown", "placeLocation": "geo:39.009518,-77.040222"}}},
            {"startTime": day + "17:16:16.000-05:00", "endTime": day + "17:30:00.000-05:00",
             "activity": {"start": "geo:39.167955,-76.884383", "end": "geo:39.0700,-77.0364",
                          "topCandidate": {"type": "in passenger vehicle"}, "distanceMeters": "7768"}},
        ]
        path = [{"point": f"geo:{38.917 + 0.0034 * m:.6f},-77.036400", "durationMinutesOffsetFromStartTime": str(47 + m)}
                for m in range(0, 44)]
        segs.append({"startTime": "2026-11-05T21:00:00.000Z", "endTime": "2026-11-05T23:00:00.000Z",
                     "timelinePath": path})
        tmp = tempfile.mkdtemp()
        f = os.path.join(tmp, "location-history.json")
        with open(f, "w", encoding="utf-8") as fh:
            json.dump(segs, fh)
        trips = rt.load_trips([f], "2026-11-05", list(rt.CATEGORIES), log=lambda *a: None)
        drives = [t for t in trips if t.category == "drive"]
        self.assertEqual(len(drives), 1, [(t.category, len(t.points)) for t in trips])
        d = drives[0].points
        self.assertLess(d[0].lat, 38.925)                 # starts down by 15th St / Columbia Rd
        self.assertGreater(d[-1].lat, 39.05)              # runs on past where Google's drive "began"
        self.assertTrue(all(p.lon < -77.0 for p in d), "stray Columbia, MD point dropped")


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def write(self, name, body):
        p = os.path.join(self.d, name)
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(body if isinstance(body, str) else json.dumps(body))
        return p

    def test_phone_export(self):
        p = self.write("Timeline.json", {"semanticSegments": [
            {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:20:00.000-04:00",
             "activity": {"start": {"latLng": "38.9300000°, -77.0700000°"},
                          "end": {"latLng": "38.9350000°, -77.0650000°"},
                          "topCandidate": {"type": "IN_PASSENGER_VEHICLE"}}},
            {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "timelinePath": [{"point": "38.9310000°, -77.0690000°", "time": "2026-10-30T09:05:00.000-04:00"},
                              {"point": "38.9330000°, -77.0670000°", "time": "2026-10-30T09:10:00.000-04:00"},
                              {"point": "38.9350000°, -77.0650000°", "time": "2026-10-30T10:30:00.000-04:00"}]},
            {"startTime": "2026-10-30T09:20:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "visit": {"topCandidate": {"placeLocation": {"latLng": "38.935°, -77.065°"}}}},
            {"startTime": "2026-10-31T12:00:00.000-04:00", "endTime": "2026-10-31T13:00:00.000-04:00",
             "activity": {"start": {"latLng": "38.8°, -77.0°"}, "end": {"latLng": "39.8°, -78.0°"},
                          "topCandidate": {"type": "FLYING"}}}],
            "rawSignals": [{"position": {"LatLng": "38.9320000°, -77.0680000°", "accuracyMeters": 10,
                                         "timestamp": "2026-10-30T09:07:00.000-04:00"}},
                           {"position": {"LatLng": "38.9330000°, -77.0670000°", "accuracyMeters": 900,
                                         "timestamp": "2026-10-30T09:08:00.000-04:00"}}]})
        pts, acts, visits, kind = rt.read_track_file(p)
        self.assertIn("phone", kind)
        self.assertEqual(len(pts), 8)
        trips = rt.load_trips([p], "2026-10-30", log=lambda *a: None)
        self.assertEqual([t.category for t in trips], ["drive"])
        self.assertFalse(any(pt.t and pt.t.hour == 10 for pt in trips[0].points), "visit points dropped")

    def test_iphone_records_semantic(self):
        p = self.write("location-history.json", [
            {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:30:00.000-04:00",
             "activity": {"start": "geo:38.930000,-77.070000", "end": "geo:38.935000,-77.065000",
                          "topCandidate": {"type": "walking"}}},
            {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "timelinePath": [{"point": "geo:38.931000,-77.069000", "durationMinutesOffsetFromStartTime": "5"},
                              {"point": "geo:38.933000,-77.067000", "durationMinutesOffsetFromStartTime": "15"}]}])
        trips = rt.load_trips([p], "2026-10-30", log=lambda *a: None)
        self.assertEqual([t.category for t in trips], ["walk"])
        p = self.write("Records.json", {"locations": [
            {"latitudeE7": 389300000, "longitudeE7": -770700000, "timestamp": "2026-10-30T13:00:00Z",
             "accuracy": 10, "activity": [{"activity": [{"type": "IN_VEHICLE", "confidence": 80}]}]},
            {"latitudeE7": 389350000, "longitudeE7": -770650000, "timestampMs": "1761829500000", "accuracy": 10}]})
        pts, _, _, kind = rt.read_track_file(p)
        self.assertEqual((kind, len(pts), pts[0].mode), ("Google Takeout Records.json", 2, "IN_VEHICLE"))
        p = self.write("2026_OCTOBER.json", {"timelineObjects": [{"activitySegment": {
            "startLocation": {"latitudeE7": 389300000, "longitudeE7": -770700000},
            "endLocation": {"latitudeE7": 389350000, "longitudeE7": -770650000},
            "duration": {"startTimestamp": "2026-10-30T13:00:00Z", "endTimestamp": "2026-10-30T13:20:00Z"},
            "activityType": "CYCLING", "waypointPath": {"waypoints": [{"latE7": 389320000, "lngE7": -770680000}]}}}]})
        pts, acts, _, kind = rt.read_track_file(p)
        self.assertEqual((len(pts), acts[0][2]), (3, "CYCLING"))

    def test_gpx_kml_geojson(self):
        gpx = ('<?xml version="1.0"?><gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">'
               '<trk><trkseg><trkpt lat="38.93" lon="-77.07"><time>2026-10-30T13:00:00Z</time></trkpt>'
               '<trkpt lat="38.935" lon="-77.065"><time>2026-10-30T13:05:00Z</time></trkpt>'
               '</trkseg></trk></gpx>')
        kml = ('<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">'
               '<Placemark><gx:Track><when>2026-10-30T13:00:00Z</when><when>2026-10-30T13:05:00Z</when>'
               '<gx:coord>-77.07 38.93 0</gx:coord><gx:coord>-77.065 38.935 0</gx:coord></gx:Track>'
               '</Placemark></kml>')
        geo = {"type": "FeatureCollection", "features": [{"type": "Feature", "properties": {},
               "geometry": {"type": "LineString", "coordinates": [[-77.07, 38.93], [-77.065, 38.935]]}}]}
        for name, body, kind in (("t.gpx", gpx, "GPX"), ("t.kml", kml, "KML"), ("t.geojson", geo, "GeoJSON")):
            pts, _, _, k = rt.read_track_file(self.write(name, body))
            self.assertEqual((k, len(pts)), (kind, 2))

    def test_long_gap_inside_one_drive_stays_one_trip(self):
        path = [{"point": f"{38.93 + i * 0.01:.4f}°, -77.07°",
                 "time": f"2026-10-30T09:{m:02d}:00.000-04:00"} for i, m in enumerate((0, 5, 25, 30))]
        act = {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:40:00.000-04:00",
               "activity": {"topCandidate": {"type": "IN_PASSENGER_VEHICLE"}}}
        seg = {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
               "timelinePath": path}
        one = rt.load_trips([self.write("a.json", {"semanticSegments": [act, seg]})], "2026-10-30",
                            log=lambda *a: None)
        two = rt.load_trips([self.write("b.json", {"semanticSegments": [seg]})], "2026-10-30",
                            log=lambda *a: None)
        self.assertEqual((len(one), len(two)), (1, 2))

    def test_download_boxes_cover_the_track(self):
        t0 = datetime(2026, 10, 30, 9, tzinfo=timezone.utc)
        pts = [rt.TrackPoint(t0 + timedelta(seconds=10 * i), 38.9 + i * 0.0005, -77.0, None, None, "x")
               for i in range(20)]
        pts += [rt.TrackPoint(t0 + timedelta(seconds=400 + 10 * i), 38.94 + i * 0.0005, -77.0,
                              None, None, "x") for i in range(20)]
        trip = rt.Trip("drive", pts)
        boxes = rt.cells_to_boxes(rt.trip_cells(trip))
        for p in pts:                                        # every point is inside a box
            self.assertTrue(any(s <= p.lat <= n and w <= p.lon <= e for s, w, n, e in boxes))
        # corridor is wider across the 3 km gap than along the dense stretches
        width = lambda lat: sum(e - w for s, w, n, e in boxes if s <= lat < n)
        self.assertGreater(width(38.925), width(38.897))
        for batch in rt.batch_boxes(boxes, max_km2=5):
            self.assertLessEqual(sum(rt.box_area_km2(b) for b in batch), 5 + max(rt.box_area_km2(b) for b in batch))

    def test_iphone_utc_path_points_get_local_time(self):
        """The iPhone export stamps path points in UTC but activities locally."""
        p = self.write("location-history.json", [
            {"startTime": "2026-10-30T23:10:00.000-04:00", "endTime": "2026-10-30T23:50:00.000-04:00",
             "activity": {"start": "geo:38.930000,-77.070000", "end": "geo:38.935000,-77.065000",
                          "topCandidate": {"type": "in passenger vehicle"}}},
            {"startTime": "2026-10-31T02:00:00.000Z", "endTime": "2026-10-31T04:00:00.000Z",
             "timelinePath": [{"point": "geo:38.931000,-77.069000", "durationMinutesOffsetFromStartTime": "75"},
                              {"point": "geo:38.933000,-77.067000", "durationMinutesOffsetFromStartTime": "80"}]}])
        trips = rt.load_trips([p], "2026-10-30", log=lambda *a: None)   # 03:15Z = 23:15 on the 30th
        self.assertEqual(len(trips), 1)
        times = [rt.local_time(q.t).strftime("%d %H:%M") for q in trips[0].points]
        self.assertEqual(times, sorted(times))
        self.assertTrue(all(t.startswith("30 23:") for t in times), times)

    def test_dates(self):
        self.assertEqual(rt.parse_date_spec("2026-02"), (date(2026, 2, 1), date(2026, 2, 28)))
        self.assertEqual(rt.parse_date_spec("2026-10-01..2026-10-31")[1], date(2026, 10, 31))
        self.assertIsNone(rt.parse_date_spec("all"))
        with self.assertRaises(ValueError):
            rt.parse_date_spec("Oct 5")
        segs = [{"startTime": f"2026-{m:02d}-{d:02d}T09:00:00.000-04:00",
                 "endTime": f"2026-{m:02d}-{d:02d}T10:00:00.000-04:00",
                 "timelinePath": [{"point": "38.93°, -77.07°", "time": f"2026-{m:02d}-{d:02d}T09:00:00.000-04:00"}]}
                for m in (1, 2, 3) for d in range(1, 20)]
        p = self.write("big.json", {"semanticSegments": segs})
        with self.assertRaises(ValueError):
            rt.load_trips([p], None, log=lambda *a: None)


class TrackEndToEndTests(TempDirTest):
    def timeline(self):
        """A drive along Cathedral then up Connecticut, Timeline-style (sparse)."""
        route = walk_points([(0, 0), (0, 3), (4, 3)], 250)
        t0 = datetime(2026, 10, 30, 9, 0)
        path = [{"point": f"{a:.7f}°, {b:.7f}°", "time": (t0 + timedelta(seconds=30 * i)).isoformat() + ".000-04:00"}
                for i, (a, b) in enumerate(route)]
        data = {"semanticSegments": [
            {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:30:00.000-04:00",
             "activity": {"start": {"latLng": path[0]["point"]}, "end": {"latLng": path[-1]["point"]},
                          "topCandidate": {"type": "IN_PASSENGER_VEHICLE"}}},
            {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "timelinePath": path}]}
        with open("Timeline.json", "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return "Timeline.json"

    def test_track_run(self):
        code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "track_2026-10-30_osm.kml")
        g = read_kml(path)
        for p in (at(0, 1.5), at(0, 2.5), at(2, 3), at(3.5, 3)):
            self.assertTrue(g.contains(p), p)
        self.assertFalse(g.contains(at(5, 2)), "Quebec St wasn't driven")
        self.assertFalse(g.contains(at(2, 3.8)), "Newark St east of Connecticut wasn't driven")
        self.assertTrue(g.contains(at(1.5, 3, east_m=9)), "pavement outline used")
        self.assertTrue(g.contains(at(0, 3, east_m=-7.3, north_m=1.5)), "turn corner filled")
        self.assertTrue(g.contains(at(0, 3, east_m=2, north_m=-1)), "notch at the turn filled")
        self.assertFalse(g.contains(at(0, 3, east_m=5, north_m=-5)), "bulge outside the turn trimmed")

    def test_track_survives_overpass_errors(self):
        """An error inside a 200 reply is reported and the request is split."""
        FAULTS["big_track_requests"] = True
        try:
            code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30", "--no-outlines"])
        finally:
            FAULTS["big_track_requests"] = False
        self.assertEqual(code, 0, out)
        self.assertIn("couldn't finish the query: runtime error", out)
        self.assertIn("Splitting this request", out)
        self.assertTrue(read_kml(path).contains(at(2, 3)))

    def test_track_all_downloads_fail(self):
        FAULTS["all_track_requests"] = True
        try:
            code, out, _ = run_main(["--track", self.timeline(), "--date", "2026-10-30", "--source", "osm"])
        finally:
            FAULTS["all_track_requests"] = False
        self.assertEqual(code, 1)
        self.assertIn("no OSM road data for these trips", out)
        self.assertIn("re-run with --wait", out)
        self.assertNotIn("0.0 km", out)

    def network_queries(self):
        return [q for q in QUERIES if "out skel qt" in q]

    def test_track_default_uses_osm_only_when_it_matches(self):
        code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "track_2026-10-30_osm.kml")
        self.assertFalse(DOWNLOADS, "no TIGER/Line downloads needed")

    @unittest.skipUnless(HAVE_GPD, "geopandas not installed")
    def test_track_tiger_only(self):
        code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30", "--source", "tiger"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "track_2026-10-30_tiger.kml")
        self.assertIn("Counties: District of Columbia", out)
        self.assertIn(("ROADS", "11001", 2024), DOWNLOADS)
        self.assertFalse(self.network_queries(), "OSM shouldn't be asked")
        g = read_kml(path)
        for p in (at(0, 1.5), at(2, 3), at(3.5, 3)):
            self.assertTrue(g.contains(p), p)
        self.assertFalse(g.contains(at(5, 2)))

    @unittest.skipUnless(HAVE_GPD, "geopandas not installed")
    def test_track_osm_and_tiger_combined(self):
        code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30", "--source", "osm,tiger"])
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "track_2026-10-30_osm_tiger.kml")
        self.assertIn("km OSM + ", out)

    @unittest.skipUnless(HAVE_GPD, "geopandas not installed")
    def test_track_default_falls_back_when_osm_is_down(self):
        FAULTS["all_track_requests"] = True
        try:
            code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30"])
        finally:
            FAULTS["all_track_requests"] = False
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "track_2026-10-30_tiger.kml")
        self.assertIn("Using TIGER/Line to fill what OSM couldn't match", out)
        self.assertTrue(read_kml(path).contains(at(2, 3)))

    @unittest.skipUnless(HAVE_GPD, "geopandas not installed")
    def test_track_default_fills_a_road_missing_from_osm(self):
        conn = [w["id"] for w in WAYS if w["tags"].get("name") == "Connecticut Avenue Northwest"]
        FAULTS["hide_ways"] = set(conn)
        try:
            code, out, path = run_main(["--track", self.timeline(), "--date", "2026-10-30", "--no-outlines"])
        finally:
            FAULTS["hide_ways"] = set()
        self.assertEqual(code, 0, out)
        self.assertEqual(path, "track_2026-10-30_tiger.kml")
        self.assertIn("OSM went the long way round", out)
        g = read_kml(path)
        self.assertTrue(g.contains(at(2.5, 3)), "Connecticut from TIGER/Line")
        self.assertTrue(g.contains(at(0, 1.5)), "Cathedral")
        for c in (2, 4):
            self.assertFalse(g.contains(at(2.5, c)), f"OSM's detour on column {c} left out")

    def test_track_downloads_each_area_once(self):
        """Two trips over the same streets, in separate groups: one OSM download."""
        self.timeline()
        data = json.load(open("Timeline.json", encoding="utf-8"))
        later = json.loads(json.dumps(data).replace("2026-10-30T09", "2026-10-30T15")
                           .replace("2026-10-30T10", "2026-10-30T16").replace("2026-10-30T11", "2026-10-30T17"))
        data["semanticSegments"] += later["semanticSegments"]
        with open("Twice.json", "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        real = rt.group_trips
        rt.group_trips = lambda trips, **kw: [[t] for t in trips]     # force one group per trip
        try:
            code, out, path = run_main(["--track", "Twice.json", "--date", "2026-10-30", "--no-outlines"])
        finally:
            rt.group_trips = real
        self.assertEqual(code, 0, out)
        self.assertIn("Trip group 2 of 2", out)
        self.assertIn("Downloading OSM roads for all trips at once: 1 request(s)", out)
        self.assertEqual(len(self.network_queries()), 1, out)
        self.assertEqual(out.count("km OSM"), 2, out)
        self.assertTrue(read_kml(path).contains(at(2, 3)))

    def test_request_cap(self):
        self.assertEqual(rt.MAX_REQUEST_KM2, 80.0)
        boxes = [(38.9, -77.1 + i * 0.05, 38.95, -77.05 + i * 0.05) for i in range(6)]   # ~24 km² each
        self.assertEqual([len(b) for b in rt.batch_boxes(boxes)], [3, 3])

    def test_track_option_errors(self):
        self.timeline()
        self.assertEqual(run_main(["--track", "Timeline.json", "--road", "x"])[0], 2)
        self.assertEqual(run_main(["--track", "Timeline.json", "--source", "xml", "a.osm"])[0], 2)
        self.assertEqual(run_main(["--track", "Timeline.json", "--travel-modes", "boat"])[0], 2)
        code, out, _ = run_main(["--track", "Timeline.json", "--date", "2026-10-29"])
        self.assertEqual(code, 1)
        self.assertIn("No trips", out)


class MirrorStatsTests(TempDirTest):
    def setUp(self):
        super().setUp()
        self.path = os.path.join(self.tmp, "stats.txt")
        os.environ["ROAD_TO_KML_MIRROR_STATS"] = self.path

    def tearDown(self):
        os.environ["ROAD_TO_KML_MIRROR_STATS"] = os.path.join(STATS_DIR, "overpass_mirror_stats.txt")
        install_fakes()
        super().tearDown()

    def test_every_attempt_is_counted_and_kept(self):
        import requests
        m = rk.OVERPASS_MIRRORS
        plan = []

        class Resp:
            status_code, reason, text = 504, "Gateway Timeout", ""

        def fake(url, query, timeout=130):
            what = plan.pop(0)
            if what == "504":
                raise requests.HTTPError("HTTP 504", response=Resp())
            if what == "refused":
                raise requests.ConnectionError("Connection refused")
            if what == "busy":
                return {"elements": [], "remark": "runtime error: rate_limited"}
            return {"elements": []}
        rk._overpass_post = fake
        quiet = contextlib.redirect_stdout(io.StringIO())
        plan[:] = ["504", "refused", "busy", "ok"]
        with quiet:
            self.assertEqual(rk.overpass_json("[out:json];"), {"elements": []})
        plan[:] = ["ok"]
        with contextlib.redirect_stdout(io.StringIO()):
            rk.overpass_json("[out:json];")
        text = open(self.path, encoding="utf-8").read()
        data = ms.load(self.path)["mirrors"]
        self.assertEqual(data[m[0]]["outcomes"], {"HTTP 504 Gateway Timeout": 1, "Succeeded": 1})
        self.assertEqual(data[m[1]]["outcomes"], {ms.CONNECTION: 1})
        self.assertEqual(data[m[2]]["outcomes"], {ms.BUSY: 1})
        self.assertEqual(data[m[3]]["outcomes"], {"Succeeded": 1})
        self.assertRegex(text, re.escape(m[0]) + r"\s+2\s+1\s+50\.0%")
        self.assertRegex(text, re.escape(m[4]) + r"\s+0\s+0\s+-\s+never tried")
        self.assertIn("HTTP 504 Gateway Timeout", text)

    def test_damaged_file_is_set_aside(self):
        with open(self.path, "w", encoding="utf-8") as fh:
            fh.write("someone edited this\n")
        with contextlib.redirect_stdout(io.StringIO()) as out:
            ms.record("https://example.org/api/interpreter", ms.SUCCEEDED, 1.0)
        self.assertIn("couldn't read the mirror tally", out.getvalue())
        self.assertTrue([f for f in os.listdir(self.tmp) if ".unreadable-" in f])
        self.assertEqual(ms.load(self.path)["mirrors"]["https://example.org/api/interpreter"]["outcomes"],
                         {"Succeeded": 1})

    def test_file_problems_never_stop_a_run(self):
        os.environ["ROAD_TO_KML_MIRROR_STATS"] = os.path.join(self.tmp, "no", "such", "dir", "s.txt")
        ms._warned = False
        with contextlib.redirect_stdout(io.StringIO()) as out:
            ms.record("u", ms.SUCCEEDED, 1.0)
            ms.record("u", ms.SUCCEEDED, 1.0)
        self.assertEqual(out.getvalue().count("couldn't update the mirror tally"), 1)


class BatchTests(TempDirTest):
    def test_batch(self):
        with open("trips.csv", "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["Road", "State", "From", "To", "Output", "Junctions", "Notes", "Visited"])
            w.writerow(["Connecticut Ave NW", "DC", "Macomb St NW", "Ordway St NW", "a.kml", "no", "lunch run", "2026-10-30"])
            w.writerow(["# commented out", "", "", "", "", "", "", ""])
            w.writerow(["Cathedral Ave NW", "Atlantis", "", "", "b.kml", "", "", ""])
            w.writerow(["Cathedral Ave NW", "DC", "", "", "c.kml", "", "", ""])
        code, out, _ = run_main(["--batch", "trips.csv", "--source", "osm", "--no-outlines"])
        self.assertEqual(code, 1, out)                       # one row failed
        self.assertIn("ignoring column(s) visited", out)
        self.assertIn("2 succeeded, 1 failed", out)
        self.assertIn("State not recognised: 'Atlantis'", out)
        self.assertTrue(os.path.exists("a.kml") and os.path.exists("c.kml"))
        with open("a.kml", encoding="utf-8") as fh:
            self.assertIn("lunch run", fh.read())


# ===========================================================================
# 5. Browser interface server (road_to_kml_ui.py)
# ===========================================================================
import threading                    # noqa: E402
import urllib.error                 # noqa: E402
import urllib.request               # noqa: E402

FAKE_RUNNER = """import sys
sys.path.insert(0, {here!r})
import test_road_to_kml as T
import road_to_kml as rk
T.install_fakes()
rk.main(sys.argv[1:])
"""


class UIServerTests(unittest.TestCase):
    """road_to_kml_ui.py's HTTP API, with road_to_kml.py swapped for a runner
    that uses the same offline fakes as the tests above."""

    @classmethod
    def setUpClass(cls):
        import road_to_kml_ui as ui
        cls.ui = ui
        cls.tmp = tempfile.mkdtemp()
        runner = os.path.join(cls.tmp, "fake_runner.py")
        with open(runner, "w", encoding="utf-8") as fh:
            fh.write(FAKE_RUNNER.format(here=HERE))
        ui.SCRIPT = runner
        cls.out = os.path.join(cls.tmp, "out")
        cls.server = ui.make_server(0, cls.out)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.ui._cleanup()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def call(self, path, body=None, headers=None, raw=None):
        url = f"http://127.0.0.1:{self.port}{path}"
        h = {"X-Road-KML": "1"} if (body is not None or raw is not None) else {}
        h.update(headers or {})
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        if body is not None:
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=h, method="POST" if data is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def j(self, path, body=None, **kw):
        code, data = self.call(path, body, **kw)
        return code, json.loads(data.decode() or "{}")

    def wait(self, job_id, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            _, d = self.j(f"/api/job?id={job_id}&since=0")
            if d["status"] != "running":
                return d
            time.sleep(0.2)
        self.fail("run didn't finish")

    def test_page_and_info(self):
        code, html = self.call("/")
        self.assertEqual(code, 200)
        self.assertIn(b"Road to KML", html)
        code, info = self.j("/api/info")
        self.assertEqual(code, 200)
        self.assertEqual(info["out_dir"], os.path.abspath(self.out))
        self.assertIn(["DC", "District of Columbia"], info["states"])

    def test_guards(self):
        code, _ = self.call("/api/run", raw=b"{}", headers={"X-Road-KML": "0"})
        self.assertEqual(code, 403)
        code, _ = self.call("/api/info", headers={"Host": "evil.example"})
        self.assertEqual(code, 403)
        code, _ = self.call("/api/file?name=../secret.kml")
        self.assertEqual(code, 404)

    def test_aliases_and_validation(self):
        code, d = self.j("/api/aliases", {"road": "Lee Hwy", "state": "VA", "county": "Arlington County"})
        self.assertEqual(code, 200)
        self.assertEqual(d["results"][0]["county_fips"], "51013")
        self.assertTrue(any("Langston Boulevard" in e["alts"] for e in d["results"][0]["elements"]))
        _, d = self.j("/api/validate", {"argv": ["--road", "x", "--source", "bing"]})
        self.assertIn("invalid mode", d["error"])
        code, d = self.j("/api/run", {"argv": ["--road", "x", "--source", "bing"]})
        self.assertEqual(code, 400)

    def test_run_upload_batch_and_files(self):
        code, job = self.j("/api/run", {"argv": ["--road", "Cathedral Ave NW", "--state", "DC",
                                                 "--source", "osm", "--no-outlines"], "label": "t"})
        self.assertEqual(code, 200, job)
        done = self.wait(job["id"])
        self.assertEqual(done["status"], "done", "\n".join(done["lines"]))
        self.assertEqual([o["name"] for o in done["outputs"]], ["Cathedral_Ave_NW_DC_osm.kml"])
        code, kml = self.call("/api/file?name=Cathedral_Ave_NW_DC_osm.kml")
        self.assertEqual(code, 200)
        self.assertIn(b"<Polygon", kml)
        _, files = self.j("/api/files")
        self.assertIn("Cathedral_Ave_NW_DC_osm.kml", [f["name"] for f in files["files"]])

        gpx = (b'<?xml version="1.0"?><gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>'
               + b"".join(b'<trkpt lat="%f" lon="%f"><time>2026-10-30T13:%02d:00Z</time></trkpt>'
                          % (lat, lon, i) for i, (lat, lon) in enumerate(walk_points([(0, 0), (0, 3)], 100)))
               + b"</trkseg></trk></gpx>")
        code, up = self.j("/api/upload?name=drive.gpx", raw=gpx,
                          headers={"Content-Type": "application/octet-stream"})
        self.assertEqual(code, 200, up)
        self.assertTrue(os.path.exists(up["path"]))
        csv_text = ("road,state,track,date,output\n"
                    f"Cathedral Ave NW,DC,,,a.kml\n,,{up['path']},2026-10-30,b.kml\n")
        code, job = self.j("/api/batch", {"csv": csv_text, "argv": ["--no-outlines"]})
        self.assertEqual(code, 200, job)
        done = self.wait(job["id"])
        self.assertEqual(done["status"], "done", "\n".join(done["lines"]))
        self.assertEqual(sorted(o["name"] for o in done["outputs"]), ["a.kml", "b.kml"])

    def test_settings(self):
        other = os.path.join(self.tmp, "elsewhere")
        code, info = self.j("/api/settings", {"out_dir": other, "overpass_url": ""})
        self.assertEqual((code, info["out_dir"]), (200, os.path.abspath(other)))
        code, d = self.j("/api/settings", {"overpass_url": "ftp://nope"})
        self.assertEqual(code, 400)
        self.j("/api/settings", {"out_dir": self.out})


if __name__ == "__main__":
    unittest.main(verbosity=2)
