# Waytrace

An iPhone app that records everywhere you go: press **RECORD**, put the phone
away, press **STOP** when you're done (or leave it running for days). It
replaces two workflows:

- **Photo EXIF → KML.** Every point has what a photo's GPS EXIF has (time,
  position, accuracy, altitude, speed, direction of travel), with no photos to
  take. Export → **KML** gives the same line-plus-point-markers file.
- **Google Timeline → `road_to_kml.py`.** road_to_kml.py is built into the app
  (the **Roads** tab, and **Map roads traveled** on any recording), so the road
  surfaces come out as KML on the phone. Export → **Records.json** still works
  with the Python script on a computer. A recording has a point every 15 s
  instead of Timeline's one a minute, plus each point's real accuracy and
  travel mode.

Targets iOS 17 and later, so it runs on an iPhone 11 (which runs iOS 26 and 27).

---

## Build and install

**No Mac?** Follow [INSTALL_WITHOUT_MAC.md](INSTALL_WITHOUT_MAC.md). GitHub
builds the app on a cloud Mac, and Sideloadly installs it from a Windows PC.

**With a Mac (Xcode 26 or later):**

1. Unzip, then double-click **`Waytrace.xcodeproj`**.
2. Select the **Waytrace** target → **Signing & Capabilities**:
   - **Team:** your Apple ID. A free account works; add it under Xcode ›
     Settings › Accounts.
   - **Bundle Identifier:** change `com.example.waytrace` to something unique,
     e.g. `com.yourname.waytrace`.
3. Plug in the iPhone and pick it as the run destination. If asked, turn on
   **Developer Mode** on the phone (Settings › Privacy & Security › Developer
   Mode) and restart it.
4. Press **Run** (⌘R). The first time, the phone may ask you to trust the
   developer under Settings › General › VPN & Device Management.

With a free Apple ID, the app stops opening after **7 days**; press Run again
to reinstall it (your recordings are kept). A paid developer account
($99/year) makes an install last a year.

**If the project won't open:** install XcodeGen (`brew install xcodegen`),
delete `Waytrace.xcodeproj`, and run `xcodegen` in this folder.
Alternatively, create a new iOS App project (SwiftUI) named Waytrace and
delete its template Swift files. Then drag in the `Waytrace` folder and set
the build settings **Info.plist File** = `Waytrace/Info.plist`, **Generate
Info.plist File** = No, **iOS Deployment Target** = 17.0, **Swift Language
Version** = 5, and **Default Actor Isolation** = nonisolated.

---

## First run

1. Press **RECORD** and allow location access.
2. When asked again, choose **Change to Always Allow**. Recording works with
   "While Using", but "Always" lets iOS restart the app and continue the
   recording if it ever gets closed in the background.
3. Keep **Precise Location** on.
4. At the first **STOP**, allow **Motion & Fitness**. That lets each point be
   labelled walking, running, cycling, driving or stationary.

A blue location indicator shows in the status bar while recording. Don't
swipe the app away in the app switcher, since that ends the recording until
you open it again. After a phone restart, open the app once and it carries on
in the same file.

---

## How points are chosen

| Rule | Default |
|---|---|
| One save attempt every | 15 s |
| Skip if within this distance of the **last saved** point | 20 m |
| Skip if accuracy is worse than | ±50 m |
| Drift guard: also skip unless the move exceeds the fix's own accuracy | on |
| New file at local midnight | on |

All of these are in Settings (gear icon) and apply at the next RECORD.

- **Background.** iOS doesn't allow true background daemons. Instead, the app
  uses the background-location mode, which keeps it alive only while
  location updates run.
- **Why it's lightweight.** Core Location has a 5 m distance filter, so while
  you're still the app isn't woken at all. While you move it gets about one
  fix a second and does a single comparison per fix.
- **The save attempt.** Each attempt uses the newest fix, or a fix from the
  previous 3 s if that one is more accurate. Saving appends one ~150-byte line
  to a CSV.
- **Battery.** The GPS stays on while recording, as in any fitness tracker.
  That GPS is the main battery cost, so test a full day before relying on it.
- **No road snapping.** The activity type is `.other`, so a walk across a
  plaza or field is recorded as walked.
- **Drift guard.** Indoors, wifi positions (±30–65 m) wander more than 20 m
  while you sit still. In testing, the guard removed about half of that
  drift; the motion labels catch the rest (see KML below). Outdoors, with
  ±3–10 m GPS, the 20 m rule applies exactly. Turn it off in Settings to use
  only the 20 m rule.
- **Interruptions.** If recording is interrupted (app killed, phone off), it
  resumes in the same file with a new *segment* number. Exports break the
  line there instead of drawing a straight jump across the gap.

Your files are in the **Files** app under On My iPhone › Waytrace:
`Tracks/` holds the recordings and `Exports/` the latest exports.

---

## Exports

Open a recording and tap **Export…**, or use **Export all** (top left) for
every recording combined.

| Format | Use it for |
|---|---|
| **KML** | Google Earth / My Maps. A red line, plus a marker per point; tap one to see its time, accuracy, altitude, speed, course and activity. Points labelled *stationary* (usually indoor drift) go in a hidden "Stationary" folder and are left out of the line. |
| **Records.json** | `road_to_kml.py --track`. Google Takeout's Records.json format, which `road_tracks.py` already reads, with per-point accuracy and travel mode. |
| **GPX** | Any GPS tool, and `exiftool -geotag` if you ever want to geotag photos from the track. Accuracy, speed and course are in `<extensions>`. |
| **CSV** | The raw recording, one row per point. |

