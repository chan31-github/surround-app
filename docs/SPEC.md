# Surround: Specification

Working title: **Surround**. An iOS app for capturing and viewing immersive
photo spheres of scenic viewpoints, built for hiking in Hong Kong.

Status: v0.5. Decisions marked **Confirmed** were agreed during requirements
review. Section 8 records every decision and when it was settled. There are
no open decisions.

---

## 1. Purpose

A flat panorama does not recreate the feeling of standing at a viewpoint.
Surround captures the surroundings of a spot as a photo sphere and plays it
back so the viewer can look around by moving the phone, restoring the
spatial sense that a flat image loses.

## 2. Users and context

- **Primary user:** the project owner, a hiker in Hong Kong. Single user for
  the foreseeable future. A public App Store release is a possible later
  stage, so nothing in the design should preclude it, but no multi-user,
  account, or backend work is done until then.
- **Capture context:** outdoors on a trail. No tripod. Bright sun and haze.
  Wind. Sweaty hands. Possibly no mobile signal. Battery matters.
- **Viewing context:** at home on the same iPhone or on the owner's iPad
  mini (6th generation), and occasionally showing friends on either. The
  iPad is a viewing and browsing device first; capture happens on the
  iPhone. **Confirmed** in v0.4.
- **Platform baseline:** iOS 27 and iPadOS 27 as the minimum. **Confirmed**
  in v0.4: the owner's devices all run the current OS and the app is
  personal, so backward compatibility is worth nothing and every current API
  can be used without availability checks.

## 3. Milestones

**Confirmed:** cylindrical capture is the first milestone, full sphere is the
goal. Whether the full sphere ships in the first usable version is decided
after M1.

| Milestone | Scope | Exit criterion |
|---|---|---|
| M1 Cylindrical POC | Guided 360-degree single-ring capture, on-device stitch, gyro viewer, local library, location and heading metadata. | Owner captures three spheres on a real hike and the look-around playback feels closer to being there than the iPhone panorama does. |
| M2 Full sphere | Multi-ring capture including zenith and nadir, spherical stitch. Viewer and storage unchanged because M1 already uses the spherical format. | A full sphere captured hand-held on a summit stitches with no gap and no seam visible at normal zoom. |
| M3 Trail polish | P1 items: segment retake, exposure lock, standard export, trips, map view with heading pins, iCloud sync to the iPad, all-orientation viewing, capture time target. | Owner prefers Surround over the built-in Camera panorama for every viewpoint on a hike, finds any past sphere from the map without scrolling the list, and views the day's spheres on the iPad that evening without touching a cable. |
| M4 Share and release | P2 items and App Store preparation, only if M3 proves the app is useful to others. | Decided later. |

## 4. Functional requirements

Priorities: **P0** must have, **P1** should have soon after, **P2** nice to
have, **P3** later or never. IDs are stable for reference in issues.

### P0

| ID | Requirement | Acceptance criteria |
|---|---|---|
| F1 | **Guided capture.** On-screen targets show where to point the phone next. A shot is taken automatically when the phone is aligned and steady. M1: one horizontal ring covering 360 degrees. M2: rings at several pitches plus zenith and nadir. | Alignment tolerance and steadiness threshold are configurable constants. A full ring completes without the user touching the screen after the first tap. A progress indicator shows coverage. |
| F2 | **On-device stitching.** Shots are stitched into one equirectangular image before the user leaves the spot. | Result is shown within 30 seconds of the last shot on an iPhone from the last three generations. A failed stitch is reported with the option to retake. Seams are not visible at default zoom on the phone screen. |
| F3 | **Immersive viewer.** Look around by moving the phone (gyroscope), with drag as fallback. Pinch to zoom. | Sustained 60 fps on supported devices. Field of view clamped between 30 and 100 degrees. Motion-to-photon latency low enough that no user reports lag or nausea. |
| F4 | **Local library.** All spheres stored on device with thumbnail, date, location. Fully offline. | Library opens and scrolls with 200 spheres without stutter. No network permission requested. Deleting a sphere removes all its files. |
| F5 | **Location and heading metadata.** GPS position, altitude, and compass heading are recorded at capture. The viewer opens facing the direction the user faced when capture started. | Metadata is stored in the sphere's sidecar and embedded in exports (F8). Location permission is requested only when capture starts. Capture still works with location denied. |

