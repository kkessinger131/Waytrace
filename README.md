# Waytrace

An iPhone app that records everywhere you go: press **RECORD**, put the phone
away, press **STOP** when you're done (or leave it running for days). It
replaces two workflows:

- **Photo EXIF → KML.** Every point has what a photo's GPS EXIF has (time,
  position, accuracy, altitude, speed, direction of travel), with no photos to
  take. Export → **KML** gives the same line-plus-point-markers file, with
  the photos you took during the recording as points on the line. The
  **Photos** tab does what exif2kml.py did: every photo on a map, and a KML
  line through them for any day or range of days.
- **Google Timeline → `road_to_kml.py`.** road_to_kml.py is built into the app
  (the **Roads** tab, and **Map roads traveled** on any recording), so the road
  surfaces come out as KML on the phone. Export → **Records.json** still works
  with the Python script on a computer. A recording has a point every 10 s
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
   - Do the same for the **WaytraceControls** target (the Control Center
     buttons): same Team, and the app's ID plus `.controls`
     (`com.yourname.waytrace.controls`).
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
Version** = 5, and **Default Actor Isolation** = nonisolated. That
leaves out the Control Center buttons; for them, add a Widget Extension
target named WaytraceControls (iOS 18) holding `WaytraceControls/` and
`Waytrace/Intents/RecordingIntents.swift`.

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
| One save attempt every | 10 s |
| Skip if within this distance of the **last saved** point | 10 m |
| Skip if accuracy is worse than | ±50 m |
| Drift guard: also skip unless the move exceeds the fix's own accuracy | on |
| New file at local midnight | on |

All of these are in Settings (gear icon) and apply at the next RECORD. (The defaults
used to be 15 s and 20 m; a phone still on exactly those moves to the new ones
once, and any other value you chose is kept.)

- **Background.** iOS doesn't allow true background daemons. Instead, the app
  uses the background-location mode, which keeps it alive only while
  location updates run.
- **Why it's lightweight.** Core Location has a 5 m distance filter, so while
  you're still the app isn't woken at all. While you move it gets about one
  fix a second and does a single comparison per fix.
- **The save attempt.** Each attempt uses the newest fix, or a fix from the
  previous 3 s if that one is more accurate. Saving appends one ~150-byte line
  to a CSV.
- **Battery: the GPS rests while you stay put.** The GPS is the main battery
  cost, so after you've been still for 5 minutes it is turned down to cell-tower
  accuracy until you move (Settings › Battery; on by default). It only rests
  when every sign agrees: no fix leaves a small circle (40 m, more for vague
  indoor fixes), the motion sensor reports no walking, cycling or driving, and
  fewer than 30 steps are counted. Sitting at a red light or in a traffic jam
  reads as driving, and a short break on a hike is shorter than 5 minutes, so
  neither rests. Location updates never stop, so the app stays alive exactly as
  before and the recording carries on. It wakes after about 10 steps, as soon
  as the phone senses walking or driving, when you leave a 150 m geofence (with
  "Always" access), or at a quick GPS check every 3 minutes; the status card
  shows when it rested and what woke it. Nothing is saved while resting, since
  you haven't gone anywhere.
- **Turns.** Between attempts, a turn of **60° or more** in your direction of
  travel since the last saved point saves a point straight away, so corners
  stay sharp instead of being cut (at 10 s and 30 mph a corner could be cut by
  up to about 130 m). It reads the GPS's own direction of travel, and only
  when it's reliable: moving faster than 1 m/s with the direction known to
  ±30°. It costs no battery, since fixes already arrive about once a second
  while you move and this only looks at each one's direction. The distance,
  accuracy and drift rules still apply to a turn point. The Record screen
  counts them ("at turns").
- **No road snapping.** The activity type is `.other`, so a walk across a
  plaza or field is recorded as walked.