### Using the Records.json with road_to_kml.py

```
python road_to_kml.py --track 2026-11-06_08-12-03_Records.json --date 2026-11-06
python road_to_kml.py --track waytrace_all_Records.json --date 2026-11 --travel-modes walk
```

How `road_tracks.py` treats this file:

- **Accuracy.** Each point's real accuracy sets how far the matcher looks for
  a road. A ±5 m GPS point uses the 8 m minimum instead of the 35 m assumed for
  Timeline path points, so parallel streets and plaza paths are told apart
  better.
- **Accuracy cutoff.** Points less accurate than ±40 m are dropped by the
  script (its `raw_max_acc`).
- **Travel modes.** automotive → `IN_VEHICLE` (drive), walking/running →
  `WALKING`/`RUNNING` (walk), cycling → `ON_BICYCLE` (bike).
- **Stationary points.** These become `STILL`, which the script drops. A short
  stop *between* two points of the same mode (a crosswalk, a red light) takes
  that mode instead, so the trip isn't split there.
- **Unlabelled points.** Points with no motion label have no mode and count as
  "other" unless a neighbouring point sets one.
- **Times.** Times are written with your UTC offset (`-05:00`), so `--date`
  picks days as you lived them.

Each point looks like this (`velocity` m/s, `heading` degrees true; the
`confidence` of 100 is a placeholder, since Core Motion's own confidence
isn't stored):

```json
{
  "accuracy": 4.7,
  "activity": [{"activity": [{"confidence": 100, "type": "WALKING"}],
                "timestamp": "2026-11-06T08:12:45.120-05:00"}],
  "altitude": 52.3, "heading": 271.0, "headingAccuracy": 12.0,
  "latitudeE7": 389123456, "longitudeE7": -770456789,
  "timestamp": "2026-11-06T08:12:45.120-05:00",
  "velocity": 1.42, "velocityAccuracy": 0.3, "verticalAccuracy": 3.9
}
```

### Things to know

- **Direction is direction of travel** (GPS course), the same as EXIF
  `GPSDestBearing`. A pocketed phone can't give a meaningful equivalent of EXIF
  `GPSImgDirection` (where the camera pointed), so that isn't recorded.
- **Core Motion's "automotive" includes buses and trains.** A train ride is
  labelled as driving and road_to_kml will try to match it to roads; use
  `--date` or trim the file for those days.
- **Motion labels are filled in when you press STOP** (and at midnight for
  day-split files) from the iPhone's own motion history. That history only
  goes back 7 days. If a recording missed its labels, open it and tap **Fill
  in walking / driving labels** within the week.

## Roads (road_to_kml.py in the app)

The **Roads** tab is road_to_kml.py and its browser interface, ported to Swift
(the `RoadKit` package). Everything the script does runs on the phone: OSM
(Overpass, with the same mirror list, retries and mirror tally), TIGER/Line
county downloads including alternate names, aliases, intersection fill and
trimming, ramps, pavement outlines, `--from`/`--to` stretches, GPS-history map
matching and batches. It needs a network connection for the map data.

- **GPS history**, **Road**, **OSM way** and **Batch** are the same forms, in the
  same order, as the browser UI, with the same options. The pin buttons pick a `--from`/`--to`
  point on a map.
- **GPS history** takes Waytrace recordings (**Add a recording**) and any file
  the script reads: Timeline.json / location-history.json, Takeout
  Records.json and Semantic Location History, GPX, KML, GeoJSON.
- **Map roads traveled** on a recording's page runs GPS history on that
  recording alone, with the GPS history tab's source and surface options.
- **Run** shows the live log (cancel any time), the result on a map (Streets
  or Satellite, red pins for junctions left round) and share buttons for the
  KML. **Output files** lists every KML written, to show on the map, share or
  delete.
- **Same run from a terminal** shows the matching `python road_to_kml.py ...`
  command, so a run can be repeated on the computer. Batches save and open as
  the same CSV files the script reads.
- **Settings** has the Overpass server override and the mirror tally.

Files live in the Files app under **On My iPhone › Waytrace › Road KML**
(imported inputs in its **Inputs** folder). The engine's test suite is a port
of `test_road_to_kml.py`; it runs with `cd RoadKit && swift test` on a Mac and
in the GitHub build.

---

## Code map

| File | Role |
|---|---|
| `LocationRecorder.swift` | Core Location setup, the 15 s / 20 m sampling, relaunch and resume |
| `SamplingPolicy.swift` | The sampling settings and their defaults |
| `TrackStore.swift` | One CSV per recording in Documents/Tracks, appended per point |
| `TrackPoint.swift` | The point model, CSV format, time formats, distance maths |
| `MotionAnnotator.swift` | Walking/driving labels from Core Motion history |
| `Exporter.swift` | KML, Records.json, GPX and CSV writers |
| `Views/` | SwiftUI screens: main screen with RECORD/STOP, recording detail, export sheet, settings |
| `Roads/` | The Roads tab: forms and batch (`RoadForms`), runs and output files (`RoadJobs`), screens (`RoadsView`, `RunView`) |
| `RoadKit/` | Swift package: the port of road_to_kml.py, road_aliases.py, road_tracks.py, mirror_stats.py and county_fips.py, on GEOS (the library Shapely uses) |
| `RoadKit/Tests/` | The port of test_road_to_kml.py, with the same synthetic DC street grid and offline fakes |
| `Waytrace/Assets.xcassets`, `Design/AppIcon.svg` | The app icon (default, dark and tinted) and its source drawing |
