# Handoff

A macOS notch overlay for [Claude Code](https://code.claude.com). When the
agent needs a decision, the ask comes to you — approve, deny, or answer —
without hunting for the terminal.

Hover the cutout (or press ⌃⌥N) and the panel expands into a dashboard of live
sessions, pending questions, and recent work you can resume. Move away and it
collapses back into the hardware notch. On a display without a notch, it
collapses to a 200×32 pill.

Requires macOS 13+ and Claude Code.

## Run

```bash
swift run
```

Or `./scripts/dev.sh` for a packaged `Handoff.app` (menu-bar accessory, no Dock
icon) that rebuilds on save. `open Package.swift` to work in Xcode.

Quit from the menu bar icon, or Ctrl-C in the terminal.

On first launch Handoff writes Claude Code hooks into `~/.claude/settings.json`
and a bridge script under `~/Library/Application Support/Handoff`. Quit removes
the pidfile so those hooks fail fast while the app is closed; they stay
installed for next time. **Remove Claude Code Hooks** in the menu bar undoes
the install.

Resume uses Terminal.app via Automation — macOS will ask the first time. To
resume in another terminal instead:

```bash
defaults write com.swarajsaxena.handoff resumeCommandTemplate \
  'cd {cwd} && ghostty -e claude --resume {id}'
```

A Tink plays when a session flips to *needs you*. Silence it with
`defaults write com.swarajsaxena.handoff HandoffSoundEnabled -bool false`.

## How it works

There is no notch API. A borderless, transparent `NSPanel` sits at the top of
each screen, painted to match the cutout. Collapsed, it is click-through so
the menu bar still works. Expanded, it takes clicks and (via the hotkey)
keyboard focus.

Claude Code never talks to the panel directly. On launch, `HookInstaller`
registers `type: "command"` hooks that curl a loopback server inside the app
(`docs/claude-code-integration-notes.md` has the why). `SessionStore` turns
those events into the dashboard: running / needs-you / done, permission
prompts, elicitation forms, and a list of recent sessions read from
`~/.claude/projects`.

The collapsed mark is a session-lifecycle signal, not a spinner for its own
sake: visible while a session is alive, spinning while the agent is mid-turn,
badged when something needs you. Reduce Motion holds the mark still and
softens the expand animation.

| File | Role |
| --- | --- |
| `NotchMetrics` | Measures the real notch via `safeAreaInsets` + `auxiliaryTopLeft/RightArea`; fake pill otherwise. Owns all rects. |
| `NotchWindow` | The panel. Borderless, clear, status-bar level, joins all Spaces. Click-through while collapsed. |
| `NotchShape` | Inverted top corners, rounded bottom — continuous with the camera housing. |
| `NotchRootView` | Size + content animation. Dashboard or question flow when open; mark when closed. |
| `NotchController` | One window per screen, hover hysteresis, ⌃⌥N, Space-swipe hide. |
| `HotKey` | Carbon global hotkey (⌃⌥N). No Input Monitoring permission. |
| `SessionStore` | Live tasks, pending approvals/questions, recent sessions. |
| `HookServer` / `HookInstaller` | Loopback HTTP + generated `hook-bridge.sh`. |
| `ResumeLauncher` | `claude --resume` in Terminal.app (or a `resumeCommandTemplate`). |

### The one design decision that matters

The window frame **never changes**. It's a fixed transparent canvas (screen
width × expanded height). Only the SwiftUI shape inside it springs between
collapsed and expanded. Animating `NSWindow.setFrame` instead is CPU-bound,
tears, and can't do spring physics — that's the difference between "fluid"
and "janky".
