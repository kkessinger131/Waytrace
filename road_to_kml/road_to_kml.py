#!/usr/bin/env python3
"""
road_to_kml.py
--------------
Generate a KML polygon covering the road surface of any named US road.

Usage:
    python road_to_kml.py --road "Main Street" --city "Austin" --state "Texas"
    python road_to_kml.py --road "US-1" --state "Florida" --output my_road.kml
    python road_to_kml.py --road "Interstate 10" --state "Texas" --county "Harris County, Dallas County" --lanes 6
    python road_to_kml.py --road "Cathedral Ave NW" --state DC --source tiger
    python road_to_kml.py --road "I-95" --state "MD, DE, PA" --source osm,tiger
    python road_to_kml.py --road "MD 355" --state "MD, DC" --county "Montgomery County (MD)" --source osm,tiger
    python road_to_kml.py --road "Mass Ave NW" --state DC --list-aliases
    python road_to_kml.py --road "Connecticut Ave NW" --state DC --from "Calvert St NW" --to "Nebraska Ave NW"
    python road_to_kml.py --track Timeline.json --date 2026-10-30
    python road_to_kml.py --batch trips.csv

Road names are matched with aliases (road_aliases.py): "Cathedral Ave NW" also
finds "Cathedral Avenue Northwest", "MD 355" also finds "Maryland Route 355", etc.
--track map-matches Google Maps Timeline exports and GPX/KML tracks onto OSM
roads (road_tracks.py).

Requirements:
    pip install overpy shapely pyproj simplekml requests
    pip install geopandas            (only needed for TIGER/Line)

Keep road_aliases.py, road_tracks.py and county_fips.py in the same folder as
this script. test_road_to_kml.py checks everything offline.
"""

import argparse
import csv
import heapq
import importlib.util
import math
import sys
import time
from collections import defaultdict, namedtuple
from datetime import date

import overpy
import simplekml
import requests
import urllib3
import re
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
from pyproj import Transformer
from shapely.geometry import LineString, MultiLineString, Point, Polygon, MultiPolygon
from shapely.ops import unary_union, linemerge, nearest_points, polygonize, substring
import numpy as np
import shapely
from shapely.strtree import STRtree

import mirror_stats
import road_aliases
import road_tracks

# ---------------------------------------------------------------------------
# Default road widths (meters, edge-to-edge) keyed on OSM highway= tag.
# These are conservative estimates for typical US roads.
# Override per-segment using the actual OSM width= or lanes= tag when present.
# ---------------------------------------------------------------------------
DEFAULT_WIDTHS = {
    "motorway":       24.0,   # ~4 lanes + shoulders
    "motorway_link":  10.0,
    "trunk":          18.0,
    "trunk_link":      9.0,
    "primary":        14.0,
    "primary_link":    7.0,
    "secondary":      11.0,
    "secondary_link":  6.0,
    "tertiary":        9.0,
    "tertiary_link":   5.5,
    "unclassified":    7.0,
    "residential":     7.5,
    "living_street":   5.0,
    "service":         4.5,
    "pedestrian":      4.0,
    "footway":         2.0,
    "path":            2.0,
    "cycleway":        2.5,
    "steps":           2.0,
    "bridleway":       2.5,
    "corridor":        2.0,
    "track":           4.0,
    "busway":          7.0,
    "road":            7.0,   # unknown type fallback
}

LANE_WIDTH = 3.7   # meters per lane (US standard)
DEFAULT_WIDTH_FALLBACK = 7.0  # if highway tag not in table

def get_state_area_id(state: str) -> int:
    """
    Find the OSM relation for a US state (or DC) and return its Overpass area ID.

    Asks Nominatim for state-level results first, so "New York" gives the state
    rather than New York City and "Washington" gives the state rather than DC,
    then falls back to a plain search.
    """
    q = f"{state}, USA"

    for attempt, extra in enumerate(({"featureType": "state"}, {})):
        if attempt:
            time.sleep(1)  # Nominatim usage policy: at most 1 request per second
        r = requests.get(
            "https://nominatim.openstreetmap.org/search",
            params={
                "q": q,
                "format": "jsonv2",
                "limit": 20,
                **extra,
            },
            headers={"User-Agent": "road_to_kml/1.0"},
            timeout=30,
            verify=False,
        )

        r.raise_for_status()
        results = r.json()
        relations = [item for item in results if item.get("osm_type") == "relation"]

        for item in relations:
            if item.get("addresstype") == "state":
                return int(item["osm_id"]) + 3600000000
        for item in relations:
            if "state" in item.get("display_name", "").lower():
                return int(item["osm_id"]) + 3600000000

    raise RuntimeError(f"State not found: {state}")


def get_city_area_id(city: str, state: str) -> int:
    """
    Use Nominatim to find the exact OSM relation for a city and
    convert it to an Overpass area ID.

    Returns the Overpass area ID.
    """

    q = f"{city}, {state}, USA"

    r = requests.get(
        "https://nominatim.openstreetmap.org/search",
        params={
            "q": q,
            "format": "jsonv2",
            "limit": 20,
        },
        headers={
            "User-Agent": "road_to_kml/1.0"
        },
        timeout=30,
        verify=False,  # Python 3.14 Windows SSL workaround
    )

    r.raise_for_status()
    results = r.json()

    if not results:
        raise RuntimeError(f"City not found: {q}")

    # Prefer administrative relations
    for item in results:
        if item.get("osm_type") == "relation":
            rel_id = int(item["osm_id"])

            # Overpass area id = relation id + 3600000000
            return rel_id + 3600000000

    raise RuntimeError(
        f"No administrative relation found for {q}"
    )

def get_county_area_id(county: str, state: str) -> int:
    q = f"{county}, {state}, USA"

    r = requests.get(
        "https://nominatim.openstreetmap.org/search",
        params={
            "q": q,
            "format": "jsonv2",
            "limit": 20,
        },
        headers={"User-Agent": "road_to_kml/1.0"},
        timeout=30,
        verify=False,
    )

    r.raise_for_status()
    results = r.json()

    for item in results:
        if item.get("osm_type") == "relation":
            return int(item["osm_id"]) + 3600000000

    raise RuntimeError(f"County not found: {county}, {state}")

def get_road_width(tags: dict) -> float:
    """
    Determine road half-width in meters from OSM tags (or TIGER synthetic tags).
    Priority: explicit width= > tiger_width= > lanes= > highway= default table.
    Returns total width (buffer = width / 2 each side).
    """
    # Explicit OSM width tag (e.g. width=12 or width=12m)
    if "width" in tags:
        w = tags["width"].replace("m", "").strip()
        try:
            return float(w)
        except ValueError:
            pass

    # TIGER/Line synthetic width (set from MTFCC class lookup)
    if "tiger_width" in tags:
        return float(tags["tiger_width"])

    # Lanes tag
    if "lanes" in tags:
        try:
            return int(tags["lanes"]) * LANE_WIDTH
        except ValueError:
            pass

    # Highway class lookup
    hw = tags.get("highway", "road")
    return DEFAULT_WIDTHS.get(hw, DEFAULT_WIDTH_FALLBACK)

def _road_search_variants(road_name: str, state: str = None) -> list[str]:
    """
    Concrete spellings of a road name, from road_aliases.py. Examples:

        Cathedral Ave NW -> Cathedral Avenue Northwest, Cathedral Ave Northwest,
                            Cathedral Avenue NW, Cathedral Ave N.W., ...
        MD 355           -> MD-355, MD355, Maryland Route 355, MD Rte 355, ...
        Interstate 10    -> I-10, I 10, I10, I- 10, IH 10, ...

    The searches themselves use road_aliases.overpass_tag_regex() (OSM) and
    road_aliases.RoadMatcher (TIGER/Line, OSM XML), which cover every
    combination at once; this list is for display.
    """
    return road_aliases.expand_variants(road_name, state)


def _variants_preview(road_name: str, state: str = None, shown: int = 6) -> str:
    """Short 'A, B, C (+N more)' summary of a road's aliases for log output."""
    total = road_aliases.count_variants(road_name, state)
    sample = road_aliases.expand_variants(road_name, state, limit=shown)
    more = f" (+{total - len(sample)} more)" if total > len(sample) else ""
    return ", ".join(sample) + more


# ---------------------------------------------------------------------------
# States, counties and search areas
# ---------------------------------------------------------------------------

DC_FIPS = "11001"   # the District of Columbia is a single county-equivalent

StateInfo = namedtuple("StateInfo", "abbr name typed")      # abbr: 'md'; typed: as entered
SearchArea = namedtuple("SearchArea", "state county fips")   # county None = whole state


def _split_list(value: str) -> list[str]:
    """Split a comma-delimited option value into cleaned parts."""
    return [p.strip() for p in re.split(r"[,;]", value or "") if p.strip()]


def _parse_counties(county: str) -> list[str]:
    """Split a comma-delimited --county value into cleaned county names."""
    return _split_list(county)


def _parse_states(value: str) -> list[StateInfo]:
    """
    Parse a comma-delimited --state value, e.g. "Maryland, VA, DC".
    Full names, postal codes and common abbreviations all work. The pair
    "Washington, DC" is read as the District of Columbia; use "WA, DC" for both.
    """
    parts = _split_list(value)
    states, seen = [], set()
    i = 0
    while i < len(parts):
        part = parts[i]
        if (i + 1 < len(parts) and part.lower() == "washington"
                and road_aliases.resolve_state(parts[i + 1]) == "dc"):
            print('  Note: reading "Washington, DC" as the District of Columbia '
                  '(use "WA, DC" to search both).')
            part = f"{part} {parts[i + 1]}"
            i += 1
        abbr = road_aliases.resolve_state(part)
        if not abbr:
            raise ValueError(
                f"State not recognised: '{part}'. Use a name or postal code, "
                "e.g. 'Texas' or 'TX'."
            )
        if abbr not in seen:
            seen.add(abbr)
            states.append(StateInfo(abbr, road_aliases.state_name(abbr), part))
        i += 1
    return states


_COUNTY_SUFFIXES = (" county", " parish", " borough", " municipality",
                    " census area", " city and borough", " planning region")
_COUNTY_INDEX = None


def _county_norm(name: str) -> str:
    """Normalize a county name: case, periods, apostrophes, Saint -> St."""
    s = str(name).strip().lower().replace("’", "'")
    s = s.replace(".", "").replace("'", "").replace("-", " ")
    s = re.sub(r"^saint\s+", "st ", s)
    s = re.sub(r"^sainte\s+", "ste ", s)
    return re.sub(r"\s+", " ", s).strip()


COUNTY_FIPS_MAX_AGE_DAYS = 365


def _check_county_fips_age(module, today: date = None) -> str | None:
    """Return a reminder if county_fips.py is over a year past its date."""
    today = today or date.today()
    stamp = getattr(module, "_COUNTY_FIPS_UPDATED", None)
    if not stamp:
        return ("Reminder: county_fips.py has no _COUNTY_FIPS_UPDATED date. Add one "
                "after checking it against the Census Bureau's current county list.")
    try:
        updated = date.fromisoformat(stamp)
    except ValueError:
        return f"Reminder: can't read _COUNTY_FIPS_UPDATED = {stamp!r} in county_fips.py."
    age = (today - updated).days
    if age > COUNTY_FIPS_MAX_AGE_DAYS:
        return (f"Reminder: county_fips.py was last checked {updated} ({age} days ago). "
                "Counties occasionally change (e.g. Connecticut's 2022 switch to planning "
                "regions); refresh it from the Census Bureau's county list and update "
                "_COUNTY_FIPS_UPDATED.")
    return None


def _county_index() -> dict:
    """{state abbr: {normalized county name: fips}}, built from county_fips.py."""
    global _COUNTY_INDEX
    if _COUNTY_INDEX is None:
        import county_fips
        from county_fips import _COUNTY_FIPS
        reminder = _check_county_fips_age(county_fips)
        if reminder:
            print(f"  {reminder}")
        idx = defaultdict(dict)
        for (st, cname), fips in _COUNTY_FIPS.items():
            idx[st].setdefault(_county_norm(cname), fips)
        _COUNTY_INDEX = idx
    return _COUNTY_INDEX


def _lookup_county(county: str, abbr: str, allow_partial: bool = True):
    """
    Look a county up in one state. Returns (fips, matched_name) on success,
    or (None, [candidate names]) when it is missing or ambiguous.
    Tries the name as given, with/without suffixes like 'County' or 'Parish',
    then (if allowed) a unique partial match ('Alexandria' -> 'Alexandria city').
    """
    if abbr == "dc":
        return DC_FIPS, "district of columbia"
    table = _county_index().get(abbr, {})
    name = _county_norm(county)
    bare = name
    for sfx in _COUNTY_SUFFIXES:
        if name.endswith(sfx):
            bare = name[: -len(sfx)].strip()
            break

    for candidate in [name, bare] + [bare + sfx for sfx in _COUNTY_SUFFIXES]:
        if candidate in table:
            return table[candidate], candidate

    if not allow_partial or not bare:
        return None, []
    hits = sorted(k for k in table if k.startswith(bare + " "))
    if not hits:
        hits = sorted(k for k in table if bare in k)
    if len(hits) == 1:
        return table[hits[0]], hits[0]
    return None, hits