### P1

| ID | Requirement | Acceptance criteria |
|---|---|---|
| F6 | **Segment retake.** Any individual shot can be retaken without restarting the sphere. | The coverage view lets the user tap a segment to retake it. Re-stitching uses the replaced shot. |
| F7 | **Exposure handling.** Exposure and white balance are locked after the first shot so the sphere has uniform brightness. Bracketed capture is a later option. | Sky and shaded terrain in the same sphere are both legible. The lock value is chosen from a metered reference frame at the brightest expected direction, or from the first shot, selectable in settings. |
| F8 | **Standard export.** Export as an equirectangular JPEG with XMP photo sphere (GPano) metadata. Partial coverage (cylindrical) is expressed via the GPano cropped-area fields. | The exported file opens as a 360 photo in Google Photos and Facebook, and as a cropped panorama in the iOS Photos app. |
| F9 | **Trips.** Spheres captured on the same calendar day form a trip automatically. A trip can be renamed (for example "MacLehose section 4"), and a sphere can carry free-text tags. The library and the map can be filtered by trip. | No manual step is needed for a sphere to belong to a trip. Renaming a trip is one tap from the library or the map. Tags autocomplete from previous tags. |
| F10 | **Capture time.** A full ring (M1) takes under 90 seconds; a full sphere (M2) under 3 minutes for a practised user. | Measured on a real hike with a stopwatch. |
| F17 | **Sync between the owner's devices.** A sphere kept on the iPhone appears on the iPad, and edits to a title, trip name or tags made on either device appear on the other. Deleting on one device deletes on both. See section 6.7. | Within a minute of both devices being online. Works with the app closed on the receiving device. No account beyond the user's iCloud login. Viewing and capture keep working offline; changes reconcile later. |
| F20 | **Map view.** The library can be shown as a map with one pin per sphere, so a sphere is found by where it was taken rather than when. Tapping a pin shows the thumbnail, title and date, and opens the viewer. See section 6.6. | Opens fitted to all spheres. Pins closer together than about 40 points cluster and expand on tap. A "locate me" button centres on the phone's position. Works offline with whatever base-map tiles are cached; pins and thumbnails never depend on the network. The map shows a sphere within one second of it being kept. |
| F21 | **Heading on the pin.** Each pin shows the direction the sphere's front faces, as a short wedge, so the map also answers "which way was I looking". | The wedge uses `frontHeadingDegrees`; pins without a heading show a plain dot. The wedge is legible at the default zoom on a 13 mini screen. |

### P2

| ID | Requirement |
|---|---|
| F11 | Share a viewable link or bundle with people who do not have the app. |
| F12 | Peak and landmark labels overlaid in the viewer, derived from heading, position, and a Hong Kong peaks dataset. |
| F13 | Little-planet and flat panorama renders from the same sphere for social posts. |
| F14 | Optional voice note or ambient audio recorded at the spot, played back in the viewer. |
| F15 | Weather and visibility at capture time stored with the sphere. |
| F22 | Place-name suggestion. When a sphere is kept, the nearest named peak or viewpoint within about 300 m from a bundled Hong Kong dataset is offered as its title. Shares the dataset with F12. |
| F23 | Trip path. On the map, the spheres of one trip are joined in capture order by a thin line, giving a sense of the route without recording a GPS track. |
| F24 | Location control on share. Sharing or exporting a sphere (F8, F11) can strip position and heading; the default for a public release is to strip. |

### P3

| ID | Requirement |
|---|---|
| F16 | Apple Vision Pro or headset viewing. |
| F18 | Video spheres or HDR capture. |
| F19 | Android version. |
| F25 | Hike route overlay. Draw the day's actual route on the map from an Apple Health workout route or an imported GPX file (for example from a COROS watch), instead of the straight-line trip path of F23. |

