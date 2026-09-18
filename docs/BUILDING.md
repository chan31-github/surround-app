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

## Running the core tests

```
cd Packages/SurroundCore
swift test
```

These cover the geometry, capture plan, alignment logic, projection stitcher,
ring refinement (alignment, gain, seams), metadata and XMP code, and need no
device. Set `SURROUND_DUMP=<dir>` to have the stitcher tests write their
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
| `Surround/Library` | SwiftData record, file store, library and detail screens |
| `Surround/Location` | Position and compass heading |
| `project.yml` | XcodeGen project definition, including Info.plist keys |
