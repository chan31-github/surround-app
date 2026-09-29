# Building and running Surround

The app only builds on a Mac with Xcode, and ARKit, the camera and motion
sensors only work on a physical iPhone. The simulator is useful for nothing
in this project beyond checking that the code compiles.

## One-time setup

1. Install XcodeGen: `brew install xcodegen`.
2. From the repository root run `./bootstrap.sh`. It copies
   `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored)
   and generates `Surround.xcodeproj`.
3. Edit `Config/Local.xcconfig`: set `DEVELOPMENT_TEAM` to your team ID, or
   leave it empty and pick the team in Xcode under Signing & Capabilities.
   Change `PRODUCT_BUNDLE_IDENTIFIER` if the default is taken.
4. Open `Surround.xcodeproj`, select your iPhone as the run destination, and
   press Run.
5. On a free developer account the phone will refuse to launch the app the
   first time. On the phone go to Settings > General > VPN & Device
   Management and trust your developer certificate. A free-account build
   expires after 7 days; run again from Xcode to refresh it.

Re-run `./bootstrap.sh` (or `xcodegen generate`) whenever `project.yml`
changes or files are added or removed. Do not edit the `.xcodeproj` by hand;
it is not committed.

`SurroundCore` is always compiled optimised, even in the app's Debug
configuration (`Package.swift` passes `-O` for debug builds). Xcode would
otherwise build the package at `-Onone`, and the stitcher is a hundred times
slower that way: a full sphere took six minutes on the phone instead of a
few seconds. To step through package code in the debugger, remove that
flag temporarily. The app target itself stays unoptimised in Debug.

## Which build is on the phone

The filter menu in the library, and the footer under the grid, show a line
like `Surround 0.1.0 (57) · a1b2c3d+ · 19 Sep, 17:02`: the marketing
version, the commit count, the short commit hash (with `+` when the tree
had uncommitted changes) and the build time. A build script writes these
into `BuildInfo.plist` in the bundle, so the line changes with every build
even when the version does not. Compare the hash with `git log` to confirm
a test device is running what you think it is.

## Running the core tests

```
cd Packages/SurroundCore
swift test
```

These cover the geometry, capture plan, alignment logic, projection stitcher,
ring refinement (alignment, gain, seams), trip day keys, metadata and XMP
code, and need no device. Set `SURROUND_DUMP=<dir>` to have the stitcher tests write their
synthetic outputs as PPM files for eyeballing.

## Re-stitching a capture on the Mac

The shots and poses of every kept sphere sit in the app's Documents folder
and can be copied off the phone without Xcode:

```
xcrun devicectl device copy from --device <udid> \
  --domain-type appDataContainer --domain-identifier com.chan31.surround \
  --source Documents --destination ./Documents