## 5. Non-functional requirements

| ID | Requirement |
|---|---|
| N1 | **Offline first.** Every P0 and P1 feature works with no network. |
| N2 | **Battery.** A capture session, including stitch, uses under 3 percent battery on a recent iPhone. Camera and motion sensors are released the moment capture ends. |
| N3 | **Storage.** A stitched sphere plus its source shots stays under 60 MB. The user can see and reclaim space per sphere. |
| N4 | **Outdoor usability.** Capture screen is legible in direct sunlight (high-contrast overlays, large targets). All capture actions are possible with one thumb. |
| N5 | **Privacy.** No data leaves the device unless the user exports or shares. No analytics in M1 to M3. Location is stored only with the user's own spheres, and the map view never sends sphere positions anywhere: the base map is fetched by region, the pins are drawn locally. |
| N6 | **Maintainability.** Stitching, viewer rendering, and storage are behind protocols so each can be replaced. Every third-party dependency has a stated reason and an exit plan. |
| N7 | **Supported devices.** iOS 27 and iPadOS 27 or later, iPhone and iPad. The library, map and viewer support every orientation on both devices. Capture is portrait only on both devices. |

## 6. Technical approach

**Confirmed:** use iOS built-in frameworks and well-tested libraries rather
than writing capture, tracking, rendering, or stitching from scratch.

**Confirmed:** native Swift is preferred where it gives better performance.
Camera control, motion tracking, and GPU rendering all sit on native
frameworks with no cross-platform equivalent of the same quality, so the
whole app is native Swift with SwiftUI. There is no framework split.

### 6.1 Platform and frameworks

| Concern | Choice | Reason |
|---|---|---|
| Language and UI | Swift, SwiftUI, with UIKit views where gestures or camera preview need it | Native performance, simplest long-term maintenance for a single iOS app |
| Camera and orientation during capture | ARKit world tracking owns the camera: `ARSession` supplies the preview, the drift-corrected camera pose, high-resolution stills through `captureHighResolutionFrame`, and the exposure lock through `configurableCaptureDeviceForPrimaryCamera` | ARKit and an `AVCaptureSession` cannot share the camera, so AVFoundation is not used directly. ARKit fuses camera and IMU and gives drift-corrected rotation, which is what guided capture needs; CoreMotion alone drifts in yaw. When tracking degrades the app pauses capture and tells the user rather than switching sensors |
| Viewer rendering | SceneKit: camera at the centre of a sphere with inward-facing normals, equirectangular texture | Simple, GPU-accelerated, 60 fps on all supported devices. Metal directly is the fallback if SceneKit limits us |
| Viewer orientation | CoreMotion `CMDeviceMotion` attitude, reference frame `xArbitraryCorrectedZVertical` | Low latency, no camera needed for playback |
| Location | CoreLocation for position, altitude, and true heading | Standard |
| Library index | SwiftData | Native, minimal boilerplate |
| Sync | iCloud Drive: the `spheres/` folder lives in the app's ubiquity container | Files are already the source of truth and each sphere is a self-contained folder, so file sync is the sync. No CloudKit schema constraints, no server code |
| Map | MapKit through `MKMapView` (UIKit) wrapped for SwiftUI, not the SwiftUI `Map` view | `MKMapView` has annotation clustering, custom annotation views for the heading wedge and thumbnail, and overlays for the trip path; the SwiftUI `Map` on iOS 17 has none of these |
| Stitching, M1 | Projection stitcher in `SurroundCore`: pure Swift, projects each still onto the sphere from its ARKit pose and intrinsics. Before compositing, `RingRefinement` corrects each shot's yaw and pitch by correlating it with its neighbours (ring closed, front shot anchored), equalises exposure with a per-shot gain, and cuts each overlap along the seam where the two shots agree best, with a crossfade that widens in smooth areas such as sky and stays narrow over detail | No dependency, testable on any platform, and a direct check of whether the poses are good enough. Pose-only projection with a wide crossfade remains available as `StitchOptions.plain` for diagnosing captures |
| Stitching, M2 onwards | OpenCV (official iOS xcframework) via a small Objective-C++ bridge, using its cylindrical and spherical warpers, exposure compensation, and multi-band blending, seeded with ARKit rotations as initial camera poses | The only mature, well-tested open stitching pipeline available on iOS. Seeding with known rotations makes it robust for low-texture sky and sea, which is where feature matching alone fails on a summit |