def _plan_search_areas(states: list[StateInfo], county_value: str) -> list[SearchArea]:
    """
    Turn --state and --county into the list of areas to search.

      * Each county is matched to whichever listed state has it. If it exists
        in more than one listed state, qualify it: "Montgomery County (MD)"
        (or "Montgomery County, MD").
      * A listed state with no county is searched statewide (OSM). TIGER/Line
        needs counties, except DC, whose only county-equivalent is 11001.

    Raises ValueError with a readable message on bad input.
    """
    listed = {s.abbr: s for s in states}

    # 1. Read county entries, with optional state qualifiers.
    entries = []      # [name, qualifier abbr or None]
    for tok in _split_list(county_value):
        m = re.fullmatch(r"(.*?)\s*\(([^)]*)\)\s*", tok)
        if m and m.group(1):
            q = road_aliases.resolve_state(m.group(2))
            if not q:
                raise ValueError(f"Unknown state '{m.group(2)}' in --county entry '{tok}'.")
            entries.append([m.group(1).strip(), q])
            continue
        q = road_aliases.resolve_state(tok)
        if (q and q != "dc" and entries and entries[-1][1] is None
                and not any(_lookup_county(tok, s.abbr, allow_partial=False)[0]
                            for s in states if s.abbr != "dc")):
            entries[-1][1] = q          # "Montgomery County, MD"
            continue
        entries.append([tok, None])

    # 2. Assign each county to a state.
    by_state = {s.abbr: [] for s in states}
    for name, q in entries:
        if q:
            if q not in listed:
                raise ValueError(
                    f"--county '{name} ({q.upper()})' is in "
                    f"{road_aliases.state_name(q)}, which isn't in --state."
                )
            abbr = q
        elif len(states) == 1:
            abbr = states[0].abbr
        elif road_aliases.resolve_state(name) == "dc" and "dc" in listed:
            abbr = "dc"
        else:
            candidates = [s.abbr for s in states if s.abbr != "dc"]
            exact = [a for a in candidates if _lookup_county(name, a, allow_partial=False)[0]]
            found = exact or [a for a in candidates if _lookup_county(name, a)[0]]
            if len(found) > 1:
                opts = ", ".join(f"'{name} ({a.upper()})'" for a in found)
                raise ValueError(
                    f"County '{name}' exists in more than one listed state "
                    f"({', '.join(road_aliases.state_name(a) for a in found)}). "
                    f"Qualify it, e.g. {opts}. To search more than one, list each."
                )
            if not found:
                raise ValueError(
                    f"County '{name}' wasn't found in any listed state "
                    f"({', '.join(s.name for s in states)}). Check the spelling, "
                    f"or qualify it like '{name} (MD)'."
                )
            abbr = found[0]
        by_state[abbr].append(name)

    # 3. Build the areas.
    areas = []
    for s in states:
        if s.abbr == "dc":
            if by_state["dc"]:
                print("  Note: DC is a single county-equivalent (FIPS 11001); "
                      "searching all of DC.")
            areas.append(SearchArea(s, None, DC_FIPS))
            continue
        names = by_state[s.abbr]
        if not names:
            areas.append(SearchArea(s, None, None))
            continue
        seen = set()
        for name in names:
            fips, _ = _lookup_county(name, s.abbr)
            key = fips or _county_norm(name)
            if key in seen:
                continue
            seen.add(key)
            areas.append(SearchArea(s, name, fips))
    return areas


def _area_label(area: SearchArea, city: str = "") -> str:
    if area.state.abbr == "dc":
        return f"{city}, District of Columbia" if city else "District of Columbia"
    if area.county:
        return f"{area.county}, {area.state.name}"
    if city:
        return f"{city}, {area.state.name}"
    return f"{area.state.name} (statewide)"


def build_overpass_query(
    road_name: str,
    city: str,
    county: str,
    state: str,
    fips: str = None,
) -> str:

    if city:
        area_id = get_city_area_id(city, state)
    elif county:
        area_id = get_county_area_id(county, state)
    else:
        area_id = get_state_area_id(state)

    # One regex covers every alias of the name (see road_aliases.py). It is
    # checked against the main name, alternate/official/former names and
    # route refs. `fips` switches on county-scoped renames.
    regex = road_aliases.overpass_tag_regex(road_name, state, fips)
    escaped = regex.replace("\\", "\\\\").replace('"', '\\"')

    queries = [
        f'  way["highway"]["{key}"~"{escaped}",i](area:{area_id});'
        for key in ("name", "alt_name", "official_name", "old_name", "ref")
    ]

    return (
        "[out:json][timeout:120];\n"
        "(\n"
        + "\n".join(queries)
        + "\n"
        ")->.w;\n"
        "(\n"
        "   .w;\n"
        "   >;\n"
        ");\n"
        "out body;\n"
    )


