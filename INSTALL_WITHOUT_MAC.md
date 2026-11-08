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
   is already running. Builds take about 10 to 15 minutes: the road engine's
   tests run first, and the map geometry library (GEOS) is compiled from
   source each time. To start one by hand, click
   **Build Waytrace (.ipa)** › **Run workflow**.
2. When the run shows a green tick, open it. Under **Artifacts**, download
   **Waytrace-ipa**. It downloads as a .zip; extract it to get
   **Waytrace.ipa**.

If the run shows a red ✗, open it and download **build-log**, or copy the
red error lines from the failed step, and send them to Claude. The road
engine has been compiled and its tests pass, but the app's screens haven't
been compiled for iPhone yet, so a first-build error or two is possible and
quick to fix.

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

With a free Apple ID, the app stops opening 7 days after it was signed. To
renew it:

- **Automatically:** tick Sideloadly's automatic refresh option when you
  install. Its background helper then re-signs the app whenever the phone
  connects to the PC, over USB or over Wi-Fi. For Wi-Fi, connect by USB once
  and tick "Sync with this iPhone over Wi-Fi" in iTunes. The phone's screen
  must be on and both devices on the same network.
- **By hand:** drag the same Waytrace.ipa into Sideloadly again and click
  Start.

Re-signing reinstalls over the existing app, which normally keeps your
recordings. Export anything important before renewing anyway; it takes a
few seconds. A free Apple ID can have 3 sideloaded apps at once.

A paid Apple Developer account ($99/year) makes each install last a year.

## E. Updating the app later

1. Replace or edit files in the GitHub repository; each commit triggers a new
   build.
2. Download the new **Waytrace-ipa** artifact.
3. Install it with Sideloadly exactly as before, keeping the same bundle ID so
   your recordings carry over.

Artifacts are kept for 90 days. Keep your current Waytrace.ipa on the PC for
renewals.