Apple does not expose the built-in Camera app's panorama stitcher as an API,
and the Vision framework does not stitch, so a third-party stitcher is
unavoidable for production quality. OpenCV is the one dependency that needs
an exit plan: every engine sits behind the `SphereStitcher` protocol, and the
projection stitcher stays as the dependency-free fallback and the debugging
baseline for whether a capture's poses are sound.

Code layout: `Packages/SurroundCore` is a Swift package with no platform
dependencies (geometry, capture plan, alignment, equirectangular layout,
projection stitcher, metadata, XMP) and unit tests that run with
`swift test` on a Mac. The `Surround` app target holds everything that
needs iOS frameworks. The Xcode project is generated from `project.yml`
with XcodeGen; see `docs/BUILDING.md`.

### 6.2 One format for both milestones

Every sphere, including a cylindrical one from M1, is stored as a
**partial equirectangular image**: full 360 degrees of yaw, with the
uncovered pitch range filled with transparent or a neutral gradient and the
covered range recorded in metadata. This means:

- The viewer, library, export, and metadata code are written once and do
  not change when M2 adds the full sphere.
- The M1 result already behaves as a sphere in the viewer, with an empty sky
  and ground, so the "sphere as the goal" is visible from the first build.
- Export uses the same GPano cropped-area fields Google uses for partial
  panoramas.

### 6.3 Capture flow (M1)

1. User taps +. The ARKit session starts with the camera preview; exposure
   is automatic. Location and compass updates start.
2. The user centres the view they want as the sphere's front and taps Start.
   That direction becomes yaw 0 of the sphere; the compass heading and
   position at that moment are recorded (F5).
3. The app reads the camera's field of view across the sensor's short side
   (the direction of rotation in portrait) from ARKit's intrinsics and
   computes a yaw step giving at least 40 percent overlap. With the main
   camera that is about 13 shots per ring.
4. A circle marks the next target. When the viewing direction is within 3
   degrees of it, the phone has been rotating slower than 12 degrees per
   second for a quarter of a second, and tracking is normal, a
   high-resolution still is taken automatically with a haptic tick. The
   first shot locks exposure and white balance (F7). Each still is written to
   disk immediately with its pose so memory stays flat.
5. After the last target the session stops and stitching runs with a
   progress bar. The result opens in the viewer with the covered pitch range
   shown. Buttons: Keep, Discard. Retake of a single segment is M3 (F6).
6. M2 adds rings at further pitches plus zenith and nadir with the same
   mechanism; `CapturePlan.sphere` already generates that plan.

The main camera is used, not the ultra-wide, because edge sharpness and
distortion on the ultra-wide degrade the stitch. Ultra-wide is a possible
"fast mode" later.

### 6.4 Viewer

- Sphere of radius 10 units, camera at origin, texture is the
  equirectangular image, uncovered area drawn in a neutral dark gradient.
- Camera orientation comes from device attitude, corrected for the current
  interface orientation (the motion-to-scene mapping written for portrait
  gains a rotation about the screen normal of 0, 90, 180 or 270 degrees),
  offset so that the sphere's front faces the user when the view opens.
  Landscape is the better way to view a panorama and is supported on both
  devices. Drag adds a yaw offset on top of
  the device attitude (yaw and pitch when no motion sensors are available).
  Double-tap recentres and resets zoom.
