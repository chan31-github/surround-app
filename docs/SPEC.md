# Surround: Specification

Working title: **Surround**. An iOS app for capturing and viewing immersive
photo spheres of scenic viewpoints, built for hiking in Hong Kong.

Status: draft v0.1 for review. Decisions marked **Confirmed** were agreed
during requirements review. Items under *Open decisions* carry a default
that applies until overridden.

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
- **Viewing context:** at home on the same iPhone, and occasionally showing
  friends on the phone.

## 3. Milestones

**Confirmed:** cylindrical capture is the first milestone, full sphere is the
goal. Whether the full sphere ships in the first usable version is decided
after M1.

| Milestone | Scope | Exit criterion |
|---|---|---|
| M1 Cylindrical POC | Guided 360-degree single-ring capture, on-device stitch, gyro viewer, local library, location and heading metadata. | Owner captures three spheres on a real hike and the look-around playback feels closer to being there than the iPhone panorama does. |
| M2 Full sphere | Multi-ring capture including zenith and nadir, spherical stitch. Viewer and storage unchanged because M1 already uses the spherical format. | A full sphere captured hand-held on a summit stitches with no gap and no seam visible at normal zoom. |
| M3 Trail polish | P1 items: segment retake, exposure lock, standard export, trip grouping, capture time target. | Owner prefers Surround over the built-in Camera panorama for every viewpoint on a hike. |
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
| F9 | **Trip and peak grouping.** A sphere can be tagged with a trail or peak name. The library can be browsed by trip. | Tags are free text with autocomplete from previous tags. A trip is a named set of spheres. |
| F10 | **Capture time.** A full ring (M1) takes under 90 seconds; a full sphere (M2) under 3 minutes for a practised user. | Measured on a real hike with a stopwatch. |

### P2

| ID | Requirement |
|---|---|
| F11 | Share a viewable link or bundle with people who do not have the app. |
| F12 | Peak and landmark labels overlaid in the viewer, derived from heading, position, and a Hong Kong peaks dataset. |
| F13 | Little-planet and flat panorama renders from the same sphere for social posts. |
| F14 | Optional voice note or ambient audio recorded at the spot, played back in the viewer. |
| F15 | Weather and visibility at capture time stored with the sphere. |

### P3

| ID | Requirement |
|---|---|
| F16 | Apple Vision Pro or headset viewing. |
| F17 | Cloud backup and cross-device sync. |
| F18 | Video spheres or HDR capture. |
| F19 | Android version. |

## 5. Non-functional requirements

| ID | Requirement |
|---|---|
| N1 | **Offline first.** Every P0 and P1 feature works with no network. |
| N2 | **Battery.** A capture session, including stitch, uses under 3 percent battery on a recent iPhone. Camera and motion sensors are released the moment capture ends. |
| N3 | **Storage.** A stitched sphere plus its source shots stays under 60 MB. The user can see and reclaim space per sphere. |
| N4 | **Outdoor usability.** Capture screen is legible in direct sunlight (high-contrast overlays, large targets). All capture actions are possible with one thumb. |
| N5 | **Privacy.** No data leaves the device unless the user exports or shares. No analytics in M1 to M3. Location is stored only with the user's own spheres. |
| N6 | **Maintainability.** Stitching, viewer rendering, and storage are behind protocols so each can be replaced. Every third-party dependency has a stated reason and an exit plan. |
| N7 | **Supported devices.** iOS 17 and later, iPhone only, portrait orientation only for M1. |

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
| Camera | AVFoundation (`AVCapturePhotoOutput`) | Full control over exposure lock, focus, and still quality |
| Orientation during capture | ARKit world tracking (`ARSession` with `ARWorldTrackingConfiguration`) for camera pose; CoreMotion as fallback when ARKit tracking is limited | ARKit fuses camera and IMU and gives drift-corrected rotation, which is what guided capture needs. CoreMotion alone drifts in yaw |
| Viewer rendering | SceneKit: camera at the centre of a sphere with inward-facing normals, equirectangular texture | Simple, GPU-accelerated, 60 fps on all supported devices. Metal directly is the fallback if SceneKit limits us |
| Viewer orientation | CoreMotion `CMDeviceMotion` attitude, reference frame `xArbitraryCorrectedZVertical` | Low latency, no camera needed for playback |
| Location | CoreLocation for position, altitude, and true heading | Standard |
| Library index | SwiftData | Native, minimal boilerplate |
| Stitching | OpenCV (official iOS xcframework) via a small Objective-C++ bridge, using its cylindrical and spherical warpers, exposure compensation, and multi-band blending, seeded with ARKit rotations as initial camera poses | The only mature, well-tested open stitching pipeline available on iOS. Seeding with known rotations makes it robust for low-texture sky and sea, which is where feature matching alone fails on a summit |

