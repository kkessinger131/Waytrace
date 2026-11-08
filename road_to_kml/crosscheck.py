#!/usr/bin/env python3
"""
crosscheck.py OUT_DIR

Runs road_to_kml.py on a fixed set of jobs, offline, with the fake Overpass /
Nominatim / Census servers from test_road_to_kml.py, and saves what it made:

    OUT_DIR/manifest.json        one entry per job: name, argv, exit code, output name
    OUT_DIR/<name>.kml           the KML road_to_kml.py wrote
    OUT_DIR/inputs/...           GPS files the --track jobs read

RoadKit's CrossCheckTests (the Swift port, in the Waytrace app) then runs the
same jobs through its own engine and checks that both drew the same road
surface. CI runs the pair on every push, so the two stay in step.
"""
import json
import math
import os
import shutil
import sys
import tempfile
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_road_to_kml as T  # noqa: E402  (installs nothing until asked)


def timeline(path):
    """A drive along Cathedral then up Connecticut, Timeline-style (sparse).
    The same file test_road_to_kml.TrackEndToEndTests.timeline() writes."""
    route = T.walk_points([(0, 0), (0, 3), (4, 3)], 250)
    t0 = datetime(2026, 10, 30, 9, 0)
    pts = [{"point": f"{a:.7f}°, {b:.7f}°", "time": (t0 + timedelta(seconds=30 * i)).isoformat() + ".000-04:00"}
           for i, (a, b) in enumerate(route)]
    data = {"semanticSegments": [
        {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:30:00.000-04:00",
         "activity": {"start": {"latLng": pts[0]["point"]}, "end": {"latLng": pts[-1]["point"]},
                      "topCandidate": {"type": "IN_PASSENGER_VEHICLE"}}},
        {"startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
         "timelinePath": pts}]}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh)


def records(path):
    """A Waytrace recording exported as Records.json: a drive every 15 s
    (Cathedral, Connecticut, Porter), then a walk back down Reno Road, with
    accuracy and the motion coprocessor's label on every point. The wobble
    is a fixed pattern (no random numbers), so both engines read the same file."""
    def leg(cells, step, start, secs, mode, acc):
        out = []
        for i, (lat, lon) in enumerate(T.walk_points(cells, step)):
            wob = 4.0 * math.sin(i * 1.7)
            out.append((start + timedelta(seconds=secs * i),
                        lat + wob * T.M_LAT, lon + 0.6 * wob * T.M_LON, mode, acc))
        return out
    t0 = datetime(2026, 10, 30, 14, 0)
    pts = leg([(0, 0), (0, 3), (4, 3), (4, 5)], 160, t0, 15, "IN_VEHICLE", 6.0)
    pts += leg([(4, 4), (1, 4)], 20, pts[-1][0] + timedelta(minutes=12), 15, "WALKING", 9.0)
    locs = []
    for t, lat, lon, mode, acc in pts:
        stamp = t.isoformat(timespec="milliseconds") + "-04:00"
        locs.append({"latitudeE7": round(lat * 1e7), "longitudeE7": round(lon * 1e7), "timestamp": stamp,
                     "accuracy": acc,
                     "activity": [{"timestamp": stamp, "activity": [{"type": mode, "confidence": 100}]}]})
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"locations": locs}, fh)


a, b = T.ll(1, 3), T.ll(2, 3)
CONN = ["--road", "Connecticut Ave NW", "--state", "DC"]
JOBS = [
    # name, argv, input file the job needs (or None)
    ("alias_outline", ["--road", "Conn Ave NW", "--state", "DC", "--source", "osm", "--no-junctions"], None),
    ("outline_both", ["--road", "Conn Ave NW", "--state", "DC", "--source", "osm", "--no-junctions",
                      "--outlines", "both"], None),
    ("junctions", CONN + ["--source", "osm", "--no-outlines"], None),
    ("ramps", ["--road", "I-95", "--state", "DC", "--source", "osm", "--ramps", "--no-outlines"], None),
    ("old_name", ["--road", "Lee Hwy", "--state", "DC", "--source", "osm", "--no-outlines"], None),
    ("clip_streets", CONN + ["--source", "osm", "--from", "Macomb St NW", "--to", "Ordway St NW",
                             "--no-outlines"], None),
    ("clip_points", CONN + ["--source", "osm", "--from", f"{a[0]},{a[1]}", "--to", f"{b[0]},{b[1]}",
                            "--no-outlines"], None),
    ("widths", ["--road", "Reno Rd NW", "--state", "DC", "--source", "osm", "--lanes", "1",
                "--leftwidth", "6", "--rightwidth", "-2", "--no-junctions", "--no-outlines"], None),
    ("tiger_dc", ["--road", "Cathedral Ave NW", "--state", "DC", "--source", "tiger"], None),
    ("tiger_featnames", ["--road", "MD 355", "--state", "MD, DC", "--county", "Montgomery County",
                         "--source", "osm,tiger", "--no-outlines"], None),
    ("tiger_clip", CONN + ["--source", "tiger", "--from", "Macomb St NW", "--to", "Ordway St NW"], None),
    ("no_such_street", CONN + ["--source", "osm", "--from", "Nowhere St NW", "--to", "Ordway St NW"], None),
    ("track", ["--track", "Timeline.json", "--date", "2026-10-30"], "Timeline.json"),
    ("track_tiger", ["--track", "Timeline.json", "--date", "2026-10-30", "--source", "tiger"], "Timeline.json"),
    ("track_both", ["--track", "Timeline.json", "--date", "2026-10-30", "--source", "osm,tiger"], "Timeline.json"),
    ("recording", ["--track", "Records.json", "--date", "2026-10-30"], "Records.json"),
    ("recording_walk", ["--track", "Records.json", "--date", "2026-10-30", "--travel-modes", "walk",
                        "--no-outlines"], "Records.json"),
]
MAKERS = {"Timeline.json": timeline, "Records.json": records}


def main(out_dir):
    out_dir = os.path.abspath(out_dir)
    os.makedirs(os.path.join(out_dir, "inputs"), exist_ok=True)
    for name, make in MAKERS.items():
        make(os.path.join(out_dir, "inputs", name))
    T.install_fakes()
    manifest, old = [], os.getcwd()
    for name, argv, needs in JOBS:
        work = tempfile.mkdtemp(prefix=f"xc_{name}_")
        os.chdir(work)
        try:
            if needs:
                shutil.copy(os.path.join(out_dir, "inputs", needs), needs)
            code, text, result = T.run_main(argv)
            entry = {"name": name, "argv": argv, "input": needs, "code": code, "output": result}
            if code == 0 and result:
                shutil.copy(result, os.path.join(out_dir, f"{name}.kml"))
            manifest.append(entry)
            print(f"{name:16} exit {code}  {result or ''}")
            if code not in (0, 1):
                print(text)
        finally:
            os.chdir(old)
            shutil.rmtree(work, ignore_errors=True)
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