- The sphere mesh is built by the app with texture coordinates that follow
  the equirectangular layout exactly, rather than relying on SCNSphere's
  mapping, so the seam and mirroring are deterministic.
- Pinch changes the camera's field of view within the 30 to 100 degree
  clamp.
- Roll from the device is applied so tilting the phone tilts the horizon,
  which is what makes it feel like a window rather than a picture.

### 6.5 Data and files

```
Documents/
  spheres/
    <uuid>/
      sphere.jpg          equirectangular, up to 8192 x 4096
      thumb.jpg           512 x 256
      metadata.json       see below
      shots/              source stills and their poses, kept for re-stitch
        capture.json      manifest: front yaw, plan step, all poses
        000.jpg           still in the sensor's landscape orientation
        000.json          ARKit transform, intrinsics, timestamp, exposure
        ...
```

Stills are stored exactly as the sensor delivers them, without an
orientation tag, because the stitcher uses the recorded rotation rather than
the image orientation.

`metadata.json` fields: id, capturedAt, latitude, longitude, altitude,
frontHeadingDegrees, coveredPitchMinDegrees, coveredPitchMaxDegrees,
projection ("equirectangular"), widthPx, heightPx, stitcher name and
version, device model, trip tag(s), notes.

SwiftData holds an index row per sphere (id, date, location, tags, file
size) for fast library queries. Files are the source of truth; the index can
be rebuilt from the folders.

### 6.6 Map view

**Why it earns its place.** A sphere is defined by a place more than by a
date. After a few months the list view becomes a scroll through similar
thumbnails, while a map with terrain answers "the one from Sunset Peak" in
one glance. The data is already captured (F5), MapKit is built in, and the
work is a few hundred lines, so the cost is low relative to the value. It
also reduces how much manual tagging F9 needs: place comes from the map,
day comes from the automatic trip, and tags become optional.

**Where it lives.** The library screen gets a list/map toggle in its
toolbar rather than a separate tab, so both views share the same trip and
tag filters and the same selection. The detail view's info sheet gets a
small static map snippet (`MKMapSnapshotter`, rendered once and cached)
showing the pin and heading wedge; tapping it opens the full map centred
there.

**Pins.** One annotation per sphere with a position. The annotation view is
a 28-point circle holding the thumbnail, with a wedge behind it pointing
along `frontHeadingDegrees` (F21). Selecting a pin shows a callout with the
title or date, altitude, trip name, and a button that opens the viewer.
Spheres without a position are listed under an "unplaced" filter and can
be placed by dropping a pin by hand (a long press on the map), which writes
the position into `metadata.json` with an `isManualPosition` flag.

**Clustering.** `MKMapView` clusters annotations that share a
`clusteringIdentifier`. A cluster shows the count and, when it contains a
single trip, that trip's name. Tapping a cluster zooms to fit its members.
Repeated visits to the same summit are the common case, so clustering is
required rather than optional.

**Base map.** Apple's standard map with elevation rendering
(`preferredConfiguration = MKStandardMapConfiguration(elevationStyle:
.realistic)`), with a toggle to satellite imagery. Apple Maps shows Hong
Kong country park trails and contours adequately for placing a pin. An
OpenStreetMap or OpenTopoMap tile overlay (`MKTileOverlay`) is a possible
later option because OSM's Hong Kong trail data is more complete, but it
brings tile-server usage policies and attribution requirements that matter
for an App Store release, so it is not in scope for M3.

**Camera and state.** On first open the map fits all visible pins with
padding; afterwards it restores the last region. A locate-me button uses
the existing location permission. Filters (trip, tag, date range) apply to
pins exactly as they apply to the list.

**Offline.** Pins, thumbnails, callouts and the trip path are local data.
Base-map tiles come from Apple's servers and are cached by MapKit for
regions already viewed. iOS 17's offline maps downloaded in the Apple Maps
app may also serve third-party MapKit views; that is to be verified on the
device. If it does not, the map degrades to pins on a blank background
when off-grid, which is acceptable because the map is mostly used at home.