```

A few lines of macOS Swift that depend on `Packages/SurroundCore`, load each
`NNN.jpg` with ImageIO, and call `ProjectionStitcher.stitch` on the poses in
`capture.json` will reproduce the phone's output exactly, and
`StitchResult.refinement` reports what the ring analysis measured per pair.
That loop runs in under a second and is how the stitcher is tuned.

## Turning on iCloud sync

Sync (F17) is built and inert: without the iCloud entitlement the app keeps
its spheres in Documents and the filter menu says "iCloud: off". The
entitlement needs the paid Apple Developer Program, which a free Personal
Team cannot sign for. To turn it on:

1. Enrol at developer.apple.com/programs (approval can take up to two
   days), then in Xcode > Settings > Accounts make sure the paid team is
   the one selected; `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` may need
   to change to the new team ID.
2. Uncomment the `entitlements:` block under the Surround target in
   `project.yml` and run `./bootstrap.sh`.
3. Build once with `-allowProvisioningUpdates` (or press Run in Xcode) so
   Xcode registers the App ID's iCloud capability and the container
   `iCloud.com.chan31.surround`. If it complains the container does not
   exist, add it once under Signing & Capabilities > iCloud in Xcode.
4. Install on both devices, signed into the same iCloud account with iCloud
   Drive on. On first launch each device moves its local spheres into the
   container; the menu then says "iCloud: in sync" or "fetching n files".

What syncs: every sphere folder, and `trips.json` with the trip names.
Metadata and thumbnails are fetched as soon as they appear; the full image
is fetched when a sphere is opened (a cloud badge marks spheres not yet
downloaded); source shots are never fetched proactively. Edits to titles,
tags, positions and trip names are file writes, so they propagate, and the
receiving device refreshes its rows when it sees the file change. The
folder shows in the Files app under Surround for checking what has arrived.

## iPad and orientation

The app runs on iPad (family 1,2); the iPad supports landscape, the iPhone
stays portrait.
On an iPad simulator the library is a split view with trips in the
sidebar; seed it the same way as the iPhone simulator below (copy whole
sphere folders, not their contents). Capture stays portrait only and shows
a prompt in landscape. The viewer corrects its motion mapping for the
interface orientation; that correction can only be judged on an iPad, by
turning it to landscape in the viewer and checking the horizon stays level
and turning right still moves the view right.

## Trying the library and map in the simulator

The simulator cannot capture, but it can show spheres. Copy a sphere folder
from the phone (see above) into the simulator app's Documents folder; the
index is rebuilt from the folders at launch, so the sphere appears in the
list and, if it has a position, on the map:

```
xcrun simctl get_app_container booted com.chan31.surround data
cp -R <sphere-uuid> "<that path>/Documents/spheres/"
```

## Full sphere capture (M2, in progress)

The capture screen offers Ring or Full sphere before Start. A full sphere is
a ring at the horizon, rings at about plus and minus 40 degrees, and one
shot each straight up and down, 32 shots on the main camera, taken in a
serpentine so the user turns around once: front, down to the nadir, up to
the zenith, then each column top to bottom and bottom to top in turn. The
first rooftop sphere took 81 seconds.

A sphere is stitched by `SphereRefinement` and `SphereSeams`: every
overlapping pair is measured (in parallel across cores) and the per-shot
corrections are solved jointly over the graph; then, on a low-resolution
map of the sphere, each boundary between two shots is moved by a minimum
cut to where the two disagree least, so seams follow edges and a nearby
object moved by parallax lands wholly in one shot. A two-degree crossfade
spans each boundary. That takes about 0.9 s on an M4 Mac for 32 shots; the
app logs the stitch time under the `stitch` category, visible in
Console.app filtered on the Surround process.

During capture the overlay shows a small map of the sphere, yaw across from
the front and pitch down, with done targets green and the current one
yellow, plus a progress bar and "shot n of N · turn k of K · about s left"
from the pace so far. Before Start it says how many shots the chosen mode
takes and roughly how long.
What remains afterwards is parallax where no seam can hide it: repeating
ground patterns near the nadir, where the camera moved half a metre between
shots, may still show a jog. Pivot around the phone, not your body, to
reduce it.

## Exposure across a sphere

Two things make shots of one sphere differ in brightness: the exposure the
camera chose, and the lens darkening towards the frame's corners. The
refiners solve both, in turn: a gain per shot, then one radial falloff
shared by every shot (one lens, one falloff), then the gains again with the
falloff removed. The falloff is reported as `vignetteK`, the log brightness
per unit squared normalised radius; the rooftop spheres fit about -0.09,
a 10 percent darkening at the corners, and the correction cuts the
low-frequency brightness steps in flat sky by roughly a fifth.

Two-band blending is on for full spheres. Each shot is split into a coarse
layer (its local average over about 3 degrees) and a fine layer (the rest).
Fine layers are joined with the seam weights, so detail stays exactly where
the minimum cut put it; coarse layers are crossfaded over 30 percent of the
frame, so a brightness difference the gains could not remove, typically a
gradient across the sky near the sun, fades out instead of showing as a
block. `StitchOptions.bandSplitDegrees = 0` turns it off. A first version
that blended the finished composite towards a wide crossfade could not work,
because the finished composite already contained the step.

## Storage

Stills are stored as HEIC no larger than 2400 px on the long side, about
1 MB each; the stitcher never read more than that from the 12-megapixel
originals. Captures from before this change are re-encoded once at launch
("Shrinking source shots" in the filter menu), which returned about 80 % of
the space on the owner's phone. The menu shows the total and the part in
source shots, with "Remove all source shots"; the details sheet has the
same per sphere; "Delete source shots when keeping" drops them at Keep.
Source shots exist only to stitch a sphere again with a future engine, so
removing them costs nothing today. The Mac harness reads either encoding.

## Pivot gauge

Every capture so far drifted 20 to 40 cm from where it started, with the
largest distance when facing backwards: the lens circles the body when the
user turns on the spot with the phone held in front. Parallax from that is
what splits posts and railings at the seams. During capture a small top-down
gauge beside the sphere map shows where the phone is relative to the start,
with the user facing up the gauge: green within 10 cm, yellow to 25, red
beyond, with a banner past 25 cm asking the user to keep the phone over one
spot and step around it. The review screen notes the largest drift when it
was over 25 cm. The logic is `PivotGuide` in the core package.

Position readings are ignored while the phone points more than 55 degrees
up or down, or when they put the phone more than 90 cm from the start: with
only sky or ground in view ARKit's position estimate can wander (the hilltop
sphere of 26 September read 0.97 m at the zenith and 1.8 m on the next shot,
then recovered), while rotation, which the stitcher uses, is unaffected.
The gauge then shows the last good reading faded, labelled "holding".

## Signing expiry

A free Personal Team's signing lasts seven days; after that iOS keeps the
app and its spheres but will not open it until it is rebuilt and installed
again from Xcode, and the developer is trusted again in Settings, General,
VPN & Device Management. The filter menu shows "Signed until ...", read
from the bundle's embedded profile, and a yellow banner appears across the
library from 48 hours before. Rebuilding keeps the data; deleting the app
does not. The paid Apple Developer Program signs for a year.

## Live preview, finish early, retake last

During capture every still is pasted into the AR view at the pose it was
taken from, slightly translucent, so the sphere grows behind the live
camera as you turn and the next frame can be lined up against its
neighbours. "Retake last" drops the most recent shot and re-arms its
target. "Finish" appears once the horizon ring is closed and stitches what
has been taken; the format records partial coverage.

## Retake

Pick the shot on the sphere map rather than from a list, so it is clear
where it points; the still is previewed before committing. The guidance
circle is placed by projecting the target into the camera's frame, which
stays correct when the phone is rolled and near the poles where a yaw
difference means nothing. "Take it now" overrides the alignment gate: the
pose is recorded as it is and the stitcher works from that.

On the review screen, Retake shows the stills of the capture. Pick the one
to redo; the capture screen returns with that target, the session having
resumed without a tracking reset. Capture waits for tracking to read normal
(ARKit relocalises against what it mapped a moment ago), then the shot is
taken with the exposure and white balance the first shot locked, the file
is replaced and the sphere is stitched again. Cancel returns to the review
unchanged. Stay where you took the sphere: within a step for distant
scenery, closer if that segment has anything nearby.

## First run checklist for M1

1. On the capture screen, hold the phone upright and level. The debug line
   should read roughly `yaw 0  pitch 0  roll 0`. If roll reads about 90 or
   180 instead, report it: the screen-up axis assumption in
   `CameraPose.rollDegrees` is wrong and needs the sign flipped.
2. Tap Start, then turn slowly to the right. Each time the circle meets the
   crosshair and you hold still, a haptic tick confirms a shot and a dot at
   the top turns green.
3. After the last shot, stitching runs. Note how long it takes; over 30
   seconds on the 13 mini means the output width needs lowering.
4. In the review viewer, the front of the sphere should face you. If the sky
   is at the bottom, the texture V axis needs flipping in
   `SphereGeometry.make`. If turning right moves the image the wrong way, the
   yaw sign in `SphereViewerView.Coordinator.apply` needs flipping.
5. Keep the sphere and share the exported JPEG to yourself. Opening it in
   Google Photos should show it as a 360 photo.

## Where things live

| Path | What |
|---|---|
| `Packages/SurroundCore` | Platform-independent logic and its tests |
| `Surround/Capture` | ARKit session, guidance overlay, capture flow |
| `Surround/Stitching` | `SphereStitcher` protocol, projection engine adapter, image conversion |
| `Surround/Viewer` | SceneKit sphere, motion controller |
| `Surround/Library` | SwiftData records (sphere index, trip names), file store with background index rebuild and one-time thumbnail regeneration, shared thumbnail cache, trip-sectioned library with search, Trips screen, detail screen with title and tag editing |
| `Surround/Map` | `MKMapView` wrapper: sphere pins with heading wedge, clusters, callouts, remembered region |
| `Surround/Location` | Position and compass heading |
| `project.yml` | XcodeGen project definition, including Info.plist keys |
