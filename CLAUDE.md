# Surround

iOS app for capturing and viewing photo spheres of hiking viewpoints. Read
`docs/SPEC.md` for requirements and architecture, `docs/BUILDING.md` for the
build loop.

## Working in this repository

- There is no Swift toolchain or Xcode in the remote environment. Code
  written here is compiled by the owner on a Mac. Write conservative Swift,
  prefer APIs you are sure exist, and say clearly in your summary that a
  change is uncompiled.
- Platform-independent logic goes in `Packages/SurroundCore` with unit tests.
  Anything needing UIKit, ARKit, SceneKit, CoreMotion, SwiftData or CoreImage
  goes in the `Surround` app target.
- The Xcode project is generated from `project.yml` by XcodeGen and is not
  committed. New source files under `Surround/` are picked up automatically;
  new Info.plist keys go in `project.yml`.
- The app target uses Swift 6 language mode with main-actor default
  isolation and approachable concurrency. Everything is main-actor unless
  marked `nonisolated`; mark helpers that background work calls (stitching,
  image conversion, file store) `nonisolated`, and mark value types that
  cross into background tasks `Sendable`.

## Conventions that must not drift

- World frame: right-handed, +Y up, forward at yaw 0 is -Z, yaw increases
  clockwise seen from above (compass sense), pitch positive upwards. See
  `Geometry.swift`.
- Camera frame is ARKit's: +X image right, +Y image up, looking along -Z.
  Stills are stored in the sensor's landscape orientation with no
  orientation tag; the stitcher uses the recorded rotation.
- Equirectangular layout: column 0 is yaw -180, centre column is yaw 0 (the
  sphere's front), row 0 is the zenith. See `Equirectangular.swift`.
- Every stitching engine implements `SphereStitcher`; the projection engine
  in the core package is the baseline and fallback.
- Files on disk are the source of truth; the SwiftData index is rebuildable.