**Data.** No schema change: `latitude`, `longitude`, `altitudeMetres`,
`horizontalAccuracyMetres` and `frontHeadingDegrees` already exist in
`SphereMetadata` and `SphereRecord`. Additions: `isManualPosition` (Bool,
default false) and, for F9, a `Trip` record keyed by calendar day in the
local time zone with an optional display name. Positions with horizontal
accuracy worse than 100 m show a wider, translucent ring around the pin.

**Place names (F22).** `CLGeocoder` returns districts and roads, not
peaks, so it is not useful here. A bundled dataset of Hong Kong peaks and
viewpoints is needed. Candidate sources: OpenStreetMap `natural=peak` and
`tourism=viewpoint` nodes for Hong Kong (a few hundred entries, ODbL
licence, attribution required), or the Lands Department place-name data on
data.gov.hk. The dataset is a JSON file of name, position and elevation,
and the same file serves the viewer labels in F12.

**Not in scope.** Recording a GPS track during the hike (battery cost and
a different product). Routing, distance or elevation-gain statistics.
Showing other people's spheres.

### 6.7 iPad, orientation and sync

**What the iPad is for.** Viewing and browsing: a bigger screen for the
sphere, and a map next to the list. Capture on the iPad mini works
technically (A15, ARKit, 12 MP rear camera) and nothing blocks it, but the
capture flow is designed and tested for a phone held in one hand; it is
not a supported iPad use case and gets no iPad-specific work.

**Layout.** In a regular-width window (iPad, and iPhone landscape is not
regular) the library shows the list and the map side by side with a shared
selection, using `NavigationSplitView`: trips in the sidebar, list or grid
in the content column, map or viewer in the detail column. In compact
width the existing stack with the list/map toggle remains. The viewer
opens full screen on both devices.

**Orientation.** The library, map and viewer support all orientations on
both devices. Two pieces of code currently assume portrait and must become
orientation-aware before the lock is lifted:

- The viewer's motion mapping (section 6.4). The device frame's screen-up
  axis changes with interface orientation; the correction is one extra
  rotation about the screen normal, taken from the window scene's
  interface orientation.
- Capture. It stays portrait only. On both devices the capture screen shows
  a "rotate to portrait" prompt when the interface is landscape rather
  than trying to handle landscape geometry (the yaw field of view and the
  screen-up axis both swap).

Project settings: `TARGETED_DEVICE_FAMILY` 1,2; iPhone orientations
portrait plus both landscapes; iPad all four; `UIRequiresFullScreen` false
so Split View and Stage Manager work; `UIRequiredDeviceCapabilities`
keeps `arkit`, which every iPad on iPadOS 27 satisfies.

**Sync (F17).** Moving the `spheres/` folder into the app's iCloud Drive
ubiquity container makes every sphere folder sync as a unit. Each device
rebuilds its SwiftData index from the files it sees, which the storage
design already requires. Details:

- Sphere folders are written once; only `metadata.json` changes afterwards
  (title, trip name, tags), so conflicts are rare and last-writer-wins on
  that one file is acceptable. iCloud's conflict versions are discarded.
