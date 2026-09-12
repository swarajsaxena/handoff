# Handoff

A minimal macOS notch-expansion prototype. Hover the notch, it grows and says
**Hi Swaraj**. Move away, it collapses back into the cutout.

## Run

```bash
cd /Users/swarajsaxena/github/notched
swift run
```

Quit from the small menu bar icon, or `Ctrl-C` in the terminal.

You can also `open Package.swift` to work on it in Xcode.

`NotchRootView` is wired for [Inject](https://github.com/krzysztofzablocki/Inject) hot
reload — with the [InjectionIII](https://github.com/johnno1962/InjectionIII) app running
and attached, edits to that view apply live without restarting `swift run`.

## How it works

There is no notch API. This is a borderless, transparent `NSPanel` pinned to the
top of the screen, drawn above the menu bar, painted pure black so it appears
continuous with the physical cutout.

| File | Role |
| --- | --- |
| `NotchMetrics` | Measures the real notch via `safeAreaInsets` + `auxiliaryTopLeft/RightArea`; falls back to a 200×32 pill on non-notch displays. Owns all rects. |
| `NotchWindow` | The panel. Borderless, clear, `CGShieldingWindowLevel()`, joins all Spaces, click-through. |
| `NotchShape` | The shape with *inverted* top corners and rounded bottom corners. |
| `NotchRootView` | SwiftUI content. Animates size + text. |
| `MouseTracker` | Global `.mouseMoved` monitor (no permissions needed) since the window is click-through. |
| `NotchController` | One window per screen, rebuilds on display changes, drives hover state with hysteresis. |

### The one design decision that matters

The window frame **never changes**. It's a fixed, oversized transparent canvas
(screen width × ~230pt). Only the SwiftUI shape inside it springs between
collapsed and expanded. Animating `NSWindow.setFrame` instead is CPU-bound,
tears, and can't do spring physics — that's the difference between "fluid" and
"janky".

## Knobs

- `NotchMetrics.expandedSize` — panel dimensions.
- `NotchRootView` spring `response` / `dampingFraction` — feel.
- `NotchShape` radii — 8 top / 24 bottom currently.

## Next steps when you want interaction

Set `ignoresMouseEvents = false` in `NotchWindow` and wrap the hosting view in
a container `NSView` that overrides `hitTest(_:)` to return `nil` outside the
current notch rect. Otherwise the full-width window swallows every menu bar
click.