- **Drift guard.** Indoors, wifi positions (±30–65 m) wander 20–50 m while
  you sit still. In testing, the guard removed about half of that drift; the
  motion labels catch the rest (see KML below). Outdoors, with ±3–10 m GPS,
  the distance rule (10 m by default) applies exactly. Turn it off in Settings
  to use only the distance rule.
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
| **KML** | Google Earth / My Maps. A red line, plus a marker per point; tap one to see its time, accuracy, altitude, speed, course and activity. Points labelled *stationary* (usually indoor drift) go in a hidden "Stationary" folder and are left out of the line. Every photo and video taken during the recording (screenshots left out) is a point too, named by its file (`IMG_1234`), and a vertex of the line, slotted in by the time it was taken. A photo with its own location sits there; one without (yellow camera) is placed on the recording by time. Only the recording's own time span is searched (plus 5 minutes either side), so nothing from before you had the app is added. |
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

## Daily road map

Each time you press **STOP**, that recording is run through Road to KML with
the **GPS history** settings from the Roads tab, into its own file named after
the recording: `Road KML/roads_YYYY-MM-DD_HH-MM-SS.kml` (recording
`2026-11-08_09-12-44.csv` gives `roads_2026-11-08_09-12-44.kml`). Two
recordings on one day give two files. A recording that runs past midnight
without "Start a new file each day" gives one file per day; the later part is
named for that day from midnight (`roads_2026-11-09_00-00-00.kml`).

A file name is never reused, so one map can never overwrite another: before a
run, Waytrace checks the Road KML folder on the phone, the backup folder (even
for files you've since cleared from the phone, and files iCloud keeps only in
the cloud), and the other maps waiting to run. If the name is taken, `_2`,
`_3`… is added. There's deliberately no running "everywhere" map; that stays
in your QGIS workflow. A recording that runs past midnight maps the
finished day the next time you open the app (heavy work never runs in the
background alongside a recording). If the map servers are busy, it tries again
after 30 minutes and after 2 hours, then leaves it for you to run by hand.
Turn it off in Settings › Daily road map.

Each file also gets a **Photos** folder: a camera marker for every photo and
video taken during that recording (on that day), named by its file (`IMG_1234`).
A photo with its own location sits there; one without (yellow) is placed on the
recording between the points just before and after it. Each marker also
records the times of those two points (`point_before_time`,
`point_after_time`), so the photos slot into the recording's sequence of points.

A run keeps going when you switch to another app: while it works, location
updates at cell-tower accuracy (no GPS) keep Waytrace running, and the engine
paces itself in the background so iOS doesn't stop it for using too much CPU.
A notification comes when a run finishes, saying if anything went wrong
(failed rows, trips that couldn't be matched, gaps, map data that couldn't be
downloaded). Manual runs only notify if you've left the app.

## Backup to iCloud Drive

Settings › Backup › **Choose a folder in iCloud Drive…** (make one first, e.g.
iCloud Drive › Waytrace). Recordings are copied into `Recordings/` and road
maps into `Road KML/` every 15 minutes while recording, at STOP, after each
Road to KML run, and with **Back up now**. Only changed files are copied, and
nothing is ever deleted from the backup.

Each finished recording also gets its line KML in `Recordings/`, next to its
CSV with the same name (`2026-11-08_09-12-44.kml` beside
`2026-11-08_09-12-44.csv`). It's the same file as Export › KML: the line, a
marker per point, and the photos and videos taken during the recording as
points on the line. It's made when you press STOP (or at midnight, with "Start
a new file each day"), once the walking/driving labels are filled in, and made
again if you fill the labels in later. **Back up now** also makes one for any
finished recording that doesn't have one yet, such as those recorded before
this was added. Deleting a recording on the phone deletes its KML there too,
but not the backup copies.