- Source shots (`shots/`, roughly two-thirds of a sphere's size) sync too
  by default so re-stitching works on either device. A setting can keep
  them local-only.
- The receiving device sees files arrive through `NSMetadataQuery` and
  downloads them with `startDownloadingUbiquitousItem`; thumbnails are
  fetched first so the library fills in before the full images land.
- iCloud entitlements need the paid Apple Developer Program, which
  decision 4 already schedules before M3.
- Until sync ships, the fallback is AirDrop of a sphere folder as a bundle
  and an "import" entry point, which is also the basis for F11.

**What the iOS 27 baseline changes.** The concrete simplifications the
higher baseline is known to allow, and the ones the local session should
check in the SDK because they may have arrived after this document's
author could verify them:

- Known: Xcode 26 and later can build the app in Swift 6 language mode
  with default main-actor isolation for the app module, which removes most
  of the manual `@MainActor` and `Sendable` bookkeeping the scaffold
  avoids by staying in Swift 5 mode. Decision 16.
- Known: `@Observable` view models instead of `ObservableObject` and
  Combine, which simplifies `CaptureViewModel` and `CaptureSession`. No
  minimum-OS change needed, but worth doing in the same pass.
- Known: every MapKit, SwiftData and SwiftUI API through iOS 26 is
  available without availability checks.
- To check: whether the SwiftUI `Map` in the iOS 27 SDK supports
  annotation clustering and custom annotation views. If it does,
  decision 9 (wrapped `MKMapView`) is reversed and the map is written in
  SwiftUI. If not, decision 9 stands.
- To check: whether ARKit in iOS 27 offers still capture with custom photo
  settings (bracketing, RAW) from a running session, which would make F7's
  bracketed option and F18's HDR capture cheap.
- To check: whether Apple Maps offline downloads serve MapKit in
  third-party apps on iOS 27; this decides how the map behaves off-grid.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Hand-held parallax causes seams on near objects (rocks, railings, your own feet) | Visible stitch errors | Guide the user to rotate about the camera, not their body; keep near objects out of frame; accept that M1 targets distant scenery. The seam finder routes cuts around mismatches; a rotation-only alignment cannot remove them. On the first rooftop capture the camera drifted about half a metre around the ring and the pairwise yaw offsets summed to 15 degrees, all parallax |
| Featureless sky and sea defeat feature matching | Stitch fails or warps | Seed OpenCV with ARKit poses; fall back to projection-only stitcher for those regions |
| ARKit tracking degrades in bright, low-texture scenes | Wrong poses | Detect `limited` tracking state, show a warning, fall back to CoreMotion yaw with a magnetometer reference |
| OpenCV binary size (roughly 20 to 40 MB) and build friction | Slower iteration | Acceptable for a personal app; revisit only before App Store release |
| Stitch time on the iPhone 13 mini | Frustration on the trail | Output is 4096 x 2048 for M1 and stills are downscaled before stitching; stitch at reduced resolution first for preview, full resolution in the background, if measured time exceeds 30 seconds |
| Roll and screen-up conventions of ARKit's camera frame are assumed, not yet verified on a device | Roll readout wrong; stitch unaffected (it uses the full rotation) | The roll check is disabled by default and the live yaw/pitch/roll readout on the capture screen lets the owner confirm the convention on first run |
| The owner stops using it because capture takes too long | Project fails its purpose | F10 is a hard target; measure on every hike |
| Base-map tiles unavailable off-grid | Map shows pins on a blank background on the trail | Map is a home-viewing feature; verify whether Apple Maps offline downloads serve MapKit; pins never depend on the network |
| Apple Maps trail detail in Hong Kong is thinner than OpenStreetMap | Harder to relate a pin to a trail | Elevation rendering and satellite toggle first; OSM tile overlay later if still needed, with its licensing handled before any public release |
| Peaks dataset licensing (ODbL attribution) | Blocks a public release if ignored | Choose the source and record its attribution requirement when F22 or F12 starts |
| GPS accuracy on a summit is usually good but can be tens of metres under tree cover | Pin lands off the viewpoint | Store and show horizontal accuracy; allow manual pin placement |
| The iPad mini 6th generation is not on the iPadOS 27 support list | iPad scope cannot ship at the iOS 27 baseline | Verify on the device before M3; if unsupported, drop the baseline to the iPad's OS rather than drop the iPad |
| Orientation lock lifted before the motion mapping is corrected | Viewer horizon wrong in landscape | Lift the lock in the same change that adds the interface-orientation correction, and test all four orientations on both devices |
| iCloud sync of large folders is slow or stalls on a metered connection | iPad shows stale library | Thumbnails and metadata first; full image on demand; a visible sync state per sphere; Wi-Fi-only option |

## 8. Decisions record

Decisions 1 to 6 were settled after the v0.1 review; 14 and 15 in v0.4; the
rest were proposed in v0.3 and v0.4 and confirmed in v0.5.

| # | Question | Decision |
|---|---|---|
| 1 | Capture device | iPhone 13 mini on iOS 27 (A15; fully supports ARKit world tracking and high-resolution frame capture). An iPhone 17 Pro is available for comparison, mainly useful for stitch-time and camera-quality checks. Minimum deployment target was iOS 17 in v0.1 to v0.3; raised to iOS 27 in v0.4 (decision 14). |
| 2 | Keep source shots after a successful stitch? | Keep, with a per-sphere "delete sources" action and a setting to auto-delete (M3). |
| 3 | Save the stitched image to the iOS Photos app automatically? | No. Explicit export only. |
| 4 | Apple Developer account | Free for M1, paid before M3. iCloud sync (F17) is the first feature that cannot work on a free account. |
| 5 | Build and test loop | Code is written in this repository; the owner builds and runs on a Mac mini M4 with Xcode and the phone connected. The core package's tests run with `swift test` on the Mac. |
| 6 | Uncovered sky and ground in a cylindrical capture | Dark gradient, no pitch clamp. |
| 7 | Map as a toggle inside the library, or a separate tab? | Toggle in the library toolbar, so filters and selection are shared and there is one place to look for spheres. **Confirmed** in v0.5 (proposed in v0.3). |
| 8 | Priority of the map view | P1, in M3. It is cheap and it changes how the library is used, so it should land before any sharing work. **Confirmed** in v0.5 (proposed in v0.3). |
| 9 | `MKMapView` wrapper versus the SwiftUI `Map` | `MKMapView`, for clustering, custom pins with the heading wedge, and overlays. The SwiftUI `Map` would need replacing as soon as clustering is added. **Confirmed** in v0.5 (proposed in v0.3). |
| 10 | Base map | Apple standard with realistic elevation, satellite toggle. No OSM tiles in M3. **Confirmed** in v0.5 (proposed in v0.3). |
| 11 | Trips | Automatic by calendar day, renamable, replacing the manual trip tagging in the v0.2 wording of F9. Tags stay as optional free text. **Confirmed** in v0.5 (proposed in v0.3). |
| 12 | Manual pin placement for spheres without a position | Yes, by long press, flagged as manual in metadata. **Confirmed** in v0.5 (proposed in v0.3). |
| 13 | Peaks dataset source | OpenStreetMap extract, because it also has viewpoints and is easy to refresh; record the attribution. Decide when F22 or F12 starts, not now. **Confirmed** in v0.5 (proposed in v0.3). |
| 14 | Minimum OS | iOS 27 and iPadOS 27. **Confirmed** in v0.4. The `SurroundCore` package keeps its lower platform floor because a library needs no minimum and the tools version that names iOS 27 is not required. |
| 15 | iPad | In scope as a viewing and browsing device, with iCloud sync. **Confirmed** in v0.4. |
| 16 | Swift 6 language mode with default main-actor isolation for the app target | Yes, in a dedicated change once M1 builds and runs, not mixed with feature work. Move view models to `@Observable` in the same pass. **Confirmed** in v0.5 (proposed in v0.4). |
| 17 | Sync mechanism | iCloud Drive ubiquity container, not CloudKit through SwiftData. CloudKit forbids the unique constraint the index uses and would make the index, not the files, the source of truth. **Confirmed** in v0.5 (proposed in v0.4). |
| 18 | Capture on the iPad | Allowed but unsupported: no iPad-specific capture work, portrait only, same as the phone. **Confirmed** in v0.5 (proposed in v0.4). |
| 19 | iPhone landscape for the viewer | Yes, once the orientation correction in section 6.7 exists. **Confirmed** in v0.5 (proposed in v0.4). |

## 9. Out of scope

- Any backend, account, or sync before M4.
- Video capture.
- Editing tools beyond retake and delete.
- Recording GPS tracks during a hike; routing, distance and elevation-gain statistics.
- Mac.
- iPad-specific capture work.