Apple does not expose the built-in Camera app's panorama stitcher as an API,
and the Vision framework does not stitch, so a third-party stitcher is
unavoidable. OpenCV is the one dependency that needs an exit plan: the
stitcher sits behind a `SphereStitcher` protocol, and a pure-Swift
"projection-only" stitcher (project each shot onto the sphere using its
ARKit pose and feather the overlaps, no feature matching) is kept as a
second implementation. It is lower quality but has no dependency, and it is
the debugging baseline for whether a capture's poses are sound.

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

1. User taps Capture. Camera preview starts, ARKit session starts, exposure
   is auto until the first shot.
2. The app reads the main camera's field of view and computes a yaw step
   giving at least 40 percent horizontal overlap. With the main camera in
   portrait (roughly 47 degrees horizontal), that is about 15 shots per ring.
3. The user points at the first target (the direction they are facing; this
   becomes the sphere's front heading). The first shot locks exposure and
   white balance (F7) and records GPS and heading (F5).
4. The next target appears at the next yaw. When the current pose is within
   tolerance and angular velocity is below the steadiness threshold, a still
   is captured. The coverage ring fills in.
5. After 360 degrees, stitching runs with a progress indicator. The result
   opens in the viewer. Buttons: Keep, Retake segment (F6, M3), Discard.
6. M2 adds rings at pitch plus and minus 35 and 70 degrees, plus zenith and
   nadir, with the same mechanism.

The main camera is used, not the ultra-wide, because edge sharpness and
distortion on the ultra-wide degrade the stitch. Ultra-wide is a possible
"fast mode" later.

### 6.4 Viewer

- Sphere of radius 10 units, camera at origin, texture is the
  equirectangular image, uncovered area drawn in a neutral dark gradient.
- Camera orientation comes from device attitude, offset so that the sphere's
  front heading faces the user when the view opens. Drag adds a yaw and
  pitch offset on top of the device attitude. A "recentre" button resets the
  offset.
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
        000.heic
        000.json          ARKit rotation, timestamp, exposure values
        ...
```

`metadata.json` fields: id, capturedAt, latitude, longitude, altitude,
frontHeadingDegrees, coveredPitchMinDegrees, coveredPitchMaxDegrees,
projection ("equirectangular"), widthPx, heightPx, stitcher name and
version, device model, trip tag(s), notes.

SwiftData holds an index row per sphere (id, date, location, tags, file
size) for fast library queries. Files are the source of truth; the index can
be rebuilt from the folders.

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Hand-held parallax causes seams on near objects (rocks, railings, your own feet) | Visible stitch errors | Guide the user to rotate about the camera, not their body; keep near objects out of frame; accept that M1 targets distant scenery. Multi-band blending hides most of it |
| Featureless sky and sea defeat feature matching | Stitch fails or warps | Seed OpenCV with ARKit poses; fall back to projection-only stitcher for those regions |
| ARKit tracking degrades in bright, low-texture scenes | Wrong poses | Detect `limited` tracking state, show a warning, fall back to CoreMotion yaw with a magnetometer reference |
| OpenCV binary size (roughly 20 to 40 MB) and build friction | Slower iteration | Acceptable for a personal app; revisit only before App Store release |
| Stitch time on older devices | Frustration on the trail | Stitch at reduced resolution first for preview, full resolution in the background |
| The owner stops using it because capture takes too long | Project fails its purpose | F10 is a hard target; measure on every hike |

## 8. Open decisions

Defaults apply until you say otherwise.

| # | Question | Default |
|---|---|---|
| 1 | Which iPhone model and iOS version will you capture on? This sets the minimum OS and which camera FOV constants to verify first. | iOS 17, iPhone from the last three generations |
| 2 | Keep source shots after a successful stitch? They roughly triple storage per sphere but allow re-stitching with a better engine later. | Keep, with a per-sphere "delete sources" action and a setting to auto-delete |
| 3 | Save the stitched image to the iOS Photos app automatically? | No. Explicit export only, so Photos does not fill with duplicates |
| 4 | Apple Developer account: a free account allows installing on your own phone for 7 days at a time; a paid one allows TestFlight and 1-year installs. | Free for M1, paid before M3 |
| 5 | Build and test loop: this repository can hold the Swift project, but an iOS app can only be compiled and run on a Mac with Xcode and a physical iPhone (ARKit and the camera do not work in the simulator). | You build and run on your Mac; the agent writes code and unit tests that run on Linux where possible (metadata, projection maths, file layout) |
| 6 | Should a cylindrical sphere show the empty sky and ground as a dark gradient, or should the viewer clamp pitch so the user cannot look there? | Dark gradient, no clamp, so the missing coverage is honest and motivates M2 |

## 9. Out of scope

- Any backend, account, or sync before M4.
- Video capture.
- Editing tools beyond retake and delete.
- iPad and Mac.
