# Installing Waytrace with only an iPhone and a Windows PC

GitHub builds the app on one of its cloud Macs. Sideloadly on your PC signs it
with your Apple ID and installs it on the iPhone. You only need a free GitHub
account and your Apple ID.

---

## A. Put the project on GitHub (once)

1. Sign in at github.com and create a **New repository**, named e.g. `waytrace`.
   Make it **Public**, since public repositories get unlimited free Mac build
   time. The code holds nothing personal; your recordings stay on the phone.
   Leave "Add a README" unticked.
2. Unzip `Waytrace.zip` on the PC. Open the inner **Waytrace** folder, the one
   that contains `Waytrace.xcodeproj`, `.github`, and `README.md`.
3. On the new repository's page, click **uploading an existing file**. Select
   everything *inside* that folder, including the `.github` folder, and drag
   it onto the page. Then click **Commit changes**.
   - Check that `.github/workflows/build-ipa.yml` appears in the repository.
     If the `.github` folder didn't come along, click **Add file › Create new
     file**, type `.github/workflows/build-ipa.yml` as the name, and paste the
     file's contents in.
   - Or use [GitHub Desktop](https://desktop.github.com), which uploads the
     whole folder as is.
4. Pick your bundle ID. Open `.github/workflows/build-ipa.yml` in the
   repository and click the pencil icon. Change `com.example.waytrace` to
   something unique to you, like `com.yourname.waytrace`, then **Commit
   changes**. Keep it the same from then on.

## B. Get the app file

1. Open the repository's **Actions** tab. Each commit starts a build, so one
   is already running. Builds take about 15 to 25 minutes: the Python and
   Swift road engines are tested and compared, the app's tests run on an
   iPhone simulator, then the app is built. (The map geometry library, GEOS,
   is kept between builds, so later ones are quicker.) To start one by hand,
   click **Build Waytrace (.ipa)** › **Run workflow**.
2. When the run shows a green tick, open it. Under **Artifacts**, download
   **Waytrace-ipa**. It downloads as a .zip; extract it to get
   **Waytrace.ipa**.

If the run shows a red ✗, open it and download **build-log**, or copy the
red error lines from the failed step, and send them to Claude.

## C. Install with Sideloadly (once)

1. Install **iTunes** and **iCloud** from Apple's website, *not* the Microsoft
   Store versions. Sideloadly needs their iPhone drivers.
2. Install **Sideloadly** from [sideloadly.io](https://sideloadly.io).
3. Connect the iPhone by USB. Unlock it and tap **Trust** if asked.
4. Open Sideloadly and drag **Waytrace.ipa** into it. Enter your Apple ID and
   click **Start**. Enter your password and the two-factor code when asked.
5. On the iPhone:
   - **Trust the profile:** go to Settings › General › **VPN & Device
     Management**, tap your Apple ID, then **Trust**.
   - **Developer Mode:** if iOS asks, go to Settings › Privacy & Security ›
     **Developer Mode**, turn it on, and restart. The option appears after the
     first install attempt.
6. Open Waytrace and follow "First run" in the README.

## D. The weekly renewal

With a free Apple ID, the app stops opening 7 days after it was signed.
Waytrace sends a notification 24 hours before, and Settings shows the exact
time. Reinstalling over the app keeps your recordings; deleting it erases them.

**Automatic refresh (set up once):**

1. **Wi-Fi sync.** Connect the iPhone by USB. In iTunes, click the phone icon,
   tick **Sync with this iPhone over Wi-Fi** and click Apply. (With Apple's
   newer *Apple Devices* app instead of iTunes: **Show this iPhone when on
   Wi-Fi**.)
2. **Start the daemon.** In Sideloadly, open **Advanced Options**, check that
   **Anisette Usage** is "Sideloadly Fixed" or "Remote", and click the
   **Sideloadly Daemon** button. An icon appears in the Windows tray.
3. **Install with refresh on.** Drag in Waytrace.ipa, enter your Apple ID,
   and in **Advanced Options** keep Signing Mode on **Apple ID Sideload** and
   tick **Automatic Refresh via Sideloadly Daemon**. Then click Start as usual.
4. **Check it.** Right-click the tray icon › **Show Daemon** lists the app and
   the days it has left.

From then on, whenever the PC is on, the daemon is running and the phone is on
the same Wi-Fi (with any VPN off), the app is re-signed when about 2 days
remain. If Waytrace's 24-hour warning arrives, the refresh hasn't happened:
plug the phone in, or check that the PC is awake and the daemon is running.

**By hand:** drag the same Waytrace.ipa into Sideloadly again and click Start.

A free Apple ID can have 3 sideloaded apps at once.