**Delete backed-up recordings…** (Settings › Backup) frees space on the phone.
It deletes only recordings that ended **7 or more days ago** and whose CSV and
KML are confirmed in `Recordings/`: present, the same size, and uploaded by
iCloud (files iCloud keeps only in the cloud count as uploaded). It lists how
many it will delete and asks first; a recording in progress is never touched.
Older recordings that aren't fully in the backup yet are counted, so you can
press **Back up now** and try again. A recording's log (gaps, GPS rests,
battery) isn't backed up and is deleted with it; the backed-up KML still shows
the gaps.

## Gaps, battery and the battery saver log

If Waytrace stops while recording (the phone was off, iOS closed it, a Sideloadly
refresh restarted it…), the recording picks up again when it can. The gap is
noted in the recording's log (`<name>.log.json` next to the CSV): when, how long,
the likely cause, and how far you moved meanwhile. The recording's page lists
the gaps, exported KML shows each as a yellow line between the points either
side, and a gap of 10 minutes or more sends a notification when recording
resumes.

The same log keeps each GPS rest and what woke it. The recording's page sums
them up and flags any wake where only the 3-minute GPS check noticed you'd
left (the one case where a little track before it could be missing).

It also keeps the **battery level**: when recording starts and stops, at each
GPS rest and wake, at midnight, and whenever the level changes (iOS reports it
in 1% steps). The recording's page charts it, with the GPS rests shaded, and
lists the percentage used, the rate per hour, the rate with the GPS on and
with it resting, time on the charger (left out of the rates) and whether Low
Power Mode was on. The level counts everything else the phone did too, so
short stretches are rough; over a day it shows what recording costs and what
resting saves. Recordings made before this have no battery section.

## Photos

The **Photos** tab is exif2kml.py on the phone. It shows every photo and video
in your library that has a location (screenshots left out) on a map, grouped
into numbered clusters where they're dense; tap a cluster to zoom in, or a
photo for its file name, time and a small picture.

