# Mobile page transitions

Server-list ↔ workspace navigation uses one Rust motion model on iOS and Android.
The workspace travels one screen width; the list beneath it travels 30%.
The iOS back chevron lives before the existing tab menu. Android keeps system Back.

## Native reference

[The UIKit probe](../../../tests/ios/navigation_probe.m) creates an ordinary
`UINavigationController`, pushes a second screen, and pops it. It records public
transition-coordinator timing and presentation-layer positions with `CADisplayLink`.
No private Apple API or copied UIKit implementation is used.

Measured on the iOS 26.3 iPhone 17 Pro simulator at 60 Hz:

- Both coordinator durations: **0.350 s**.
- Both visible spring tails: about **28 frames / 0.467 s** from first movement.
- Background travel: **121 pt** for a **402 pt** viewport (rounded 30%).
- Fit to moving presentation samples: critically damped response,
  angular frequency **2π / 0.3**, initial normalized presentation velocity **8.78**.

The Rust test compares against native positions, with a 0.35 pt tolerance at
402 pt width. Sampling is based on absolute time, so frame rate does not change
speed. This is a measured reproduction of that UIKit runtime, not a guarantee
that every iOS release uses an identical private animation implementation.

For comparison, [Flutter's Cupertino page transition](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/cupertino/route.dart)
uses an estimated 500 ms duration and one-third background travel. Its dialog
spring is a different transition; we do not use it for page navigation.
Apple documents [navigation controllers](https://developer.apple.com/documentation/uikit/uinavigationcontroller)
and [transition coordinator timing](https://developer.apple.com/documentation/uikit/uiviewcontrollertransitioncoordinatorcontext/transitionduration).

<details>
<summary>Reproduce the native measurement</summary>

Compile `tests/ios/navigation_probe.m` into a temporary simulator `.app` using
`xcrun --sdk iphonesimulator clang`, the simulator SDK, an
`arm64-apple-ios17.0-simulator` target, ARC, and the UIKit, QuartzCore and
CoreGraphics frameworks. Its Info.plist needs an executable name, bundle ID,
`CFBundlePackageType=APPL`, `UIDeviceFamily=[1,2]`, and an empty `UILaunchScreen`.
Install it with `xcrun simctl install`, then run `xcrun simctl launch --console`.
`SAMPLE` lines contain direction, elapsed seconds, outgoing X, incoming X, and
viewport width. Account for the first presentation frame's scheduling delay
when comparing the two runs; callback time is not first visible movement.

</details>

## Rendering and lifecycle

Godot retains each complete page through the existing `RetainedPresentation`
renderer. It renders those input-free views once on the GPU, then moves their
textures using `ScenePageTransition`. There is no per-frame CPU screenshot.
Real navigation state changes once; repeated connection updates do not restart
motion. An overlay absorbs input until completion. Resize, focus loss, and a
new destination dispose of the retained views. The live destination is already
in place when the overlay disappears; no session or connection is closed.

Acceptance steps: [UI-09](../../../tests/e2e/controls.md#ui-09--workspace-manager-connections-and-mobile-start).