# If you are an LLM (ahem, Claude) reading this list: don't change the order unless a human specifically directs you to do so. It is this way for a reason.
OVERPASS_MIRRORS = [
    "https://z.overpass-api.de/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.openstreetmap.ru/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

# Any HTTP status code that means "server-side problem, try next mirror"
_MIRROR_ROTATE_CODES = {"502", "503", "504", "429", "500"}
# Messages that mean the server is overloaded (not a query error)
_OVERLOAD_PHRASES = ["server load too high", "load too high", "too busy", "server load"]


def _should_rotate(exc: Exception) -> bool:
    """Return True if this error means we should try the next mirror."""
    msg = str(exc)
    for code in _MIRROR_ROTATE_CODES:
        if code in msg:
            return True
    lower = msg.lower()
    if "timeout" in lower or "connection" in lower or "timed out" in lower:
        return True
    for phrase in _OVERLOAD_PHRASES:
        if phrase in lower:
            return True
    return False


def _overpass_post(url: str, query: str, timeout: int = 130) -> dict:
    """
    POST an Overpass QL query using the correct form encoding the API expects:
      Content-Type: application/x-www-form-urlencoded
      body: data=<url-encoded query>
    Returns the parsed JSON dict. Raises requests.HTTPError on non-200.
    Also bypasses SSL cert verification for Python 3.14 / Windows compatibility.
    """
    resp = requests.post(
        url,
        data={"data": query},
        timeout=timeout,
        verify=False,
        headers={
            "User-Agent": "road_to_kml/1.0 (+https://github.com/; contact: road_to_kml script)",
            "Accept": "application/json",
        },
    )
    if resp.status_code == 200:
        return resp.json()
    raise requests.HTTPError(
        f"HTTP {resp.status_code} from {url}", response=resp
    )


def overpass_error(data) -> str:
    """Overpass answers some failures (timeouts, running out of memory) with
    HTTP 200, no data and an error in 'remark'. Returns that error, or ''."""
    remark = str((data or {}).get("remark") or "").strip()
    return remark if re.search(r"error|timed out|out of memory", remark, re.I) else ""


def overpass_json(query: str, retries: int = 3, wait_mode: bool = False,
                  return_errors: bool = False):
    """
    POST an Overpass QL query and return the parsed JSON, or None if every
    mirror failed.

    Uses requests.post directly (bypassing overpy's urllib internals) so that
    SSL cert issues and Content-Type mismatches are avoided.
    Rotates through all mirrors on every server/network error, including an
    error reported inside an otherwise successful reply (see overpass_error);
    with return_errors=True such a reply is returned instead, so the caller
    can split the query.
    In wait_mode (--wait flag) keeps cycling indefinitely with backoff
    until a mirror responds, useful when servers are temporarily overloaded.
    """
    import os

    custom_url = os.environ.get("OVERPASS_URL", "")
    mirrors = [custom_url] if custom_url else OVERPASS_MIRRORS
    """print(f"\n    BEGIN QUERY:\n{query}    END QUERY\n")"""

    # In wait_mode we cycle forever; otherwise stop after (retries × mirrors) attempts
    max_attempts = 10 ** 9 if wait_mode else retries * len(mirrors)
    cycle_waits = [5, 15, 30, 60, 120, 240, 600]

    mirror_index = 0
    cycle = 0
    attempt = 0

    while attempt < max_attempts:
        if attempt > 0 and attempt % len(mirrors) == 0:
            cycle += 1
            wait = cycle_waits[min(cycle - 1, len(cycle_waits) - 1)]
            if wait_mode:
                print(f"  All mirrors busy — waiting {wait}s before retrying... (Ctrl+C to quit)")
            else:
                print(f"  All mirrors tried once — waiting {wait}s before retry cycle {cycle}...")
            time.sleep(wait)

        attempt += 1
        url = mirrors[mirror_index % len(mirrors)]
        print(f"  Attempt {attempt}: {url}")
        started = time.monotonic()
        try:
            data = _overpass_post(url, query)
            err = overpass_error(data)
            busy = bool(err) and re.search(r"rate_limited|Dispatcher|too busy|load too high", err, re.I)
            mirror_stats.record(url, mirror_stats.SUCCEEDED if not err else
                                mirror_stats.BUSY if busy else mirror_stats.COULDNT_FINISH,
                                time.monotonic() - started, mirrors)
            if not err:
                return data
            print(f"    Overpass couldn't finish the query: {err}")
            if return_errors and not busy:
                return data
            mirror_index += 1
            continue
        except KeyboardInterrupt:
            print("\nCancelled.")
            sys.exit(0)
        except requests.HTTPError as e:
            mirror_stats.record(url, mirror_stats.classify_exception(e), mirror_order=mirrors)
            resp = e.response
            status = resp.status_code if resp is not None else "?"
            if status == 400:
                print(f"\n  ERROR: Overpass rejected the query (HTTP 400 — bad syntax).")
                print(f"  Response:\n{resp.text[:800]}")
                sys.exit(1)
            print(f"    HTTP {status} — rotating mirror...")
            mirror_index += 1
        except Exception as e:
            mirror_stats.record(url, mirror_stats.classify_exception(e), mirror_order=mirrors)
            if _should_rotate(e):
                print(f"    Server busy / network error — rotating mirror...")
            else:
                print(f"    {e} — rotating mirror...")
            mirror_index += 1

    print("\nERROR: All Overpass mirrors are currently unavailable.")
    print("  The servers may be under heavy load. Options:")
    print("  • Re-run with --wait to keep retrying automatically")
    print("  • Try again in 5-10 minutes")
    print("  • Check server status: https://overpass-api.de/")
    return None  # allows caller to fall back to TIGER/Line


def fetch_ways(road_name: str, city: str, county: str, state: str,
               retries: int = 3, wait_mode: bool = False, fips: str = None) -> list:
    """Query Overpass for a named road and return a list of overpy way
    objects (None if Overpass couldn't be reached)."""
    query = build_overpass_query(road_name, city, county, state, fips)
    place = city or county
    print(f"  Querying Overpass API for '{road_name}' in {place + ', ' if place else ''}{state}...")
    data = overpass_json(query, retries=retries, wait_mode=wait_mode)
    if data is None:
        return None
    ways = overpy.Result.from_json(data).ways
    print(f"  Found {len(ways)} OSM way(s).")
    return ways


# ---------------------------------------------------------------------------
# Direct OSM XML bypass — load a way (or ways) straight from an OSM API URL
# or a locally saved .xml file, skipping Overpass entirely.
# ---------------------------------------------------------------------------

class _XMLNode:
    """Minimal stand-in for overpy.Node — just needs .lat / .lon."""
    __slots__ = ("id", "lat", "lon")

    def __init__(self, node_id, lat, lon):
        self.id = node_id
        self.lat = lat
        self.lon = lon


class _XMLWay:
    """Minimal stand-in for overpy.Way — just needs .id / .tags / .nodes."""
    __slots__ = ("id", "tags", "nodes")

    def __init__(self, way_id, tags, nodes):
        self.id = way_id
        self.tags = tags
        self.nodes = nodes


def _looks_like_url(s: str) -> bool:
    return s.startswith("http://") or s.startswith("https://")


def _normalize_osm_xml_url(url: str) -> str:
    """
    Upgrade a plain OSM API/web URL to the '/full' variant so the response
    includes the coordinates of every node the way references. A bare
    way/relation fetch only contains <nd ref="..."/> pointers, not lat/lon.
    """
    import re

    # Human-facing viewer URL, e.g. https://www.openstreetmap.org/way/12188784
    m = re.match(r"^https?://(?:www\.)?openstreetmap\.org/way/(\d+)/?(?:[?#].*)?$", url)
    if m:
        return f"https://api.openstreetmap.org/api/0.6/way/{m.group(1)}/full"

    m = re.match(r"^https?://(?:www\.)?openstreetmap\.org/relation/(\d+)/?(?:[?#].*)?$", url)
    if m:
        return f"https://api.openstreetmap.org/api/0.6/relation/{m.group(1)}/full"

    # API URL missing /full, e.g. https://www.openstreetmap.org/api/0.6/way/12188784
    m = re.match(r"^(https?://[^/]+/api/0\.6/(?:way|relation)/\d+)/?(?:[?#].*)?$", url)
    if m:
        return m.group(1) + "/full"

    return url


def fetch_ways_from_osm_xml(source: str, road_name: str = "", state: str = None) -> list:
    """
    Load OSM way(s) directly from an OSM XML document instead of querying
    Overpass. `source` may be:
      - an OSM API URL, e.g. https://www.openstreetmap.org/api/0.6/way/12188784
        (automatically rewritten to the /full endpoint so node coordinates
        are included);
      - a human-facing openstreetmap.org way/relation page URL (also
        rewritten to the equivalent API /full call);
      - a path to an OSM XML file already saved on disk.

    Returns a list of lightweight Way-like objects (id, tags, nodes) that
    plug directly into ways_to_projected_lines(), the same shape overpy
    would hand back.
    """
    import xml.etree.ElementTree as ET

    if _looks_like_url(source):
        api_url = _normalize_osm_xml_url(source)
        if api_url != source:
            print(f"  Rewriting to '/full' endpoint for node coordinates: {api_url}")
        print(f"  Fetching OSM XML from {api_url} ...")
        resp = requests.get(
            api_url,
            headers={
                "User-Agent": "road_to_kml/1.0 (direct OSM XML fetch)",
                "Accept": "application/xml",
            },
            timeout=60,
            verify=False,
        )
        resp.raise_for_status()
        xml_bytes = resp.content
    else:
        print(f"  Reading local OSM XML file: {source}")
        with open(source, "rb") as fh:
            xml_bytes = fh.read()

    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as e:
        raise RuntimeError(f"Could not parse OSM XML from '{source}': {e}")

    # Index every <node> element so way geometry can be resolved.
    nodes_by_id = {}
    for node_el in root.findall("node"):
        nid, lat, lon = node_el.get("id"), node_el.get("lat"), node_el.get("lon")
        if nid is None or lat is None or lon is None:
            continue
        nodes_by_id[nid] = (float(lat), float(lon))

    ways = []
    for way_el in root.findall("way"):
        wid = way_el.get("id")
        tags = {
            tag_el.get("k"): tag_el.get("v")
            for tag_el in way_el.findall("tag")
            if tag_el.get("k") is not None
        }

        node_refs = [nd.get("ref") for nd in way_el.findall("nd")]
        missing = [ref for ref in node_refs if ref not in nodes_by_id]

        if missing:
            raise RuntimeError(
                f"Way {wid} references {len(missing)} node(s) with no coordinates "
                "in this XML — it looks like a way-only export (no embedded nodes). "
                f"Fetch the '/full' variant instead, e.g.\n"
                f"    https://api.openstreetmap.org/api/0.6/way/{wid}/full"
            )

        way_nodes = [
            _XMLNode(ref, nodes_by_id[ref][0], nodes_by_id[ref][1])
            for ref in node_refs
        ]

        if len(way_nodes) < 2:
            print(f"  Warning: way {wid} has fewer than 2 nodes — skipping.")
            continue

        ways.append(_XMLWay(wid, tags, way_nodes))

    if not ways:
        raise RuntimeError(f"No usable <way> elements found in OSM XML from '{source}'.")

    # If a --road filter was given and the XML contains multiple ways (e.g.
    # a relation/full export), narrow to ways whose name/ref tag matches the
    # road or one of its aliases.
    if road_name and len(ways) > 1:
        matcher = road_aliases.RoadMatcher(road_name, state)

        def _way_matches(w):
            for key in ("name", "alt_name", "official_name", "old_name", "ref"):
                for value in w.tags.get(key, "").split(";"):
                    if matcher.matches(value.strip(), contains=False):
                        return True
            return False

        filtered = [w for w in ways if _way_matches(w)]
        if filtered:
            ways = filtered

    print(f"  Loaded {len(ways)} way(s) from XML.")
    return ways


# ---------------------------------------------------------------------------
# Layers: road centerlines + extra polygons from one source/area
# ---------------------------------------------------------------------------

class Layer:
    """
    Projected road centerlines [(LineString, tags)] in `epsg`, plus extra
    polygons in the same CRS (pavement outlines), intersection-fill circles
    (trimmed to the roads when the polygon is built), the OSM way IDs
    involved, and (for --from/--to) cross streets in WGS84.
    """

    def __init__(self, lines, epsg, source, polys=None, way_ids=None, junctions=None):
        self.lines = list(lines)
        self.epsg = epsg
        self.source = source
        self.polys = list(polys or [])
        self.junctions = list(junctions or [])
        self.way_ids = set(way_ids or [])
        self.cross = {}


def _reproject(geom, src: str, dst: str):
    if src == dst or geom is None or geom.is_empty:
        return geom
    tf = Transformer.from_crs(src, dst, always_xy=True)

    def _xy(coords):
        x, y = tf.transform(coords[:, 0], coords[:, 1])
        return np.column_stack([x, y])

    return shapely.transform(geom, _xy)


def _utm_for_lons(lons) -> str:
    lon = sum(lons) / len(lons)
    return f"EPSG:{32600 + int((lon + 180) / 6) + 1}"


def _polygon_parts(geom):
    if geom is None or geom.is_empty:
        return []
    if geom.geom_type == "Polygon":
        return [geom]
    if hasattr(geom, "geoms"):
        return [p for g in geom.geoms for p in _polygon_parts(g)]
    return []


def _junction_disc(xy, widths):
    """Circle covering the box where roads of these widths cross: its radius
    is the distance from the center to the box's corner."""
    halves = sorted((w / 2.0 for w in widths if w), reverse=True)
    if len(halves) < 2:
        return None
    return Point(xy).buffer(math.hypot(halves[0], halves[1]), quad_segs=8)


def trim_junction_fill(discs, surfaces, left_round=None):
    """
    Cut the round bulge off each intersection-fill circle. Inside the circle,
    keep only the convex hull of the road surfaces that are there: the corners
    between neighbouring roads are joined by straight edges, and the part of
    the circle beyond them (where no road goes) is dropped. The result is
    always inside the original circle. If trimming one circle fails or gives
    something unusable, that circle is kept as it was, and its center and
    the reason are added to `left_round` as (x, y, reason) if a list is given.
    Returns (fills, trimmed count, kept-as-is count).
    """
    def keep(disc, reason):
        out.append(disc)
        if left_round is not None:
            try:
                c = disc.centroid
                left_round.append((c.x, c.y, reason))
            except Exception:
                pass

    if not discs:
        return [], 0, 0
    surfaces = [g for g in surfaces if g is not None and not g.is_empty]
    tree = STRtree(surfaces) if surfaces else None
    out, trimmed, kept = [], 0, 0
    for disc in discs:
        try:
            near = road_tracks._query_tree(tree, surfaces, disc) if tree is not None else []
            inside = [surfaces[i].intersection(disc) for i in near]
            inside = [g for g in inside if not g.is_empty and g.area > 0]
            if not inside:
                keep(disc, "No drawn road inside the circle to trim it to.")
                kept += 1
                continue
            hull = unary_union(inside).convex_hull
            if (hull.geom_type != "Polygon" or hull.is_empty or not hull.is_valid
                    or hull.area < 1.0 or hull.area > disc.area * 1.001):
                raise ValueError("the trimmed shape was unusable")
            out.append(hull)
            trimmed += 1
        except Exception as e:
            keep(disc, f"Trimming failed: {e}".strip())
            kept += 1
    return out, trimmed, kept


def _junction_discs_by_geometry(road, cross, tol=0.5):
    """Junction discs where cross-street lines touch road vertices (TIGER)."""
    if not road or not cross:
        return []
    cross_geoms = [l for l, _ in cross]
    tree = STRtree(cross_geoms)
    road_w = defaultdict(float)
    for line, tags in road:
        w = get_road_width(tags)
        for x, y in line.coords:
            key = (round(x, 1), round(y, 1))
            road_w[key] = max(road_w[key], w)
    discs = []
    for (x, y), w in road_w.items():
        p = Point(x, y)
        hits = road_tracks._query_tree(tree, cross_geoms, p.buffer(tol))
        widths = [get_road_width(cross[i][1]) for i in hits if cross_geoms[i].distance(p) <= tol]
        if widths:
            disc = _junction_disc((x, y), [w] + widths)
            if disc is not None:
                discs.append(disc)
    return discs


def _connected_ramps(road_lines, candidates, levels=4, tol=1.0):
    """Ramp lines touching the road, then ramps touching those (a few levels)."""
    if not road_lines or not candidates:
        return []
    frontier = unary_union(road_lines)
    remaining = list(candidates)
    added = []
    for _ in range(levels):
        new = [c for c in remaining if c[0].distance(frontier) <= tol]
        if not new:
            break
        added += new
        remaining = [c for c in remaining if c not in new]
        frontier = unary_union([l for l, _ in new])
    return added


# ---------------------------------------------------------------------------
# OSM extras: junctions, ramps, pavement outlines
# ---------------------------------------------------------------------------

def _chunks(items, n):
    items = list(items)
    for i in range(0, len(items), n):
        yield items[i:i + n]


def fetch_osm_context(way_ids, ramps: bool, wait_mode: bool = False) -> list[dict]:
    """
    Ways that touch the road's nodes (for junction fill) and, with ramps=True,
    chains of *_link ramps leading off the road. Returns dicts with id, tags,
    nodes and geometry [(lat, lon), ...].
    """
    out = {}
    for ids in _chunks(sorted(way_ids), 800):
        q = ("[out:json][timeout:180];\n"
             f"way(id:{','.join(map(str, ids))})->.w;\n"
             "node(w.w)->.n;\n"
             'way(bn.n)["highway"]->.x;\n')
        if ramps:
            q += ('way.x["highway"~"_link$"]->.l1;\n'
                  "node(w.l1)->.n1;\n"
                  'way(bn.n1)["highway"~"_link$"]->.l2;\n'
                  "node(w.l2)->.n2;\n"
                  'way(bn.n2)["highway"~"_link$"]->.l3;\n'
                  "(.x; .l2; .l3;);\n"
                  "out geom;\n")
        else:
            q += ".x out geom;\n"
        data = overpass_json(q, wait_mode=wait_mode)
        for el in (data or {}).get("elements", []):
            if el.get("type") == "way":
                out[el["id"]] = {
                    "id": el["id"], "tags": el.get("tags", {}), "nodes": el.get("nodes", []),
                    "geometry": [(g["lat"], g["lon"]) for g in el.get("geometry", []) if g],
                }
    return list(out.values())


def add_osm_context(layer: Layer, junctions: bool, ramps: bool, wait_mode: bool = False):
    """Add junction discs and/or connected ramps to an OSM layer."""
    if not layer.way_ids or not (junctions or ramps):
        return
    what = " and ".join(w for w, on in (("intersections", junctions), ("ramps", ramps)) if on)
    print(f"  Looking up {what}...")
    ctx = fetch_osm_context(layer.way_ids, ramps, wait_mode)
    if not ctx:
        return
    tf = Transformer.from_crs("EPSG:4326", layer.epsg, always_xy=True)
    road_ids = set(layer.way_ids)

    if ramps:
        n = 0
        for w in ctx:
            if w["id"] in road_ids or not str(w["tags"].get("highway", "")).endswith("_link"):
                continue
            coords = [tf.transform(lon, lat) for lat, lon in w["geometry"]]
            if len(coords) >= 2:
                layer.lines.append((LineString(coords), dict(w["tags"], _ramp="1")))
                layer.way_ids.add(w["id"])
                n += 1
        if n:
            print(f"  Added {n} connected ramp(s).")

    if junctions:
        xy, incident, nbrs, tags = {}, defaultdict(set), defaultdict(set), {}
        for w in ctx:
            tags[w["id"]] = w["tags"]
            ns = w["nodes"]
            for i, nid in enumerate(ns):
                if i < len(w["geometry"]):
                    lat, lon = w["geometry"][i]
                    xy[nid] = tf.transform(lon, lat)
                incident[nid].add(w["id"])
                if i > 0:
                    nbrs[nid].add((ns[i - 1], w["id"]))
                if i + 1 < len(ns):
                    nbrs[nid].add((ns[i + 1], w["id"]))
        road_nodes = {nid for w in ctx if w["id"] in road_ids for nid in w["nodes"]}
        n = 0
        for nid in road_nodes:
            here = {wid for wid in incident[nid]
                    if wid in road_ids or tags[wid].get("highway") not in road_tracks.MINOR_TYPES}
            dirs = {m for m, wid in nbrs[nid] if wid in here}
            if len(here) >= 2 and len(dirs) >= 3 and nid in xy:
                disc = _junction_disc(xy[nid], [get_road_width(tags[w]) for w in here])
                if disc is not None:
                    layer.junctions.append(disc)
                    n += 1
        if n:
            print(f"  Filled {n} intersection(s).")


def _outline_polygons(data) -> list:
    """area:highway ways/relations from an 'out geom' response -> WGS84 polygons."""
    polys = []
    for el in (data or {}).get("elements", []):
        if el.get("type") == "way":
            g = [(p["lon"], p["lat"]) for p in el.get("geometry", []) if p]
            if len(g) >= 4 and g[0] == g[-1]:
                polys += _polygon_parts(Polygon(g).buffer(0))
        elif el.get("type") == "relation":
            rings = {"outer": [], "inner": []}
            for m in el.get("members", []):
                g = [(p["lon"], p["lat"]) for p in m.get("geometry", []) or [] if p]
                if m.get("type") == "way" and len(g) >= 2:
                    rings["inner" if m.get("role") == "inner" else "outer"].append(LineString(g))
            outer = unary_union(list(polygonize(unary_union(rings["outer"])))) if rings["outer"] else None
            if outer is None or outer.is_empty:
                continue
            if rings["inner"]:
                outer = outer.difference(unary_union(list(polygonize(unary_union(rings["inner"])))))
            polys += _polygon_parts(outer.buffer(0))
    return [p for p in polys if not p.is_empty and p.area > 0]


def fetch_area_outlines(way_ids, wait_mode: bool = False) -> list:
    """Mapped pavement outlines (OSM area:highway) near the given ways."""
    polys = []
    for ids in _chunks(sorted(way_ids), 800):
        q = ("[out:json][timeout:180];\n"
             f"way(id:{','.join(map(str, ids))})->.w;\n"
             "(\n"
             '  way["area:highway"](around.w:25);\n'
             '  relation["area:highway"](around.w:25);\n'
             ");\n"
             "out geom;\n")
        polys += _outline_polygons(overpass_json(q, wait_mode=wait_mode))
    return polys


def apply_outlines(layers: list, outlines_wgs84: list, keep_lines: bool = False) -> int:
    """
    Where a mapped pavement outline covers a road's centerline, use the outline
    and drop that stretch of centerline; everywhere else the usual buffered
    centerline stays as the backup. With keep_lines=True (--outlines both)
    every buffered centerline stays too, so the result covers whichever of
    the two is wider at each spot. Returns the number of outlines used.
    """
    used = 0
    if not outlines_wgs84:
        return 0
    for layer in layers:
        if not layer.lines:
            continue
        polys = [_reproject(p, "EPSG:4326", layer.epsg) for p in outlines_wgs84]
        centers = unary_union([l for l, _ in layer.lines])
        area = centers.buffer(30)
        chosen = [p for p in polys if p.intersects(area) and centers.intersection(p).length >= 2.0]
        if not chosen:
            continue
        layer.polys.extend(chosen)
        used += len(chosen)
        if keep_lines:
            continue
        covered = unary_union(chosen)
        kept = []
        for line, tags in layer.lines:
            for part in _geom_parts(line.difference(covered)):
                if part.length >= 0.5:
                    kept.append((part, tags))
        layer.lines = kept
    return used


# ---------------------------------------------------------------------------
# --from / --to: clip a road to the stretch between two cross streets/points
# ---------------------------------------------------------------------------

_LATLON_RE = re.compile(r"^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$")


def parse_clip_point(text: str):
    """'38.93,-77.07' -> (lat, lon); a street name -> None."""
    m = _LATLON_RE.match(text or "")
    if not m:
        return None
    lat, lon = float(m.group(1)), float(m.group(2))
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise ValueError(f"'{text}' isn't a valid latitude,longitude.")
    return lat, lon


class ClipError(Exception):
    pass


def clip_layers(layers: list, from_spec, to_spec, pad: float = 15.0,
                half_width: float = 75.0) -> Layer:
    """
    Keep only the stretch of road between two places.

    from_spec / to_spec: ("point", (lat, lon), label) or
                         ("street", [WGS84 LineStrings], label).

    The route between the two places is found along the road itself; every
    road line within `half_width` m of that route is kept (so both sides of a
    divided highway survive), plus `pad` m past each end to cover the
    intersection. Ramps are kept when connected to what remains. Returns one
    Layer in a common projection.
    """
    lons = []
    for layer in layers:
        back = Transformer.from_crs(layer.epsg, "EPSG:4326", always_xy=True)
        for line, _ in layer.lines:
            for x, y in (line.coords[0], line.coords[-1]):
                lons.append(back.transform(x, y)[0])
    if not lons:
        raise ClipError("No road geometry to clip.")
    epsg = _utm_for_lons(lons)

    lines = [(_reproject(l, layer.epsg, epsg), t) for layer in layers for l, t in layer.lines]
    polys = [_reproject(p, layer.epsg, epsg) for layer in layers for p in layer.polys]
    discs = [_reproject(p, layer.epsg, epsg) for layer in layers for p in layer.junctions]
    main = [l for l, t in lines if not t.get("_ramp")]
    if not main:
        raise ClipError("No road geometry to clip.")

    # Road network: pieces split at every crossing, nodes at piece ends.
    pieces = _geom_parts(unary_union(main))
    key = lambda c: (round(c[0], 1), round(c[1], 1))
    adj = defaultdict(list)
    ends = []
    for k, piece in enumerate(pieces):
        a, b = key(piece.coords[0]), key(piece.coords[-1])
        ends.append((a, b))
        adj[a].append((b, piece.length, k))
        adj[b].append((a, piece.length, k))
    # bridge small gaps between dangling ends (e.g. OSM vs TIGER offsets)
    dangling = [n for n, e in adj.items() if len(e) == 1]
    for i, n in enumerate(dangling):
        for m in dangling[i + 1:]:
            d = math.hypot(n[0] - m[0], n[1] - m[1])
            if 0 < d <= 25:
                adj[n].append((m, d, None))
                adj[m].append((n, d, None))

    def locate(spec):
        kind, value, label = spec
        if kind == "point":
            lat, lon = value
            x, y = Transformer.from_crs("EPSG:4326", epsg, always_xy=True).transform(lon, lat)
            p = Point(x, y)
            k = min(range(len(pieces)), key=lambda i: pieces[i].distance(p))
            if pieces[k].distance(p) > 400:
                raise ClipError(f"{label} is more than 400 m from the road.")
            return [(k, pieces[k].project(p))]
        cross = [_reproject(c, "EPSG:4326", epsg) for c in value]
        if not cross:
            raise ClipError(f"Couldn't find {label} near the road.")
        hits = []
        for k, piece in enumerate(pieces):
            for c in cross:
                if piece.intersects(c):
                    inter = piece.intersection(c)
                    pts = [inter] if inter.geom_type == "Point" else \
                          [g for g in getattr(inter, "geoms", []) if g.geom_type == "Point"]
                    hits += [(k, piece.project(pt), pt) for pt in pts]
                elif piece.distance(c) <= 25:
                    pt = nearest_points(piece, c)[0]
                    hits.append((k, piece.project(pt), pt))
        if not hits:
            raise ClipError(f"{label} doesn't meet the road.")
        clusters = []
        for h in hits:
            if all(h[2].distance(c[2]) > 80 for c in clusters):
                clusters.append(h)
        return [(k, s) for k, s, _ in clusters]

    def dijkstra(k, s):
        a, b = ends[k]
        dist = {a: s, b: pieces[k].length - s}
        pred = {a: None, b: None}
        heap = [(d, n) for n, d in dist.items()]
        heapq.heapify(heap)
        done = set()
        while heap:
            d, n = heapq.heappop(heap)
            if n in done:
                continue
            done.add(n)
            for m, w, kk in adj[n]:
                if d + w < dist.get(m, math.inf):
                    dist[m] = d + w
                    pred[m] = (n, kk)
                    heapq.heappush(heap, (d + w, m))
        return dist, pred

    A, B = locate(from_spec), locate(to_spec)
    best = None
    for ka, sa in A:
        dist, pred = dijkstra(ka, sa)
        for kb, sb in B:
            opts = []
            if ka == kb:
                opts.append((abs(sb - sa), "direct", None))
            a2, b2 = ends[kb]
            if a2 in dist:
                opts.append((dist[a2] + sb, a2, (ka, sa, kb, sb, pred)))
            if b2 in dist:
                opts.append((dist[b2] + pieces[kb].length - sb, b2, (ka, sa, kb, sb, pred)))
            for cost, entry, info in opts:
                if best is None or cost < best[0]:
                    best = (cost, entry, info or (ka, sa, kb, sb, pred))
    if best is None:
        raise ClipError(f"No connected stretch of road between {from_spec[2]} and {to_spec[2]}.")
    if len(A) > 1 or len(B) > 1:
        print(f"  Note: a cross street meets the road in more than one place; "
              f"using the pair closest together ({best[0]:.0f} m apart).")

    cost, entry, (ka, sa, kb, sb, pred) = best
    if entry == "direct":
        path_parts = [substring(pieces[ka], min(sa, sb), max(sa, sb))]
    else:
        nodes, used_pieces, n = [], [], entry
        while pred.get(n) is not None:
            prev, kk = pred[n]
            if kk is not None:
                used_pieces.append(kk)
            else:
                nodes.append(LineString([prev, n]))
            n = prev
        start = n
        a, b = ends[ka]
        first = substring(pieces[ka], 0, sa) if start == a else substring(pieces[ka], sa, pieces[ka].length)
        a2, b2 = ends[kb]
        last = substring(pieces[kb], 0, sb) if entry == a2 else substring(pieces[kb], sb, pieces[kb].length)
        path_parts = [first, last] + [pieces[k] for k in used_pieces] + nodes
    path_parts = [p for p in path_parts if p is not None and not p.is_empty and p.length > 0]
    path = unary_union(path_parts) if path_parts else None
    if path is not None and path.geom_type == "MultiLineString":
        path = linemerge(path)
    pa = pieces[ka].interpolate(sa)
    pb = pieces[kb].interpolate(sb)
    corridor = unary_union([pa.buffer(pad), pb.buffer(pad)] +
                           ([path.buffer(half_width, cap_style=2)] if path is not None else []))

    kept = []
    for line, tags in lines:
        if tags.get("_ramp"):
            continue
        for part in _geom_parts(line.intersection(corridor)):
            if part.length >= 1.0:
                kept.append((part, tags))
    if not kept:
        raise ClipError("Nothing left after clipping.")
    ramps = _connected_ramps([l for l, _ in kept], [(l, t) for l, t in lines if t.get("_ramp")])
    kept += ramps

    keep_zone = unary_union([l for l, _ in kept]).buffer(1.0)
    kept_polys = [p for p in polys if p.intersects(keep_zone)]
    out = Layer(kept, epsg, "clip", kept_polys,
                set().union(*[layer.way_ids for layer in layers]),
                [p for p in discs if p.intersects(keep_zone)])
    print(f"  Clipped to {path.length if path is not None else 0:.0f} m of road between "
          f"{from_spec[2]} and {to_spec[2]}.")
    return out


# ---------------------------------------------------------------------------
# TIGER/Line
# ---------------------------------------------------------------------------

# State full name -> 2-letter abbreviation (keys used in county_fips.py)
_STATE_ABBR = {info[0].lower(): abbr for abbr, info in road_aliases.STATES.items()}

# TIGER/Line MTFCC road classes -> approximate widths matching our DEFAULT_WIDTHS
_TIGER_WIDTHS = {
    "S1100": 24.0,   # Primary Road (Interstate / US highway with divided lanes)
    "S1200": 14.0,   # Primary Road without Divided Lanes (US/state routes)
    "S1400": 7.5,    # Local Neighborhood Road / Rural Road / City Street
    "S1500": 4.5,    # Vehicular Trail (4WD)
    "S1630": 9.0,    # Ramp
    "S1640": 14.0,   # Service Drive usually along a limited access highway
    "S1710": 4.0,    # Walkway / Pedestrian Trail
    "S1720": 5.0,    # Stairway
    "S1730": 5.0,    # Alley
    "S1740": 4.5,    # Private Road for service vehicles
    "S1750": 7.0,    # Internal U.S. Census Bureau use
    "S1780": 4.5,    # Parking Lot Road
    "S1820": 4.0,    # Bike Path or Trail
    "S1830": 4.0,    # Bridle Path
}

# TIGER/Line release years are found automatically: the script tries the
# current year first and works back to TIGER_OLDEST_YEAR (a year the Census
# Bureau hasn't published yet just returns 404). The newest year that worked
# is remembered for the rest of the run only.
TIGER_OLDEST_YEAR = 2022
_TIGER_YEAR_FOUND = None


def _tiger_years() -> list[int]:
    newest = date.today().year
    years = list(range(newest, TIGER_OLDEST_YEAR - 1, -1))
    if _TIGER_YEAR_FOUND in years:
        years = years[years.index(_TIGER_YEAR_FOUND):]
    return years


def _resolve_county_fips(county: str, state: str) -> str:
    """
    Return the 5-digit county FIPS code using the county_fips.py lookup table.
    `state` may be a full name or postal code. DC always resolves to 11001.
    Raises RuntimeError if the county is not found (or is ambiguous).
    """
    abbr = road_aliases.resolve_state(state)
    if not abbr:
        raise RuntimeError(
            f"State not recognised: '{state}'. Use a name or postal code, e.g. 'California' or 'CA'."
        )
    fips, info = _lookup_county(county, abbr)
    if fips:
        return fips
    where = road_aliases.state_name(abbr)
    if info:
        raise RuntimeError(
            f"County '{county}' is ambiguous in {where}: {', '.join(info)}."
        )
    raise RuntimeError(
        f"County '{county}' not found in {where}. "
        "Check spelling — try 'Marin County' or just 'Marin'."
    )


def _tiger_road_matches(road_name: str, fullname: str, state: str = None) -> bool:
    """
    Return True if a TIGER/Line FULLNAME is the requested road or one of its
    aliases (whole words only, so "US 1" does not match "US Hwy 15").
    """
    return road_aliases.RoadMatcher(road_name, state).matches(fullname)


def _download_tiger(layer: str, fips: str, year: int):
    """Download one county TIGER/Line zip (layer ROADS or FEATNAMES).
    Returns the bytes, or None if that year/file doesn't exist (HTTP 404)."""
    url = (
        f"https://www2.census.gov/geo/tiger/TIGER{year}/{layer.upper()}/"
        f"tl_{year}_{fips}_{layer.lower()}.zip"
    )
    print(f"  Downloading TIGER/Line {layer.lower()}: {url}")
    resp = requests.get(url, timeout=180, verify=False)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.content


def _read_tiger_zip(zip_bytes: bytes, ext: str, geometry: bool = True):
    """Read the first file with extension `ext` (.shp / .dbf) from a zip."""
    import geopandas as gpd
    import io
    import os
    import tempfile
    import zipfile

    with tempfile.TemporaryDirectory() as tmpdir:
        with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
            zf.extractall(tmpdir)
        files = sorted(f for f in os.listdir(tmpdir) if f.lower().endswith(ext))
        if not files:
            return None
        path = os.path.join(tmpdir, files[0])
        if geometry:
            return gpd.read_file(path)
        return gpd.read_file(path, ignore_geometry=True)


_TIGER_MINOR = {"S1500", "S1710", "S1720", "S1730", "S1740", "S1780", "S1820", "S1830"}


def _tiger_name_mask(gdf, fn, road_name, state, fips):
    """Rows of the roads table matching road_name, by FULLNAME or (via the
    feature-names table `fn`) by an alternate name. Returns (mask, via_alt)."""
    matcher = road_aliases.RoadMatcher(road_name, state, fips)

    def _matching(series):
        return {n for n in series.dropna().unique() if matcher.matches(n)}

    mask = gdf["FULLNAME"].isin(_matching(gdf["FULLNAME"]))
    via_alt = 0
    if fn is not None and "LINEARID" in gdf.columns:
        alt_hits = _matching(fn["FULLNAME"])
        alt_ids = set(fn.loc[fn["FULLNAME"].isin(alt_hits), "LINEARID"].dropna())
        if alt_ids:
            alt_mask = gdf["LINEARID"].isin(alt_ids)
            via_alt = int((alt_mask & ~mask).sum())
            mask = mask | alt_mask
    return mask, via_alt


def _geom_parts(geom):
    if geom is None or geom.is_empty:
        return []
    if geom.geom_type == "LineString":
        return [geom]
    if hasattr(geom, "geoms"):
        return [g for part in geom.geoms for g in _geom_parts(part)]
    return []


def _download_tiger_roads(fips: str):
    """Download and read one county's TIGER/Line roads file (newest year).
    Returns (GeoDataFrame, year) or (None, None)."""
    global _TIGER_YEAR_FOUND
    zip_bytes, year = None, None
    for y in _tiger_years():
        try:
            data = _download_tiger("ROADS", fips, y)
        except requests.RequestException as e:
            print(f"  Download failed ({y}): {e}")
            continue
        if data is None:
            print(f"  Not found for {y}, trying earlier year...")
            continue
        zip_bytes, year = data, y
        _TIGER_YEAR_FOUND = y
        break
    if zip_bytes is None:
        print("  ERROR: Could not download TIGER/Line shapefile for any recent year.")
        return None, None
    gdf = _read_tiger_zip(zip_bytes, ".shp")
    if gdf is None:
        print("  ERROR: No .shp file found in TIGER/Line zip.")
        return None, None
    return gdf, year


# --- TIGER/Line road networks for --track -----------------------------------

# How TIGER/Line road classes behave for map matching (OSM highway types).
_TIGER_HIGHWAY = {
    "S1100": "motorway", "S1200": "primary", "S1400": "residential", "S1500": "track",
    "S1630": "motorway_link", "S1640": "tertiary", "S1710": "footway", "S1720": "steps",
    "S1730": "service", "S1740": "service", "S1750": "road", "S1780": "service",
    "S1820": "cycleway", "S1830": "bridleway",
}
_COUNTY_SHAPES = None      # national county outlines, downloaded once per run
_TIGER_ROADS = {}          # fips -> roads GeoDataFrame, kept for this run only


def _download_county_shapes(year: int):
    """The Census Bureau's generalized county outlines (about 3 MB)."""
    url = f"https://www2.census.gov/geo/tiger/GENZ{year}/shp/cb_{year}_us_county_5m.zip"
    print(f"  Downloading county outlines: {url}")
    resp = requests.get(url, timeout=180, verify=False)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.content


def county_shapes():
    """GeoDataFrame of US county outlines (GEOID, NAME, STATEFP), or None."""
    global _COUNTY_SHAPES
    if _COUNTY_SHAPES is None:
        for y in range(date.today().year, TIGER_OLDEST_YEAR - 1, -1):
            try:
                data = _download_county_shapes(y)
            except requests.RequestException as e:
                print(f"  Download failed ({y}): {e}")
                continue
            if data:
                _COUNTY_SHAPES = _read_tiger_zip(data, ".shp")
                break
        else:
            print("  ERROR: Could not download the county outlines.")
            return None
    return _COUNTY_SHAPES


def counties_for_boxes(boxes) -> list[tuple[str, str]]:
    """[(fips, "Harris County, TX"), ...] for counties touching the boxes
    (with ~1 km to spare, since the outlines are simplified)."""
    shapes = county_shapes()
    if shapes is None:
        return []
    from shapely.geometry import box as shp_box
    area = unary_union([shp_box(w, s, e, n) for s, w, n, e in boxes]).buffer(0.01)
    hits = shapes[shapes.intersects(area)]
    from county_fips import _COUNTY_FIPS
    state_of = {f[:2]: st for (st, _), f in _COUNTY_FIPS.items()}
    out = []
    for _, row in hits.iterrows():
        geoid = str(row.get("GEOID"))
        st = state_of.get(geoid[:2], "")
        name = row.get("NAMELSAD") or row.get("NAME") or geoid
        out.append((geoid, f"{name}, {st.upper()}" if st else str(name)))
    return sorted(out)


def tiger_track_network(boxes, id_start=10**12):
    """
    TIGER/Line roads inside `boxes`, as (ways, nodes, counties, complete) in the
    same shape road_tracks.RoadNetwork takes from Overpass. Intersections are
    where road lines share a point, so overpasses stay unconnected. TIGER/Line
    has no one-way information, so every road is two-way.
    """
    counties = counties_for_boxes(boxes)
    if not counties:
        return [], {}, [], False
    from shapely.geometry import box as shp_box
    area = unary_union([shp_box(w, s, e, n) for s, w, n, e in boxes])
    ways, nodes, key_to_id = [], {}, {}
    complete = True
    wid = id_start
    for fips, name in counties:
        if fips not in _TIGER_ROADS:
            print(f"  TIGER/Line roads for {name} ({fips})")
            gdf, _ = _download_tiger_roads(fips)
            _TIGER_ROADS[fips] = gdf
        gdf = _TIGER_ROADS[fips]
        if gdf is None:
            complete = False
            continue
        try:
            idx = gdf.sindex.query(area, predicate="intersects")
            sub = gdf.iloc[sorted(set(int(i) for i in idx))]
        except Exception:
            sub = gdf[gdf.intersects(area)]
        for _, row in sub.iterrows():
            mtfcc = str(row.get("MTFCC", "S1400"))
            tags = {"highway": _TIGER_HIGHWAY.get(mtfcc, "road"), "oneway": "no",
                    "name": row.get("FULLNAME") or "", "MTFCC": mtfcc,
                    "tiger_width": _TIGER_WIDTHS.get(mtfcc, DEFAULT_WIDTH_FALLBACK)}
            for part in _geom_parts(row.geometry):
                ids = []
                for x, y in part.coords:
                    k = (round(x, 7), round(y, 7))
                    nid = key_to_id.get(k)
                    if nid is None:
                        nid = key_to_id[k] = len(key_to_id) + 1
                        nodes[nid] = (y, x)
                    if not ids or ids[-1] != nid:
                        ids.append(nid)
                if len(ids) >= 2:
                    ways.append({"id": wid, "tags": tags, "nodes": ids})
                    wid += 1
    return ways, nodes, [n for _, n in counties], complete


def fetch_ways_tiger(road_name: str, fips: str, state: str = None, label: str = "",
                     cross_names=(), junctions: bool = False, ramps: bool = False):
    """
    Download the TIGER/Line roads shapefile for one county (by FIPS code) and
    return a Layer of the features matching road_name or any of its aliases,
    projected to UTM like ways_to_projected_lines().

    Each feature's primary FULLNAME is checked, and so is the county's
    feature-names file, which lists TIGER's alternate names for the same road
    (e.g. a segment named "Rockville Pike" that is also "State Rte 355").

    cross_names: also return those streets (WGS84 lines in layer.cross), for
                 --from/--to clipping.
    junctions:   add a disc filling each intersection along the road.
    ramps:       add ramps (MTFCC S1630) connected to the road.

    Returns None if no matching features are found.
    Requires: geopandas, fiona (pip install geopandas fiona).
    """
    try:
        import geopandas  # noqa: F401
    except ImportError:
        print("\nERROR: TIGER/Line support requires geopandas.")
        print("  Install it with:  pip install geopandas fiona")
        sys.exit(1)

    label = label or f"county {fips}"
    print(f"  County FIPS: {fips}")

    # 1. Download the roads shapefile (newest available year).
    gdf, year = _download_tiger_roads(fips)
    if gdf is None:
        return None

    # Alternate names (feature-names file, same year). A bonus only: any
    # problem here falls back to primary names.
    fn = None
    try:
        fn_bytes = _download_tiger("FEATNAMES", fips, year)
        if fn_bytes:
            fn = _read_tiger_zip(fn_bytes, ".dbf", geometry=False)
            if fn is not None and not {"LINEARID", "FULLNAME"} <= set(fn.columns):
                fn = None
    except Exception as e:
        print(f"  (Skipping TIGER alternate names: {e})")

    # 2. Match names (each distinct name is checked once).
    mask, via_alt = _tiger_name_mask(gdf, fn, road_name, state, fips)
    matched = gdf[mask]

    if matched.empty:
        print(f"  No TIGER/Line features matched '{road_name}' in {label}.")
        print(f"  Tried aliases such as: {_variants_preview(road_name, state)}")
        return None

    names = sorted(matched["FULLNAME"].dropna().unique())
    shown = ", ".join(names[:6]) + (" ..." if len(names) > 6 else "")
    alt_note = f"; {via_alt} found via TIGER alternate names" if via_alt else ""
    print(f"  Found {len(matched)} TIGER/Line feature(s) matching '{road_name}' ({shown}{alt_note}).")

    # 3. Project to UTM (same logic as ways_to_projected_lines)
    all_lons = []
    for geom in matched.geometry:
        for part in _geom_parts(geom):
            all_lons.extend(x for x, y in part.coords)

    if not all_lons:
        print("  ERROR: No coordinate data in matched TIGER features.")
        return None

    avg_lon = sum(all_lons) / len(all_lons)
    utm_zone = int((avg_lon + 180) / 6) + 1
    epsg = f"EPSG:{32600 + utm_zone}"
    print(f"  Using projection: {epsg} (UTM zone {utm_zone}N)")

    transformer = Transformer.from_crs("EPSG:4326", epsg, always_xy=True)

    def _project(part):
        return LineString([transformer.transform(x, y) for x, y in part.coords])

    def _tags(row):
        # Synthesize a tags dict compatible with get_road_width()
        mtfcc = str(row.get("MTFCC", "S1400"))
        return {"tiger_width": _TIGER_WIDTHS.get(mtfcc, DEFAULT_WIDTH_FALLBACK), "MTFCC": mtfcc}

    lines_with_tags = []
    for _, row in matched.iterrows():
        tags = _tags(row)
        for part in _geom_parts(row.geometry):
            if len(part.coords) >= 2:
                lines_with_tags.append((_project(part), tags))

    if not lines_with_tags:
        return None

    layer = Layer(lines_with_tags, epsg, "tiger")

    # 4. Cross streets for --from/--to (kept in WGS84)
    for name in cross_names:
        cmask, _ = _tiger_name_mask(gdf, fn, name, state, fips)
        layer.cross[name] = [p for g in gdf[cmask].geometry for p in _geom_parts(g)]

    # 5. Ramps and junctions from neighbouring features in the same file
    if junctions or ramps:
        minx, miny, maxx, maxy = matched.total_bounds
        pad = 0.03 if ramps else 0.002          # degrees (~3 km / ~200 m)
        near = gdf.cx[minx - pad:maxx + pad, miny - pad:maxy + pad]
        near = near[~near.index.isin(matched.index)]
        others = []                              # (projected line, tags)
        for _, row in near.iterrows():
            tags = _tags(row)
            for part in _geom_parts(row.geometry):
                if len(part.coords) >= 2:
                    others.append((_project(part), tags))

        if ramps:
            added = _connected_ramps([l for l, _ in lines_with_tags],
                                     [(l, t) for l, t in others if t["MTFCC"] == "S1630"])
            for line, tags in added:
                layer.lines.append((line, dict(tags, _ramp="1")))
            if added:
                print(f"  Added {len(added)} connected ramp segment(s).")

        if junctions:
            road = [(l, t) for l, t in layer.lines]
            cross = [(l, t) for l, t in others if t["MTFCC"] not in _TIGER_MINOR]
            discs = _junction_discs_by_geometry(road, cross)
            layer.junctions.extend(discs)
            if discs:
                print(f"  Filled {len(discs)} intersection(s).")

    return layer


def ways_to_projected_lines(ways: list) -> tuple[list[LineString], str]:
    """
    Convert OSM ways to projected Shapely LineStrings.
    Auto-selects UTM zone based on centroid longitude.
    Returns (list of (LineString, tags), epsg_code).
    """
    # Collect all coords to find centroid lon for UTM zone selection
    all_lons = []
    for way in ways:
        for node in way.nodes:
            all_lons.append(float(node.lon))

    if not all_lons:
        print("ERROR: No node coordinates found in OSM response.")
        sys.exit(1)

    avg_lon = sum(all_lons) / len(all_lons)
    utm_zone = int((avg_lon + 180) / 6) + 1
    epsg = f"EPSG:{32600 + utm_zone}"  # Northern hemisphere (US)
    print(f"  Using projection: {epsg} (UTM zone {utm_zone}N)")

    transformer = Transformer.from_crs("EPSG:4326", epsg, always_xy=True)

    lines_with_tags = []
    for way in ways:
        coords = []
        try:
            for node in way.nodes:
                x, y = transformer.transform(float(node.lon), float(node.lat))
                coords.append((x, y))
        except Exception as e:
            print(f"  Warning: skipping way {way.id} — {e}")
        if len(coords) >= 2:
            lines_with_tags.append((LineString(coords), way.tags))

    return lines_with_tags, epsg


def _offset_buffer(line: "LineString", left_dist: float, right_dist: float):
    """
    Return a polygon covering the band from right_dist m on the right of the
    centerline to left_dist m on its left.

    Positive = outward from center, negative = that edge crosses to the other
    side of the centerline. E.g. leftwidth=8, rightwidth=-5 gives a strip from
    5 to 8 m left of the centerline (a sidewalk).

    Built from Shapely single-sided buffers, which replace the deprecated
    parallel_offset and need no edge-joining.
    """
    hi, lo = float(left_dist), -float(right_dist)   # signed offsets: + left, - right
    if hi < lo:
        hi, lo = lo, hi
    if hi == lo:
        return Polygon()

    def side(d):
        if d == 0:
            return Polygon()
        return line.buffer(d, single_sided=True, join_style=2, mitre_limit=5.0)

    if lo >= 0:
        band = side(hi).difference(side(lo))
    elif hi <= 0:
        band = side(lo).difference(side(hi))
    else:
        band = side(hi).union(side(lo))
    if not band.is_valid:
        band = band.buffer(0)
    return band


def build_road_polygon(
    lines_with_tags: list,
    extra_lanes: int = 0,
    left_width: float = None,
    right_width: float = None,
):
    """
    Buffer each segment by its individual road width, then dissolve into
    one or more unified polygon(s). Returns a Shapely geometry.

    left_width / right_width: if provided, override the symmetric half-width
    on each side (in metres from centerline).  Negative values pull the edge
    inward past the centerline (e.g. to depict a sidewalk).  --lanes extra
    width is added to the base half before these overrides are applied.
    """
    buffered = _buffer_lines(lines_with_tags, extra_lanes, left_width, right_width)
    if not buffered:
        print("ERROR: No valid geometries to buffer.")
        sys.exit(1)
    return _dissolve(buffered)


def _buffer_lines(lines_with_tags, extra_lanes=0, left_width=None, right_width=None) -> list:
    """Each segment buffered by its own road width (see build_road_polygon)."""
    buffered = []
    for line, tags in lines_with_tags:
        base_width = get_road_width(tags)
        if extra_lanes:
            base_width += extra_lanes * LANE_WIDTH
        base_half = base_width / 2.0

        # Resolve per-side distances (fall back to symmetric base_half)
        l_dist = left_width  if left_width  is not None else base_half
        r_dist = right_width if right_width is not None else base_half

        if l_dist == r_dist and l_dist > 0:
            # Symmetric — use the fast standard buffer
            poly = line.buffer(l_dist, cap_style=2, join_style=2, quad_segs=8)
        else:
            poly = _offset_buffer(line, l_dist, r_dist)

        buffered.append(poly)
    return buffered


def _dissolve(buffered):
    print(f"  Buffered {len(buffered)} segment(s), dissolving...")
    dissolved = unary_union(buffered)

    # Simplify slightly to reduce vertex count without losing shape
    dissolved = dissolved.simplify(0.5, preserve_topology=True)
    return dissolved


def polygon_to_wgs84(geometry, epsg: str):
    """Reproject geometry back to WGS84 (lon, lat) for KML output."""
    transformer = Transformer.from_crs(epsg, "EPSG:4326", always_xy=True)

    def reproject_coords(coords):
        result = []
        for x, y in coords:
            lon, lat = transformer.transform(x, y)
            result.append((lon, lat))
        return result

    from shapely.geometry import Polygon, MultiPolygon

    if geometry.geom_type == "Polygon":
        exterior = reproject_coords(geometry.exterior.coords)
        interiors = [reproject_coords(ring.coords) for ring in geometry.interiors]
        return Polygon(exterior, interiors)
    elif geometry.geom_type == "MultiPolygon":
        polys = []
        for geom in geometry.geoms:
            exterior = reproject_coords(geom.exterior.coords)
            interiors = [reproject_coords(ring.coords) for ring in geom.interiors]
            polys.append(Polygon(exterior, interiors))
        return MultiPolygon(polys)
    else:
        raise ValueError(f"Unexpected geometry type: {geometry.geom_type}")


def build_combined_polygon(
    layers: list,
    extra_lanes: int = 0,
    left_width: float = None,
    right_width: float = None,
    round_junctions: list = None,
):
    """
    Buffer and dissolve layers that can come from several sources, counties,
    states and trips. Lines that share a UTM zone are buffered together in that
    zone; different zones are buffered in their own zone (so widths stay
    accurate on a long multi-state search) and merged in WGS84. Each layer's
    extra polygons (junction fill, pavement outlines) are merged in too.
    Junctions whose fill couldn't be trimmed are added to `round_junctions`
    as (lon, lat, reason) if a list is given.

    Returns a WGS84 geometry.
    """
    by_epsg = defaultdict(list)
    polys_by_epsg = defaultdict(list)
    discs_by_epsg = defaultdict(list)
    for layer in layers:
        by_epsg[layer.epsg].extend(layer.lines)
        polys_by_epsg[layer.epsg].extend(layer.polys)
        discs_by_epsg[layer.epsg].extend(getattr(layer, "junctions", []))

    pieces = []
    n_trimmed = n_kept = 0
    for epsg in set(by_epsg) | set(polys_by_epsg) | set(discs_by_epsg):
        lines = by_epsg.get(epsg, [])
        if len(by_epsg) > 1:
            print(f"  {epsg}: {len(lines)} segment(s)")
        parts = []
        buffered = _buffer_lines(lines, extra_lanes, left_width, right_width) if lines else []
        if buffered:
            parts.append(_dissolve(buffered))
        extra = list(polys_by_epsg.get(epsg, []))
        if discs_by_epsg.get(epsg):
            left = []
            fills, t, k = trim_junction_fill(discs_by_epsg[epsg], buffered + extra, left)
            if round_junctions is not None and left:
                back = Transformer.from_crs(epsg, "EPSG:4326", always_xy=True)
                for x, y, why in left:
                    lon, lat = back.transform(x, y)
                    round_junctions.append((lon, lat, why))
            n_trimmed += t
            n_kept += k
            extra += fills
        if extra:
            parts.append(unary_union(extra).simplify(0.2, preserve_topology=True))
        projected = unary_union(parts) if parts else None
        if projected is None or projected.is_empty:
            continue
        projected = MultiPolygon(_polygon_parts(projected)) if projected.geom_type not in (
            "Polygon", "MultiPolygon") else projected
        pieces.append(polygon_to_wgs84(projected, epsg))

    if n_trimmed or n_kept:
        print(f"  Intersection fill trimmed to the roads at {n_trimmed} junction(s)"
              + (f"; {n_kept} left round (nothing to trim to, or the trim failed)"
                 + (", each marked with a pin in the KML." if round_junctions is not None else ".")
                 if n_kept else "."))
    if not pieces:
        print("ERROR: No valid geometries to buffer.")
        sys.exit(1)

    merged = pieces[0] if len(pieces) == 1 else unary_union(pieces)
    if merged.geom_type not in ("Polygon", "MultiPolygon"):
        merged = MultiPolygon(_polygon_parts(merged))
    return merged


def write_kml(geometry, road_name: str, place: str, output_path: str, source: str = "",
              notes: str = "", pins=None):
    """Write geometry to a KML file with styling. `pins` is an optional list
    of (lon, lat, description) for junctions left round, saved in their own
    folder."""
    kml = simplekml.Kml()
    kml.document.name = f"Road surface: {road_name}"
    description = f"{road_name}, {place}" if place else road_name
    if source:
        description += f"\nSource: {source}"
    if notes:
        description += f"\nNotes: {notes}"
    kml.document.description = description

    # Style: semi-transparent gray fill, dark outline
    style = simplekml.Style()
    style.polystyle.color = simplekml.Color.changealphaint(160, simplekml.Color.gray)
    style.polystyle.outline = 1
    style.linestyle.color = simplekml.Color.black
    style.linestyle.width = 1.5

    def add_polygon(poly: "Polygon", name: str):
        coords_exterior = [(lon, lat, 0) for lon, lat in poly.exterior.coords]
        inner_rings = [
            [(lon, lat, 0) for lon, lat in ring.coords]
            for ring in poly.interiors
        ]
        pm = kml.newpolygon(name=name)
        pm.outerboundaryis = coords_exterior
        if inner_rings:
            pm.innerboundaryis = inner_rings
        pm.style = style
        pm.altitudemode = simplekml.AltitudeMode.clamptoground

    if geometry.geom_type == "Polygon":
        add_polygon(geometry, road_name)
    elif geometry.geom_type == "MultiPolygon":
        for i, poly in enumerate(geometry.geoms, 1):
            add_polygon(poly, f"{road_name} (part {i})")
    else:
        raise ValueError(f"Cannot write geometry type: {geometry.geom_type}")

    if pins:
        folder = kml.newfolder(name=f"Junctions left round ({len(pins)})")
        folder.description = ("Intersection fill that couldn't be trimmed to the roads, "
                              "so the full circle was kept. Each pin is at the circle's center.")
        pin_style = simplekml.Style()
        pin_style.iconstyle.icon.href = "http://maps.google.com/mapfiles/kml/pushpin/red-pushpin.png"
        pin_style.iconstyle.scale = 0.9
        for i, (lon, lat, why) in enumerate(pins, 1):
            pt = folder.newpoint(name=f"Junction left round {i}", coords=[(lon, lat, 0)])
            pt.description = f"{why}\nCenter: {lat:.7f}, {lon:.7f}"
            pt.altitudemode = simplekml.AltitudeMode.clamptoground
            pt.style = pin_style

    kml.save(output_path)
    print(f"  Saved: {output_path}")


def strip_inner_boundaries(kml_path: str) -> int:
    """
    Remove all <innerBoundaryIs>...</innerBoundaryIs> blocks from a KML file
    in-place.  Returns the number of blocks removed.
    """
    import re

    with open(kml_path, "r", encoding="utf-8") as fh:
        text = fh.read()

    pattern = re.compile(
        r"\s*<innerBoundaryIs>.*?</innerBoundaryIs>",
        re.DOTALL | re.IGNORECASE,
    )
    cleaned, count = pattern.subn("", text)

    if count:
        with open(kml_path, "w", encoding="utf-8") as fh:
            fh.write(cleaned)
        print(f"  Stripped {count} <innerBoundaryIs> block(s) from {kml_path}")
    else:
        print(f"  No <innerBoundaryIs> blocks found in {kml_path}")

    return count


def summarize(geometry, road_name: str):
    """Print a brief summary of the result."""
    from shapely.geometry import MultiPolygon
    area_m2 = geometry.area if hasattr(geometry, "area") else sum(g.area for g in geometry.geoms)
    # area was computed in projected (meter) CRS before reprojection, so use
    # the projected version for reporting — recompute from WGS84 is inaccurate
    num_polys = 1 if geometry.geom_type == "Polygon" else len(geometry.geoms)
    print(f"\n  Road: {road_name}")
    print(f"  Polygons: {num_polys}")
    bounds = geometry.bounds  # (minx, miny, maxx, maxy) in WGS84
    print(f"  Bounding box (lon/lat): {bounds[0]:.5f},{bounds[1]:.5f} → {bounds[2]:.5f},{bounds[3]:.5f}")


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

SOURCE_LABELS = {"osm": "OSM", "tiger": "TIGER/Line"}

# Longest default filename (including the source tag and ".kml"). The source
# tag (_osm, _tiger, _osm_tiger) is always kept; the rest is shortened to fit.
MAX_FILENAME_LEN = 120


def _parse_sources(tokens: list[str], parser) -> tuple[list[str], str]:
    """
    Read --source. Returns (modes, xml_path) where modes is ["xml"], ["auto"],
    or a non-empty subset of ["osm", "tiger"] (always in that order).
    Accepts "osm,tiger", "tiger,osm", "osm tiger", "osm+tiger".
    """
    if tokens and tokens[0].strip().lower() == "xml":
        if len(tokens) < 2:
            parser.error(
                '--source xml requires a URL or file path, e.g.\n'
                '  --source xml "https://www.openstreetmap.org/api/0.6/way/12188784"'
            )
        return ["xml"], " ".join(tokens[1:]).strip()

    modes = [m for m in re.split(r"[,+\s]+", " ".join(tokens).strip().lower()) if m]
    if not modes:
        parser.error("--source needs a value (osm, tiger, auto, or xml <url-or-path>)")
    if "xml" in modes:
        parser.error("--source xml can't be combined with other sources")
    bad = [m for m in modes if m not in ("osm", "tiger", "auto")]
    if bad:
        parser.error(f"--source: invalid mode(s) {bad} (choose from osm, tiger, auto, xml)")
    if "auto" in modes:
        if len(set(modes)) > 1:
            parser.error(
                "--source auto already tries OSM and falls back to TIGER/Line; "
                "use --source osm,tiger to search both everywhere"
            )
        return ["auto"], ""
    return [m for m in ("osm", "tiger") if m in modes], ""


def _safe_name(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", s or "").strip("._")


def default_output_name(road_name: str, city: str, states: list, areas: list,
                        source_tags: list[str], clip: tuple = None) -> str:
    """
    <road>[_<city or county>]_<state(s)>_<source>.kml, e.g.
        Cathedral_Ave_NW_DC_tiger.kml
        I-95_MD_DE_PA_osm_tiger.kml
    A --from/--to stretch adds "<from>_to_<to>" after the road name.
    Every county is only named when there is exactly one (a multi-county route
    would blow past filename limits). The name is cut to MAX_FILENAME_LEN, but
    the source tag is never cut.
    """
    suffix = ("_" + "_".join(source_tags) if source_tags else "") + ".kml"
    parts = [_safe_name(road_name)]
    if clip:                                   # --from/--to stretch
        parts.append(f"{_safe_name(clip[0])}_to_{_safe_name(clip[1])}")
    counties = [a.county for a in areas if a.county]
    if city:
        parts.append(_safe_name(city))
    elif len(counties) == 1:
        parts.append(_safe_name(counties[0]))
    if len(states) == 1:
        parts.append(_safe_name(states[0].typed))
    elif len(states) > 1:
        parts.append("_".join((s.abbr or _safe_name(s.typed)).upper() for s in states))

    stem = "_".join(p for p in parts if p) or "road"
    budget = MAX_FILENAME_LEN - len(suffix)
    if len(stem) > budget:
        stem = stem[:budget].rstrip("._-") or "road"
    return stem + suffix


def _fetch_osm_for_area(road_name: str, city: str, area: SearchArea, wait_mode: bool):
    """Run the Overpass search for one planned area."""
    state = area.state.name
    fips = area.fips if area.county else None
    if area.state.abbr == "dc" or not area.county:
        return fetch_ways(road_name, city, "", state, wait_mode=wait_mode, fips=fips)
    return fetch_ways(road_name, "", area.county, state, wait_mode=wait_mode, fips=fips)


def _osm_lines_wgs84(ways) -> list:
    return [LineString([(float(n.lon), float(n.lat)) for n in w.nodes])
            for w in ways or [] if len(w.nodes) >= 2]


def _finish_output(layers, args, road_label, place, source_used, output):
    """Outlines (if wanted), buffer, write the KML, summarize."""
    pins = []
    road_poly_wgs84 = build_combined_polygon(
        layers,
        extra_lanes=args.lanes,
        left_width=args.leftwidth,
        right_width=args.rightwidth,
        round_junctions=pins,
    )
    write_kml(road_poly_wgs84, road_label, place, output, source_used, args.notes, pins)
    if args.strip_inner:
        strip_inner_boundaries(output)
    summarize(road_poly_wgs84, road_label)
    print(f"\nDone. Open {output} in Google Earth or any KML viewer.\n")
    return output


OUTLINE_MODES = ("on", "off", "both")


def _use_outlines(layers, args):
    mode = args.outlines
    if mode == "off":
        return
    ids = set().union(*[layer.way_ids for layer in layers]) if layers else set()
    if not ids:
        return
    print("\n  Looking for mapped pavement outlines (OSM area:highway)...")
    outlines = fetch_area_outlines(ids, args.wait)
    used = apply_outlines(layers, outlines, keep_lines=(mode == "both"))
    if not used:
        print("  None mapped here; using buffered centerlines.")
    elif mode == "both":
        print(f"  Combining {used} pavement outline(s) with the buffered centerlines.")
    else:
        print(f"  Using {used} pavement outline(s); buffered centerlines elsewhere.")


def build_parser():
    parser = argparse.ArgumentParser(
        description="Generate a KML road surface polygon from OpenStreetMap and/or "
                    "TIGER/Line data, from a road name or from GPS history."
    )
    parser.add_argument("--road",   default="",     help='Road name, e.g. "Main Street", "US-1", "Cathedral Ave NW". '
                                                          'Common aliases are searched automatically '
                                                          '(optional with --source xml if the XML has a single way)')
    parser.add_argument("--state",  default="",     help='US state(s), comma-delimited: names or postal codes, e.g. '
                                                          '"Texas" or "MD, VA, DC". Required except for --source xml and --track.')
    parser.add_argument("--city",   default="",     help='City name to narrow the OSM search (single --state only)')
    parser.add_argument("--county", default="",     help='County name(s), comma-delimited, e.g. "Harris County, Dallas County". '
                                                          'Each county goes with the listed state that has it; if '
                                                          'several listed states have it, qualify it: "Montgomery County (MD)". '
                                                          'States with no county listed are searched statewide.')
    parser.add_argument("--from", dest="clip_from", default="",
                        help='Start of the stretch to keep: a cross street ("Calvert St NW") or '
                             '"lat,lon". Use with --to.')
    parser.add_argument("--to", dest="clip_to", default="",
                        help='End of the stretch to keep: a cross street or "lat,lon". Use with --from.')
    parser.add_argument("--track", nargs="+", default=None, metavar="FILE",
                        help="Map GPS history instead of a named road: Google Maps Timeline exports "
                             "(Timeline.json / location-history.json, Takeout Records.json or "
                             "Semantic Location History files), GPX, KML or GeoJSON tracks.")
    parser.add_argument("--date", default=None,
                        help="With --track: day(s) to map — 2026-10-30, 2026-10, "
                             "2026-10-01..2026-10-31, or all.")
    parser.add_argument("--travel-modes", default="drive,walk,bike,other",
                        help="With --track: which trips to map (drive, walk, bike, other = mode unknown). "
                             "Flights, trains and ferries are always skipped. Default: all four.")
    parser.add_argument("--output", default="",     help='Output .kml filename (default: auto-generated, ending in '
                                                          '_osm, _tiger or _osm_tiger)')
    parser.add_argument("--notes",  default="",     help="Text added to the KML description")
    parser.add_argument("--lanes",  type=int, default=0,
                        help="Override/add extra lanes to default width estimate")
    parser.add_argument("--leftwidth",  type=float, default=None,
                        help="Distance (m) from centerline to left edge; "
                             "negative puts that edge on the other side of the centerline "
                             "(overrides default half-width)")
    parser.add_argument("--rightwidth", type=float, default=None,
                        help="Distance (m) from centerline to right edge; "
                             "negative puts that edge on the other side of the centerline "
                             "(overrides default half-width)")
    parser.add_argument("--junctions", action=argparse.BooleanOptionalAction, default=True,
                        help="Fill intersections along the road (default: on)")
    parser.add_argument("--ramps", action="store_true",
                        help="Also include ramps connected to the road (named-road searches; "
                             "--track follows the ramps you actually used)")
    parser.add_argument("--outlines", nargs="?", const="on", default="on", choices=OUTLINE_MODES,
                        type=str.lower, metavar="{on,off,both}",
                        help="Mapped pavement outlines (OSM area:highway; needs OSM). on (default): "
                             "use the outline where one exists and buffered centerlines elsewhere. "
                             "both: outlines AND every buffered centerline, combined. off: "
                             "buffered centerlines only (same as --no-outlines)")
    parser.add_argument("--no-outlines", dest="outlines", action="store_const", const="off",
                        help="Same as --outlines off")
    parser.add_argument("--wait",   action="store_true",
                        help="Keep retrying indefinitely if all mirrors are busy")
    parser.add_argument("--source", nargs="+", default=["auto"],
                        metavar="MODE",
                        help='Data source(s): "osm", "tiger", "osm,tiger" (both, combined into one '
                             'file), "auto" (OSM, falling back to TIGER/Line per county; default), '
                             'or "xml <url-or-path>" to bypass Overpass entirely and load a way '
                             'directly from OSM XML — an OSM API URL '
                             '(e.g. https://www.openstreetmap.org/api/0.6/way/12188784), an '
                             'openstreetmap.org way page URL, or a path to a local .xml file. '
                             'TIGER/Line needs --county, except in DC. --track always uses OSM.')
    parser.add_argument("--strip-inner", action="store_true",
                        help="Remove all <innerBoundaryIs> blocks from the output KML")
    parser.add_argument("--list-aliases", action="store_true",
                        help="Show the aliases that would be searched for --road, then exit "
                             "(no downloads)")
    parser.add_argument("--batch", default="", metavar="CSV",
                        help="Run every row of a CSV file (columns named like the options: road, "
                             "state, county, city, source, from, to, track, date, output, notes, ...). "
                             "Other options on the command line apply to every row.")
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.batch:
        return run_batch(args.batch, list(sys.argv[1:] if argv is None else argv))
    if args.track:
        return run_tracks(args, parser)
    return run_road(args, parser)


# ---------------------------------------------------------------------------
# Named road
# ---------------------------------------------------------------------------

def run_road(args, parser):
    road_name = args.road.strip()
    city      = args.city.strip()
    county    = args.county.strip()
    output    = args.output.strip()

    modes, osm_xml = _parse_sources(args.source, parser)
    xml_mode = modes == ["xml"]

    if not road_name and not osm_xml:
        print("ERROR: --road is required unless --source xml or --track is given.")
        sys.exit(1)

    # --- --from / --to ---
    clip_from, clip_to = args.clip_from.strip(), args.clip_to.strip()
    if bool(clip_from) != bool(clip_to):
        parser.error("--from and --to go together")
    try:
        from_pt, to_pt = parse_clip_point(clip_from), parse_clip_point(clip_to)
    except ValueError as e:
        parser.error(str(e))
    cross_names = [c for c, pt in ((clip_from, from_pt), (clip_to, to_pt)) if c and pt is None]
    if xml_mode and cross_names:
        parser.error("with --source xml, --from/--to must be lat,lon points")

    # --- States ---
    states = []
    if args.state.strip():
        try:
            states = _parse_states(args.state)
        except ValueError as e:
            if not xml_mode:
                print(f"ERROR: {e}")
                sys.exit(1)
            # --source xml only uses the state for the filename
            states = [StateInfo(None, args.state.strip(), args.state.strip())]

    if args.list_aliases:
        if not road_name:
            print("ERROR: --list-aliases needs --road.")
            sys.exit(1)
        for ctx in ([s.abbr for s in states if s.abbr] or [None]):
            print(road_aliases.describe(road_name, ctx))
            print()
        return None

    # --state is only needed to bound the Overpass/TIGER area search —
    # --source xml already identifies the exact way, so no state is required.
    if not xml_mode and not states:
        print(f"ERROR: --state is required for --source {','.join(modes)}.")
        sys.exit(1)
    if city and len(states) > 1:
        print("ERROR: --city can only be used with a single --state.")
        sys.exit(1)

    layers = []             # Layer objects
    used = set()            # sources that actually returned data
    areas = []
    cross_lines = defaultdict(list)     # cross street -> WGS84 lines

    # --- Direct OSM XML bypass (URL or local file) ---
    if xml_mode:
        print(f"\n{'='*55}")
        print(f"  Road to KML  —  direct OSM XML source")
        print(f"{'='*55}")
        xml_state = states[0].abbr if len(states) == 1 else None
        try:
            ways = fetch_ways_from_osm_xml(osm_xml, road_name, xml_state)
        except (RuntimeError, requests.RequestException, OSError) as e:
            print(f"\nERROR: {e}")
            sys.exit(1)

        if not road_name:
            first_tags = ways[0].tags
            road_name = first_tags.get("name") or first_tags.get("ref") or f"OSM_way_{ways[0].id}"
            print(f"  No --road given — using name from XML: '{road_name}'")

        lines, epsg = ways_to_projected_lines(ways)
        layers.append(Layer(lines, epsg, "osm"))
        used.add("osm")

    # --- OSM / TIGER searches ---
    else:
        try:
            areas = _plan_search_areas(states, county)
        except ValueError as e:
            print(f"ERROR: {e}")
            sys.exit(1)

        if "tiger" in modes:
            no_county = [a.state.name for a in areas if a.fips is None and not a.county]
            unresolved = [a for a in areas if a.fips is None and a.county]
            if no_county or unresolved:
                for a in unresolved:
                    try:
                        _resolve_county_fips(a.county, a.state.abbr)
                    except RuntimeError as e:
                        print(f"ERROR: {e}")
                if no_county:
                    print(f"ERROR: --source tiger requires --county for: {', '.join(no_county)}.")
                    print("  TIGER/Line shapefiles are distributed by county (DC needs no county).")
                    print("  Example: --county \"Travis County\" --state \"Texas\"")
                sys.exit(1)

        mode_label = ("OSM, falling back to TIGER/Line" if modes == ["auto"]
                      else " + ".join(SOURCE_LABELS[m] for m in modes))
        print(f"\n{'='*55}")
        print(f"  Road to KML  —  {road_name}")
        print(f"{'='*55}")
        print(f"  Source: {mode_label}")
        print(f"  Areas:  {'; '.join(_area_label(a, city) for a in areas)}")
        print(f"  Aliases: {_variants_preview(road_name, states[0].abbr)}")
        if clip_from:
            print(f"  Stretch: from {clip_from} to {clip_to}")
        for a in areas:
            hint = road_aliases.rename_hint(road_name, a.state.abbr, a.fips if a.county else None)
            if hint:
                print(f"  Note: {hint}")
                break

        seen_way_ids = set()
        for area in areas:
            label = _area_label(area, city)
            print(f"\n  --- {label} ---")

            got_osm = False
            if modes == ["auto"] or "osm" in modes:
                ways = _fetch_osm_for_area(road_name, city, area, args.wait)
                if ways:
                    got_osm = True
                    new = [w for w in ways if w.id not in seen_way_ids]
                    seen_way_ids.update(w.id for w in ways)
                    if new:
                        lines, epsg = ways_to_projected_lines(new)
                        layer = Layer(lines, epsg, "osm", way_ids={w.id for w in new})
                        add_osm_context(layer, args.junctions, args.ramps, args.wait)
                        layers.append(layer)
                        used.add("osm")
                    for name in cross_names:
                        print(f"  Looking up cross street '{name}'...")
                        cross_lines[name] += _osm_lines_wgs84(
                            _fetch_osm_for_area(name, city, area, args.wait))

            if "tiger" in modes or (modes == ["auto"] and not got_osm):
                if area.fips is None:
                    if area.county:
                        print(f"  No OSM result here, and '{area.county}' isn't in county_fips.py, "
                              "so there is no TIGER/Line fallback.")
                    else:
                        print("  No OSM result here, and no county for a TIGER/Line fallback "
                              "(add --county to enable it).")
                    continue
                if modes == ["auto"]:
                    print(f"  No OSM ways found in {label} — trying TIGER/Line...")
                layer = fetch_ways_tiger(road_name, area.fips, area.state.abbr, label,
                                         cross_names=cross_names, junctions=args.junctions,
                                         ramps=args.ramps)
                if layer is not None:
                    layers.append(layer)
                    used.add("tiger")
                    for name, lines in layer.cross.items():
                        cross_lines[name] += lines

    if not layers:
        print(f"\nERROR: No ways found for '{road_name}' from any source.")
        sys.exit(1)

    source_tags = [s for s in ("osm", "tiger") if s in used]
    source_used = "OSM XML (direct)" if xml_mode else " + ".join(SOURCE_LABELS[s] for s in source_tags)
    missing = [s for s in modes if s in SOURCE_LABELS and s not in used]
    if missing:
        print(f"\n  WARNING: {' and '.join(SOURCE_LABELS[s] for s in missing)} returned nothing; "
              f"the output uses {source_used} only.")
    print(f"  Source: {source_used}")

    # --- Clip to --from/--to ---
    if clip_from:
        def spec(text, pt):
            return ("point", pt, text) if pt else ("street", cross_lines.get(text, []), f"'{text}'")
        try:
            layers = [clip_layers(layers, spec(clip_from, from_pt), spec(clip_to, to_pt))]
        except ClipError as e:
            print(f"\nERROR: {e}")
            print("  Check the cross-street names (aliases are searched), or use lat,lon points.")
            sys.exit(1)

    # --- Pavement outlines (OSM) ---
    if "osm" in used or xml_mode:
        _use_outlines(layers, args)

    if not output:
        output = default_output_name(road_name, city, states, areas, source_tags,
                                     (clip_from, clip_to) if clip_from else None)

    if city:
        place = f"{city}, {states[0].name}"
    elif areas:
        place = "; ".join(_area_label(a) for a in areas)
    else:
        place = ", ".join(s.name for s in states)
    if clip_from:
        place = f"from {clip_from} to {clip_to}, {place}"
    return _finish_output(layers, args, road_name, place, source_used, output)


# ---------------------------------------------------------------------------
# GPS history (--track)
# ---------------------------------------------------------------------------

def build_network_query(boxes, highway_types) -> str:
    """Overpass query for all roads of the given types in each
    (south, west, north, east) box."""
    types = "|".join(sorted(set(highway_types)))
    lines = [f'  way["highway"~"^({types})$"]({s:.6f},{w:.6f},{n:.6f},{e:.6f});'
             for s, w, n, e in boxes]
    return ("[out:json][timeout:180];\n(\n" + "\n".join(lines) +
            "\n);\nout body;\n>;\nout skel qt;\n")


def fetch_track_network(boxes, highway_types, wait_mode=False, depth=0, budget=None,
                        failed=None):
    """
    Download the roads in `boxes`. If Overpass can't finish (timeout, out of
    memory), split the request in half and try each half, up to 8 extra
    requests per call. Returns (ways, nodes, complete) where complete is False
    if some part couldn't be downloaded; the boxes of those parts are added
    to `failed` if a list is given.
    """
    budget = budget if budget is not None else [8]
    data = overpass_json(build_network_query(boxes, highway_types),
                         wait_mode=wait_mode, return_errors=True)
    if data is None:
        if failed is not None:
            failed.extend(boxes)
        return [], {}, False
    if overpass_error(data):
        budget[0] -= 2
        if len(boxes) == 1 or depth >= 6 or budget[0] < 0:
            print("  WARNING: Overpass couldn't return the roads for one area even after "
                  "splitting; that stretch will be left out.")
            if failed is not None:
                failed.extend(boxes)
            return [], {}, False
        print(f"  Splitting this request into two smaller ones ({len(boxes)} boxes)...")
        half = len(boxes) // 2
        w1, n1, ok1 = fetch_track_network(boxes[:half], highway_types, wait_mode, depth + 1, budget, failed)
        w2, n2, ok2 = fetch_track_network(boxes[half:], highway_types, wait_mode, depth + 1, budget, failed)
        n1.update(n2)
        return w1 + w2, n1, ok1 and ok2
    ways, nodes = road_tracks.parse_overpass_network(data)
    return ways, nodes, True


class TrackRoads:
    """
    The OSM roads for a whole --track run, downloaded once. Every grid cell
    any trip passes through is fetched in a single pass (shared cells only
    once, with the road types of every trip that uses them), then each trip
    group takes the ways near its own cells from memory. Nothing is written
    to disk.
    """

    def __init__(self, trips, wait_mode=False):
        cell_types = defaultdict(set)
        for t in trips:
            for c in road_tracks.trip_cells(t):
                cell_types[c].update(road_tracks.NETWORK_TYPES[t.category])
        by_types = defaultdict(set)
        for c, ty in cell_types.items():
            by_types[frozenset(ty)].add(c)
        jobs = []
        for ty, cells in sorted(by_types.items(), key=lambda kv: -len(kv[1])):
            for batch in road_tracks.batch_boxes(road_tracks.cells_to_boxes(cells)):
                jobs.append((ty, batch))
        km2 = sum(road_tracks.box_area_km2(b) for _, batch in jobs for b in batch)
        print(f"\n  Downloading OSM roads for all trips at once: {len(jobs)} request(s), "
              f"{km2:.0f} km² in total")
        self.ways, self.nodes, self.missing = {}, {}, set()
        down = 0
        for i, (ty, batch) in enumerate(jobs, 1):
            if down >= 2 and not wait_mode:
                for _, rest in jobs[i - 1:]:
                    self._mark_missing(rest)
                print(f"  The OSM servers aren't answering; skipping the other {len(jobs) - i + 1} "
                      "request(s). Re-run with --wait to keep retrying.")
                break
            if len(jobs) > 1:
                print(f"  OSM request {i} of {len(jobs)}")
            failed = []
            w, n, _ = fetch_track_network(batch, ty, wait_mode, failed=failed)
            self._mark_missing(failed)
            for way in w:
                self.ways[way["id"]] = way
            self.nodes.update(n)
            down = down + 1 if (failed and not w) else 0
        self.way_cells = {}
        for wid, way in self.ways.items():
            pts = [self.nodes[n] for n in way["nodes"] if n in self.nodes]
            self.way_cells[wid] = road_tracks.line_cells(pts) if pts else set()
        print(f"  {len(self.ways)} OSM road way(s) downloaded"
              + (f"; {len(self.missing)} map cell(s) couldn't be downloaded." if self.missing else "."))

    def _mark_missing(self, boxes):
        d = road_tracks.CELL_DEG
        for s_, w_, n_, e_ in boxes:
            for r in range(round(s_ / d), round(n_ / d)):
                for c in range(round(w_ / d), round(e_ / d)):
                    self.missing.add((r, c))

    def for_cells(self, cells):
        """(ways, nodes, complete) for the roads in and next to `cells`."""
        near = road_tracks.dilate_cells(cells)
        ways = [w for wid, w in self.ways.items() if self.way_cells[wid] & near]
        ids = {n for w in ways for n in w["nodes"]}
        nodes = {n: self.nodes[n] for n in ids if n in self.nodes}
        return ways, nodes, not (cells & self.missing)


def _track_output_name(args, source_tags) -> str:
    if args.date and args.date.strip().lower() != "all":
        part = args.date.strip().replace("..", "_to_")
    else:
        part = _safe_name(re.sub(r"\.[^.]+$", "", args.track[0].replace("\\", "/").split("/")[-1]))
    stem = _safe_name(f"track_{part}") or "track"
    suffix = "_" + "_".join(source_tags or ["osm"]) + ".kml"
    return stem[:MAX_FILENAME_LEN - len(suffix)].rstrip("._-") + suffix


def _junction_polys(net, res, on):
    polys = []
    if on:
        for n, ws in net.junction_nodes(res.nodes, res.way_ids):
            disc = _junction_disc(net.xy[n], [get_road_width(net.way_tags[w]) for w in ws])
            if disc is not None:
                polys.append(disc)
    return polys


def _km(lines):
    return sum(l.length for l, _ in lines) / 1000.0


def _detoured(lines, trip):
    """Matched road far longer than the trip itself: usually a road missing
    from the map, so the matcher went around it."""
    return bool(lines) and _km(lines) > 1.5 * road_tracks.trip_length_km(trip) + 0.2


def _outside(lines, others, gap_m=20.0, min_len=30.0):
    """Parts of `lines` more than gap_m from every line in `others`."""
    if not others:
        return lines
    zone = unary_union([l for l, _ in others]).buffer(gap_m)
    out = []
    for line, tags in lines:
        for part in _geom_parts(line.difference(zone)):
            if part.length >= min_len:
                out.append((part, tags))
    return out


def run_tracks(args, parser):
    if args.road:
        parser.error("--track and --road can't be used together")
    modes, _ = _parse_sources(args.source, parser)
    if modes == ["xml"]:
        parser.error("--source xml can't be used with --track")
    if args.clip_from or args.clip_to:
        parser.error("--from/--to apply to --road searches (a track is already clipped to where you went)")
    travel = [m.strip().lower() for m in re.split(r"[,\s]+", args.travel_modes) if m.strip()]
    bad = [m for m in travel if m not in road_tracks.CATEGORIES]
    if bad:
        parser.error(f"--travel-modes: unknown {bad} (choose from {', '.join(road_tracks.CATEGORIES)})")
    if args.state or args.county or args.city:
        print("  Note: --state/--county/--city are ignored with --track (the track sets the area).")

    use_osm = modes != ["tiger"]
    tiger_all = "tiger" in modes                 # tiger, or osm,tiger
    tiger_fill = modes == ["auto"]               # TIGER/Line where OSM has nothing
    have_gpd = importlib.util.find_spec("geopandas") is not None
    if tiger_all and not have_gpd:
        print("\nERROR: TIGER/Line support requires geopandas.")
        print("  Install it with:  pip install geopandas fiona")
        sys.exit(1)
    if tiger_fill and not have_gpd:
        tiger_fill = False
        print("  Note: TIGER/Line fallback is off because geopandas isn't installed.")

    label = {("auto",): "OSM, with TIGER/Line where OSM has nothing", ("osm",): "OSM",
             ("tiger",): "TIGER/Line", ("osm", "tiger"): "OSM + TIGER/Line"}[tuple(modes)]
    print(f"\n{'='*55}")
    print(f"  Road to KML  —  GPS track{' ' + args.date if args.date else ''}")
    print(f"{'='*55}")
    print(f"  Source: {label}")
    try:
        trips = road_tracks.load_trips(args.track, args.date, travel)
    except (ValueError, OSError) as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    if not trips:
        print("ERROR: No trips found for those dates and travel modes.")
        sys.exit(1)

    by_cat = defaultdict(float)
    for t in trips:
        by_cat[t.category] += road_tracks.trip_length_km(t)
    print(f"  {len(trips)} trip(s): " +
          ", ".join(f"{c} {km:.1f} km" for c, km in sorted(by_cat.items())))

    layers, used = [], set()
    total_gaps = 0
    unmatched_trips = 0
    osm_roads = TrackRoads(trips, args.wait) if use_osm else None
    groups = road_tracks.group_trips(trips)
    for gi, group in enumerate(groups, 1):
        cells = set().union(*[road_tracks.trip_cells(t) for t in group])
        boxes = road_tracks.cells_to_boxes(cells)
        epsg = road_tracks.utm_epsg([p.lon for t in group for p in t.points])
        first = road_tracks.local_time(group[0].points[0].t) if group[0].points[0].t else None
        when = f", from {first:%Y-%m-%d %H:%M}" if first else ""
        print(f"\n  --- Trip group {gi} of {len(groups)} ({len(group)} trip(s){when}) ---")

        # --- OSM (from the one download made for the whole run)
        osm_res, osm_nets = {}, {}
        if osm_roads is not None:
            ways, nodes, complete = osm_roads.for_cells(cells)
            print(f"  {len(ways)} OSM road way(s) around the track.")
            if not ways:
                if complete:
                    b = boxes[0]
                    print("  WARNING: Overpass answered but found no roads for these trips "
                          f"(first area: south {b[0]}, west {b[1]}, north {b[2]}, east {b[3]}).")
                else:
                    print("  WARNING: no OSM road data for these trips (Overpass didn't answer).")
            else:
                if not complete:
                    print("  WARNING: part of the OSM road data is missing.")
                for t in group:
                    net = osm_nets.get(t.category)
                    if net is None:
                        net = osm_nets[t.category] = road_tracks.RoadNetwork(ways, nodes, t.category, epsg)
                    osm_res[id(t)] = (net, road_tracks.match_trip(net, t))

        # --- TIGER/Line, for every trip or only where OSM came up short
        need_tiger = []
        for t in group:
            r = osm_res.get(id(t))
            off_road = r is not None and r[1].skipped >= max(3, 0.1 * len(t.points))
            if tiger_all or (tiger_fill and (r is None or not r[1].lines or r[1].breaks
                                             or off_road or _detoured(r[1].lines, t))):
                need_tiger.append(t)
        tiger_res, tiger_nets = {}, {}
        if need_tiger:
            why = "" if tiger_all else " to fill what OSM couldn't match"
            print(f"  Using TIGER/Line{why}...")
            tcells = set().union(*[road_tracks.trip_cells(t) for t in need_tiger])
            tways, tnodes, counties, tcomplete = tiger_track_network(road_tracks.cells_to_boxes(tcells))
            if counties:
                print(f"  Counties: {'; '.join(counties)}")
            print(f"  {len(tways)} TIGER/Line road segment(s) around the track.")
            if not tcomplete:
                print("  WARNING: some TIGER/Line data couldn't be downloaded.")
            if tways:
                for t in need_tiger:
                    net = tiger_nets.get(t.category)
                    if net is None:
                        net = tiger_nets[t.category] = road_tracks.RoadNetwork(tways, tnodes, t.category, epsg)
                    tiger_res[id(t)] = (net, road_tracks.match_trip(net, t))

        # --- results per trip
        for t in group:
            stamp = road_tracks.local_time(t.points[0].t).strftime("%Y-%m-%d %H:%M") if t.points[0].t else "untimed"
            parts = []
            o = osm_res.get(id(t))
            g = tiger_res.get(id(t))
            o_lines = o[1].lines if o else []
            if (tiger_fill and o_lines and g and g[1].lines and _detoured(o_lines, t)
                    and not _detoured(g[1].lines, t)):
                print(f"  {stamp}  OSM went the long way round here (a road missing from OSM?); "
                      "using TIGER/Line for this trip.")
                o, o_lines = None, []
            if o and o_lines:
                layers.append(Layer(o_lines, epsg, "osm", way_ids=o[1].way_ids,
                                    junctions=_junction_polys(o[0], o[1], args.junctions)))
                used.add("osm")
                parts.append(f"{sum(l.length for l, _ in o_lines) / 1000:.1f} km OSM")
            if g and g[1].lines:
                t_lines = g[1].lines if tiger_all or not o_lines else _outside(g[1].lines, o_lines)
                if t_lines:
                    keep = unary_union([l for l, _ in t_lines]).buffer(1.0)
                    polys = [p for p in _junction_polys(g[0], g[1], args.junctions) if p.intersects(keep)]
                    layers.append(Layer(t_lines, epsg, "tiger", junctions=polys))
                    used.add("tiger")
                    parts.append(f"{sum(l.length for l, _ in t_lines) / 1000:.1f} km TIGER/Line"
                                 + ("" if tiger_all or not o_lines else " filling gaps"))
            # a stretch only counts as a gap if no source covered it
            gaps = min([r[1].breaks for r in (o, g) if r] or [0])
            total_gaps += gaps
            if not parts:
                unmatched_trips += 1
            note = f", {gaps} gap(s)" if gaps and parts else ""
            print(f"  {stamp}  {t.category:5}  {road_tracks.trip_length_km(t):6.1f} km tracked -> "
                  + (" + ".join(parts) if parts else "nothing matched") + note)

    if not layers:
        print("\nERROR: Nothing could be matched to roads."
              + (" The map servers may be busy: re-run with --wait." if use_osm else ""))
        sys.exit(1)
    if unmatched_trips:
        print(f"\n  WARNING: {unmatched_trips} trip(s) couldn't be matched to any road"
              + (" (re-run with --wait if the map servers were busy)." if use_osm else "."))
    if total_gaps:
        print(f"\n  Note: {total_gaps} gap(s) where a trip couldn't be followed on the road "
              "network (missing road, tunnel, or GPS jump); those stretches are left out.")

    if "osm" in used:
        _use_outlines(layers, args)
    source_tags = [x for x in ("osm", "tiger") if x in used]
    output = args.output.strip() or _track_output_name(args, source_tags)
    label = f"track {args.date}" if args.date else "track"
    place = ", ".join(sorted({f"{c}" for c in by_cat})) + " trips"
    sources = " + ".join(SOURCE_LABELS[x] for x in source_tags)
    return _finish_output(layers, args, label, place, f"{sources} (map-matched GPS track)", output)


# ---------------------------------------------------------------------------
# --batch
# ---------------------------------------------------------------------------

BATCH_VALUE_COLUMNS = {
    "road": "--road", "state": "--state", "county": "--county", "city": "--city",
    "source": "--source", "output": "--output", "notes": "--notes", "lanes": "--lanes",
    "leftwidth": "--leftwidth", "rightwidth": "--rightwidth", "from": "--from", "to": "--to",
    "track": "--track", "date": "--date", "travel_modes": "--travel-modes",
}
BATCH_FLAG_COLUMNS = {   # column -> (flag when true, flag when false)
    "strip_inner": ("--strip-inner", None), "wait": ("--wait", None),
    "ramps": ("--ramps", None), "junctions": ("--junctions", "--no-junctions"),
    "outlines": ("--outlines", "--no-outlines"),
}
_TRUE = {"1", "y", "yes", "true", "x", "on"}
_FALSE = {"0", "n", "no", "false", "off"}


class _Tee:
    """Pass output through while remembering the last error line."""

    def __init__(self, stream):
        self.stream, self.last_error = stream, ""

    def write(self, text):
        for line in text.splitlines():
            if "ERROR" in line or "error:" in line:
                self.last_error = line.strip()
        return self.stream.write(text)

    def flush(self):
        self.stream.flush()


def _batch_row_args(row: dict) -> list[str]:
    tokens = []
    for col, value in row.items():
        value = (value or "").strip()
        if not value:
            continue
        if col in BATCH_VALUE_COLUMNS:
            flag = BATCH_VALUE_COLUMNS[col]
            if col == "source":
                tokens += [flag] + value.split(None, 1)
            elif col == "track":
                tokens += [flag] + [v.strip() for v in value.split(";") if v.strip()]
            else:
                tokens += [flag, value]
        elif col in BATCH_FLAG_COLUMNS:
            on, off = BATCH_FLAG_COLUMNS[col]
            v = value.lower()
            if col == "outlines" and v == "both":
                tokens += ["--outlines", "both"]
            elif v in _TRUE:
                tokens.append(on)
            elif v in _FALSE and off:
                tokens.append(off)
    return tokens


def run_batch(path: str, argv: list[str]):
    """Run each CSV row as its own job; options given alongside --batch apply
    to every row, and row values override them."""
    base, skip = [], False
    for i, tok in enumerate(argv):
        if skip:
            skip = False
            continue
        if tok == "--batch":
            skip = True
            continue
        if tok.startswith("--batch="):
            continue
        base.append(tok)

    try:
        with open(path, newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            norm = lambda h: re.sub(r"[\s-]+", "_", (h or "").strip().lstrip("-").lower())
            rows = [{norm(k): v for k, v in r.items() if k is not None} for r in reader]
            headers = [norm(h) for h in (reader.fieldnames or [])]
    except OSError as e:
        print(f"ERROR: can't read {path}: {e}")
        sys.exit(1)

    known = set(BATCH_VALUE_COLUMNS) | set(BATCH_FLAG_COLUMNS)
    ignored = [h for h in headers if h and h not in known]
    if ignored:
        print(f"  Note: ignoring column(s) {', '.join(ignored)}.")

    results = []
    for line_no, row in enumerate(rows, start=2):
        values = [(v or "").strip() for v in row.values()]
        if not any(values) or values[0].startswith("#"):
            continue
        label = row.get("road") or row.get("track") or f"row {line_no}"
        print(f"\n######## Row {line_no}: {label} ########")
        tee_out, tee_err = _Tee(sys.stdout), _Tee(sys.stderr)
        old = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = tee_out, tee_err
        try:
            out = main(base + _batch_row_args(row))
            results.append((line_no, label, "OK", out or ""))
        except SystemExit as e:
            msg = tee_out.last_error or tee_err.last_error or f"exit code {e.code}"
            results.append((line_no, label, "FAILED", msg))
        except Exception as e:      # keep going with the other rows
            results.append((line_no, label, "FAILED", f"{type(e).__name__}: {e}"))
        finally:
            sys.stdout, sys.stderr = old

    print(f"\n{'='*55}\n  Batch summary: {path}\n{'='*55}")
    for line_no, label, status, detail in results:
        print(f"  Row {line_no:<4} {status:6}  {label}  ->  {detail}")
    failed = sum(1 for r in results if r[2] != "OK")
    print(f"\n  {len(results) - failed} succeeded, {failed} failed.")
    if failed:
        sys.exit(1)
    return None


if __name__ == "__main__":
    main()