Choose **Day**, **Range** (first and last day) or **All**, and the map shows
just those. **Make KML line** writes a red line through them in the order
they were taken, with a pin for each one named by its file (`IMG_1234`) and
holding its time and altitude; turn off **Photo markers in the KML** for the
line alone. The file goes to `Exports/` as `photos_2026-11-08.kml`,
`photos_2026-11-01_to_2026-11-08.kml` or `photos_all.kml`, and **Share** sends
it anywhere. Photos without a location are counted but can't be shown or
drawn. With limited photo access (iOS's "Selected Photos"), only the photos
you've shared with Waytrace are there.

## Control Center and Shortcuts

On iOS 18 and later, Waytrace adds two Control Center buttons, **Start
recording** and **Stop recording**: open Control Center, tap **+** (top left)
› **Add a Control**, search for Waytrace, and place them. The same two actions
are in the Shortcuts app and Siri ("Start recording in Waytrace"), and can go
on the Action button, Back Tap or an automation.

Either one opens Waytrace on the Record screen, because iOS only lets an app
that's on screen start the GPS. Start begins recording just like RECORD
(nothing changes if it's already recording). Stop asks first, the same as
STOP; if nothing is recording, it says so.

## Signing reminder

A free Apple ID signs the app for 7 days. Settings shows when this install
expires. Notifications come 24 hours before and again 3 hours before, and the
Record screen shows a banner in the last 24 hours. When a refresh renews the
app, Settings shows when, and if it happened in the background a notification
says so. Set up Sideloadly's
automatic refresh ([INSTALL_WITHOUT_MAC.md](INSTALL_WITHOUT_MAC.md), part D) and
your PC re-signs it over Wi-Fi before then. Reinstalling over the app keeps
your recordings; deleting it erases them (another reason for the backup).

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
- **Nothing is overwritten.** If the output file already exists in the
  folder, `_2`, `_3`… is added and the log says so, as in road_to_kml.py.
  Names are kept to 120 characters (Windows allows 255, and paths 260 with
  the folder), so the files copy to a PC as they are.

Files live in the Files app under **On My iPhone › Waytrace › Road KML**
(imported inputs in its **Inputs** folder).

## Tests

Every GitHub build runs:

- **road_to_kml.py's own tests** (`road_to_kml/test_road_to_kml.py`, offline).
- **RoadKit's tests** (`cd RoadKit && swift test`): the port of
  test_road_to_kml.py with the same synthetic DC street grid and fakes.
- **The cross-check**: `road_to_kml/crosscheck.py` runs 17 jobs through the
  Python script (named roads, outlines, ramps, clips, TIGER/Line, Timeline and
  Waytrace-recording tracks), and `CrossCheckTests` runs the same jobs through
  the Swift port and checks both draw the same road surface, file name and
  exit code.
- **Alias parity**: about 27,000 road names expanded by road_aliases.py
  (recomputed with the current script by `make_alias_fixture.py`) must come
  out the same in Swift.
- **The app's tests on an iPhone simulator** (`WaytraceTests`): resting the
  GPS, turn points, photo placement, the daily map queue, signing expiry, run
  notifications, background pacing, the battery log, which recordings may be
  deleted, the photo-line KML and exports. They run inside the app, so the build also
  checks that it launches.

The `road_to_kml/` folder holds copies of the Python scripts for these checks.
The originals live in the Road to KML project; copy changes across so the two
stay in step.

---

## Code map

| File | Role |
|---|---|
| `LocationRecorder.swift` | Core Location setup, the 10 s / 10 m sampling and turn points, the battery log, relaunch and resume |
| `SamplingPolicy.swift` | The sampling settings and their defaults |
| `TrackStore.swift` | One CSV per recording in Documents/Tracks, appended per point |
| `RecordingKML.swift` | Each finished recording's line KML (with photos), saved beside its CSV for the backup |
| `TrackPoint.swift` | The point model, CSV format, time formats, distance maths |
| `MotionAnnotator.swift` | Walking/driving labels from Core Motion history |
| `Exporter.swift` | KML, Records.json, GPX, CSV and photo-map writers |
| `Logic/` | Rules without any iOS dependency, tested on their own: `StillnessDetector` (when the GPS rests and wakes), `TurnDetector`, `RecordingLog` (gaps, rests, battery), `PhotoPlacer`, `PhotoPath` (the Photos tab's KML), `Cleanup` (which recordings may be deleted), `DailyPlan`, `SigningInfo`, `RunSummary`, `BackgroundPacer` |
| `MotionWatch.swift` | Live activity and step count while recording, for resting the GPS |
| `DailyRoads.swift` | The automatic daily road map |
| `Backup.swift` | Copies to the iCloud Drive folder, and deletes backed-up recordings from the phone |
| `Notifier.swift` | Run-finished and signing-expiry notifications |
| `RunKeepAlive.swift` | Keeps a Road to KML run alive in the background |
| `PhotoLibrary.swift` | Reads photo times and places for the KML, the daily road map and the Photos tab |
| `Intents/` | Start and Stop Recording for Control Center, Shortcuts and Siri |
| `WaytraceControls/` | The widget extension holding the two Control Center buttons (iOS 18) |
| `Views/` | SwiftUI screens: main screen with RECORD/STOP, recording detail (with the battery chart), export sheet, Photos tab, settings |
| `Roads/` | The Roads tab: forms and batch (`RoadForms`), runs and output files (`RoadJobs`), screens (`RoadsView`, `RunView`) |
| `RoadKit/` | Swift package: the port of road_to_kml.py, road_aliases.py, road_tracks.py, mirror_stats.py and county_fips.py, on GEOS (the library Shapely uses) |
| `RoadKit/Tests/` | The port of test_road_to_kml.py, with the same synthetic DC street grid and offline fakes; the cross-check and alias parity tests |
| `WaytraceTests/` | The app's tests (run on a simulator) |
| `road_to_kml/` | Copies of the Python scripts, for the cross-check |
| `Waytrace/Assets.xcassets`, `Design/AppIcon.svg` | The app icon (default, dark and tinted) and its source drawing |
