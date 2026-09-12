# Claude Code notch integration — working notes

Design record for implementing [`claude_code_notch_integration_31d912ab.plan.md`](/Users/swarajsaxena/.cursor/plans/claude_code_notch_integration_31d912ab.plan.md). This captures what I verified against the live Claude Code hooks docs (`code.claude.com/docs/en/hooks.md`, fetched 2026-07-29) and the decisions I made where the plan was ambiguous or wrong. Treat this as the source of truth over the original plan where they conflict — the plan predates verification.

## 1. The plan's two open decisions are now resolved

**"Interactive vs. headless sessions" is a non-issue — the docs settle it.** The plan worried that notch approve/deny would race a terminal's own prompt and asked me to pick a target. Verified behavior:

> "Runs when Claude Code is about to ask you for permission. **In sessions that can't show a prompt, such as background subagents in non-interactive mode, Claude Code still runs these hooks, and if no hook returns a decision, it denies the tool call.**"

So `PermissionRequest` fires for *every* session type — interactive and headless/background alike — and **fails closed (denies) by default** if nothing answers it. Consequences:

- Headless/background sessions have **no other way** to be approved except a hook. The notch isn't redundant there — it's the only UI.
- Interactive foreground sessions *do* still show a terminal prompt in parallel, so the notch button races it. That's fine: same user, whichever they click first wins, and it's strictly a convenience (don't context-switch to the terminal).
- "Never auto-allow" is already the platform default (timeout → deny), not something we need to engineer ourselves. We only need to *not break* that guarantee (see §4).

One correction to the earlier web search that fed the plan: a third-party blog claimed "`PermissionRequest` doesn't fire in headless mode" — that's wrong per the official reference above. Don't trust that claim.

**"PermissionRequest response schema" — confirmed, and the plan's suspicion was right.** It is a nested object, distinct from `PreToolUse`'s flat field:

```json
// Allow
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{...},"addPermissionRuleOnAllow":"Bash(npm *)"}}}

// Deny
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"reason shown to Claude","interrupt":false}}}
```

`updatedInput`/`updatedPermissions` only apply to `"allow"`; `message`/`interrupt` only apply to `"deny"`. We will only ever send bare allow/deny (no input rewriting, no permission-rule mutation) — keeps the MVP surface small and avoids the documented `PreToolUse`-vs-`PermissionRequest` path inconsistency around `updatedInput` (GitHub issue #19124) entirely, since we never use it.

**PermissionRequest input** (confirmed shape):

```json
{
  "session_id": "abc123", "cwd": "/Users/...", "permission_mode": "default",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {"command": "rm -rf node_modules", "description": "..."},
  "permission_suggestions": [{"type": "addRules", "rules": [...], "behavior": "allow", "destination": "localSettings"}]
}
```

No `tool_use_id` (unlike `PreToolUse`). We match/display on `tool_name` + `tool_input` only.

## 2. Elicitation schema — confirmed, official field names differ from the blog I first found

Official input (`Elicitation`, form mode — the only mode we render; URL mode is out of scope, see below):

```json
{
  "session_id": "abc123", "cwd": "/Users/...", "permission_mode": "default",
  "hook_event_name": "Elicitation",
  "mcp_server_name": "my-mcp-server",
  "message": "Please provide your credentials",
  "mode": "form",
  "requested_schema": {
    "type": "object",
    "properties": { "username": { "type": "string", "title": "Username" } }
  },
  "elicitation_id": "elicit-123"
}
```

- Question text is the top-level **`message`** field (not an `elicitation_form.fields[]` array — a third-party blog post invented that shape; ignore it).
- Form fields come from **`requested_schema`**, a restricted JSON-Schema `object` whose `properties` are `string` / `number` / `boolean`, optionally with an `enum` (→ radio) or `type: array` + `items.enum` (→ checkboxes). This matches the plan's UX mapping.
- `mode: "url"` is a second, distinct elicitation flavor (browser-based auth — server wants the user to visit a URL). **Out of scope for the notch MVP**: nothing to render as a form; punt these to the terminal by not answering (timeout → declines gracefully, no dialog suppressed). We only intercept `mode == "form"`.
- JSON object key order isn't preserved by `Codable`'s `[String: JSONValue]`. Accepted MVP simplification: sort fields by name for a stable render order. Not worth a custom ordered-dictionary decoder for the MVP.

Output (confirmed, same for both `accept`/`decline`/`cancel`):

```json
{"hookSpecificOutput":{"hookEventName":"Elicitation","action":"accept","content":{"username":"alice"}}}
```

`content` is required for `accept`, omitted otherwise. Exit/response with nothing (timeout) shows Claude Code's own dialog — same fail-open-to-terminal behavior as `PermissionRequest`'s fail-closed-to-deny, just the appropriate default for a "did the user answer" event rather than a security decision.

## 3. Architecture correction: **command-type wrapper hooks, not declarative `type: "http"`, for every event**

The plan's architecture section says `"type": "http"` hooks pointed straight at the app's loopback server. I'm deviating from that, for three concrete reasons:

1. **`SessionStart` doesn't support `http` hooks at all** — the reference is explicit: *"Only `type: "command"` and `type: "mcp_tool"` hooks are supported"* for that event. We need `SessionStart` (for the terminal-name capture the plan itself asks for), so at least one event *must* be command-type. Using command-type everywhere keeps one mechanism instead of two.
2. **Ephemeral port problem.** The app binds a random port per launch (required — no fixed port to avoid clashing with other local software). A declarative `http` hook has a literal URL baked into `~/.claude/settings.json`; if the app restarts on a new port mid-session, every *already-running* Claude Code process still has the old port compiled into hooks it read at startup. A command hook that shells out to a tiny wrapper script can instead read the current port from a file **at call time**, so a Handoff restart doesn't strand already-running sessions.
3. **Token custody.** `~/.claude/settings.json` isn't a locked-down file. A command-type wrapper script reads the bearer token from a dedicated `0600` file at call time instead of the token sitting in cleartext inside a `644` settings file that may get synced/backed up/viewed.

Net effect: `HookInstaller` writes one small generated shell script (`~/Library/Application Support/Handoff/hook-bridge.sh`) plus a `0600` JSON file (`hook-bridge.json`: `{"port": N, "token": "..."}`) plus a pidfile, and registers `"type": "command"` entries in `~/.claude/settings.json` that all invoke that one script with the event name as `$1`. Wire transport underneath is still plain HTTP over loopback (`curl` inside the script) — this only changes how Claude Code invokes the bridge, not the server we're building.

**Fast-fail is now explicit, not incidental.** The wrapper script:
```
1. If hook-bridge.json is missing or pidfile is stale → exit 0 immediately, no output (Claude Code proceeds as if no hook fired: PermissionRequest denies per §1, everything else is silently skipped).
2. Otherwise curl with --connect-timeout 1 (loopback refuses instantly if nothing's listening anyway, but this is a hard backstop) and --max-time matching the hook's own configured timeout.
3. Print whatever the server returned verbatim to stdout, exit 0.
```
This directly satisfies the plan's "fast-fail footgun" callout: a closed app can't add latency to every tool call on the machine.

## 4. Event list to install (revised from the plan)

Plan said: `SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Notification, TaskCreated, TaskCompleted, Stop, SessionEnd`. I'm adding two the plan's own UI mapping needs but forgot to list:

- **`Elicitation`** — the plan has an entire section on answering it; it has to be installed or that feature is dead on arrival.
- **`PermissionDenied`** — the plan's activity-feed mapping explicitly says "PermissionDenied ('sandbox denied network' analog)". Cheap to add, only fires in auto-mode, harmless elsewhere.

Not installing `PreToolUse` for decision control (no allow/deny/ask from us) — we only want it as an activity/note signal per the plan's mapping (`tool_input.command` for the note line). We will **not** return a `permissionDecision` from it, just observe.

Final list (revised again, see §9): `SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, PermissionDenied, Notification, Stop, SessionEnd, Elicitation`.

## 5. File plan

New, under `Sources/Handoff/ClaudeCode/`:

| File | Responsibility |
|---|---|
| `JSONValue.swift` | Small `Codable` dynamic-JSON enum (string/number/bool/object/array/null) for loosely-typed fields (`tool_input`, `requested_schema`, `content`, `permission_suggestions`) without hand-writing a struct per tool. |
| `HookPayloads.swift` | `HookEnvelope` (common fields: `session_id`, `cwd`, `hook_event_name`, `permission_mode`, …) + per-event decoded views built on top of it; response builders for `PermissionRequest`/`Elicitation` decisions. |
| `LoopbackHTTPServer.swift` | `NWListener`-based minimal HTTP/1.1 server, `127.0.0.1` only, POST-only, `Content-Length`-based body framing, size cap, generic `(HTTPRequest) async -> HTTPResponse` handler. No third-party dependency. |
| `HookServer.swift` | Owns the bearer token + ephemeral port; validates `Authorization` header + path; decodes `HookEnvelope`; forwards to `SessionStore`; encodes the returned decision. |
| `HookInstaller.swift` | Backs up + read-modify-writes `~/.claude/settings.json` (preserves unknown keys), generates `hook-bridge.sh`/`hook-bridge.json` (0600)/pidfile, `install()`/`uninstall()`. |
| `GitBranchReader.swift` | Reads `<cwd>/.git/HEAD` (+ resolves a ref line) for the branch name — no shell-out, per the plan. |
| `SessionStore.swift` | `@MainActor final class: ObservableObject`. Ingests every event into `[AgentTask]` (keyed by `session_id`) + `[ActivityEntry]` + header stats. Owns the pending-continuation registry for `PermissionRequest`/`Elicitation` (see §6). Exposes `respond(sessionId:allow:)`, `answer(sessionId:content:)`, `dismissElicitation(sessionId:)`. |

New, under `Sources/Handoff/`:

| File | Responsibility |
|---|---|
| `QuestionView.swift` | Renders one `Elicitation` form: radio (`enum`), checkboxes (array-of-enum), toggle (`boolean`), text (`string`/`number`), reusing `Theme` tokens. |

Modified:

- `DashboardModels.swift` — `AgentTask.id` becomes the session id (`String`), not a fresh `UUID()`; add `PendingInteraction` (`.permission(PermissionInfo)` / `.elicitation(ElicitationInfo)`) replacing the current bare `needsApproval: Bool`. `SampleData` stays, but only for `#Preview` blocks once real data is wired.
- `TaskRowView.swift` — `ApprovalButtons` are currently plain `Text` views with no tap handling at all (cosmetic only, per `swiftui-pro`'s correctness checklist this is a real accessibility bug — no `Button`, no VoiceOver target). Rebuilding as real `Button`s wired to `SessionStore.respond(sessionId:allow:)`, with accessibility labels. Inline `QuestionView` shown when the pending interaction is an elicitation.
- `DashboardView.swift` — `@EnvironmentObject var store: SessionStore` replaces the two `SampleData` lets; header stats computed from live state (see §7).
- `AppDelegate.swift` — builds `SessionStore` → `HookServer` → `HookInstaller` at launch (in that order: store must exist before the server can route to it); adds a "Reset Claude Code hooks" menu item calling `HookInstaller.uninstall()` per the plan's explicit-uninstall requirement; removes the pidfile on quit (`applicationWillTerminate`).
- `NotchController.swift` / `NotchWindow.swift` / `NotchRootView.swift` — thread `SessionStore` down via `.environmentObject`, since `NotchController` creates one `NotchWindow` per screen and each hosts its own `DashboardView`.

No `Package.swift` changes — everything above uses only `Network`, `Foundation`, `Security` (random token bytes), `AppKit`, `SwiftUI`, all already implicitly available.

## 6. Concurrency shape

Per the installed `swift-concurrency` skill: `Package.swift` is `swift-tools-version: 5.9` with no `swiftLanguageVersions`/strict-concurrency flags, so this target builds in Swift 5 language mode without complete data-race checking. I'm still isolating deliberately rather than relying on that:

- `LoopbackHTTPServer` / per-connection state: plain classes driven by `NWListener`/`NWConnection`'s own completion-handler API on a dedicated `DispatchQueue`; not actor-isolated (Network.framework's callback model doesn't benefit from it), but each connection object is only ever touched from its own queue callbacks.
- `HookServer.handle(_:)` is an `async` function that bridges into `SessionStore` (`@MainActor`) via a normal `await` call — the compiler inserts the hop, no manual `Task { @MainActor in ... }` needed.
- `SessionStore` is `@MainActor` (it's `@Published`-backed `ObservableObject` driving SwiftUI, so it's UI-bound by definition — matches the skill's "justify `@MainActor`" rule).
- Held-open requests (`PermissionRequest`, `Elicitation` form-mode) use `withCheckedContinuation` stored in a `[String: CheckedContinuation<Data, Never>]` inside `SessionStore`, keyed by `session_id` (permission) or `elicitation_id` (elicitation — a session could theoretically have both pending at once, so these are two separate dictionaries, not one keyed by session id). `Never` as the continuation's error type: we always resolve with *some* decision, including a synthetic "superseded"/"cancelled" one if the underlying connection drops before the user answers — never leak a continuation.

## 7. Header stat sourcing (unchanged from plan, restated for the implementation)

- **NEEDS YOU** = count of tasks with `status == .needsYou`.
- **WAITING ON YOU** = now − timestamp of the oldest `needsYouSince`.
- **RUNS / COST** = deferred; render as session count / em-dash until `TranscriptWatcher` lands (explicitly out of scope this pass).
- **SHIPPED** = best-effort count of `PostToolUse(Bash)` events whose `tool_input.command` matches `git push` / `gh pr create`, labeled as a heuristic in a code comment, not surfaced as exact.
- **Per-row progress bar/percentage** — removed entirely, see §9. There is no per-row numeric progress anymore, only the status dot + elapsed time.

## 8. End-to-end smoke test (2026-07-29)

Ran the built app against a temp-backed copy of the real `~/.claude/settings.json` (backed up first, restored byte-for-byte after) to validate the full path, not just unit-level reasoning:

- `HookInstaller.install()` correctly merges into a settings file that already had unrelated `Stop`/`Notification` hooks (a sound-on-completion setup) — those were preserved as separate matcher-group entries alongside ours, confirming the "surgical append, don't clobber" merge logic works against a real, messy, already-populated file.
- Auth: missing `Authorization` header → `401`; wrong path → `404`.
- Observation events (`SessionStart`, `UserPromptSubmit`) → immediate `{}`.
- `PermissionRequest` and `Elicitation` (form mode) correctly **hold the connection open** — verified by curling with `--max-time 2` and confirming curl's own timeout was what ended the request (~2.0s elapsed), not the server responding early. This is the core "never auto-allow" mechanism and it round-trips through the real `NWListener`/`withCheckedContinuation` plumbing, not just in isolation.
- **Bug found and fixed**: `HookServer` was setting `JSONDecoder().keyDecodingStrategy = .convertFromSnakeCase` *in addition to* `HookEnvelope`'s explicit snake_case `CodingKeys` — the two double-transform the keys (`session_id` → `.convertFromSnakeCase` → `sessionId` → looked up against the coding key's literal `"session_id"` → no match), so every field silently failed to decode and every request 400'd. Removed the redundant strategy; the explicit `CodingKeys` already do the mapping. Lesson: never combine both on the same decoder.

## 9. Removed: per-row progress percentage/bar (2026-07-29)

Shipped `TaskCreated`/`TaskCompleted` count ratio as a per-row progress bar + percentage in the first pass. Caught in review: it was fabricating precision. Two problems, not one:

1. `TaskCreated`/`TaskCompleted` only fire for Claude Code's internal Task-tool/subagent tracking, which most ordinary sessions never touch — so `progress` stayed `nil` (rendered `—`) for effectively every session, the whole time it ran.
2. Worse: `handleStop` had `task.progress = task.progress ?? 1` — once a session ended with no real task data (the common case), it silently backfilled **100%**. That number looked like "all subtasks completed" but actually meant "nothing was ever measured, and now it's over." Confirmed live: a real session that finished with zero `TaskCreated`/`TaskCompleted` events rendered a green 100% bar, indistinguishable from one that had actually tracked and completed real subtasks.

Decision: remove it rather than patch the fallback (e.g. showing `—`/a checkmark instead of `1`) — a signal that's essentially always absent isn't worth a UI column, and keeping `TaskCreated`/`TaskCompleted` installed with nothing genuine to show would just be dead weight. Removed end-to-end:

- `AgentTask.progress`, `SessionStore.taskProgressCounts`/`handleTaskProgress`, and the `handleStop` fallback line.
- `TaskRowView`'s `ProgressBar` view and the percentage `Text` — the trailing column is now just the elapsed-time `Text`.
- `TaskCreated`/`TaskCompleted` dropped from `HookEventName`, `HookInstaller.managedEvents`, and the now-unused `task_id`/`task_subject` fields dropped from `HookEnvelope`.
- `Theme.progressTrack` (now-unused color token) removed.

If a real progress signal shows up later (e.g. parsing the transcript for a todo-list length), reintroduce it then — don't resurrect a placeholder.

## 10. Explicitly not doing this pass

Matches the plan's own "out of scope": `TranscriptWatcher`, `UsageAggregator`, `model` field, tok/s, `$` cost, non-MCP interactive prompt answering, Claude.ai login, Console Usage API, other agents (Cursor/Codex).

## 11. Fixed: rows stuck on NEEDS YOU after answering in the terminal (2026-07-29)

A session answered at Claude Code's own prompt stayed pinned to `.needsYou` forever, with a live Approve/Deny row, while the session visibly carried on working. §1 predicted the race ("whichever they click first wins") but nothing actually handled *losing* it. Three independent causes, all fixed:

1. **The protocol never says "that was answered elsewhere."** There's no counterpart event to `PermissionRequest`/`Elicitation`. So `SessionStore` now infers it from the events that can only be emitted *after* a decision was made — `PostToolUse`, `PermissionDenied`, `UserPromptSubmit`, `Stop`, `SessionEnd` (`HookEventName.provesInteractionResolved`) — and releases whatever it was holding. `PreToolUse` is excluded on purpose: each hook is a separate `curl`/connection, so it can land *after* the `PermissionRequest` for the same tool call and would cancel a request that's genuinely still open. `Notification` is excluded because `permission_prompt` fires *alongside* a live request.
2. **Connection loss was undetectable.** `HTTPConnection` stopped re-arming `connection.receive` the moment a request was dispatched, and an outstanding receive is the only way Network.framework reports a peer FIN — a half-closed connection sits at `.ready`, so `stateUpdateHandler` never fires. The `onCancel` path from §6 was therefore dead code for the entire hold. Now a read stays outstanding for the life of the connection (post-dispatch bytes are discarded; one request per connection, no pipelining), so a dead `curl` cancels the context as designed.
3. **Resolution cleared the row only as a side effect of resuming the continuation.** Both `resolve*` methods early-returned on `guard let continuation`, so once a request was resolved by any other path, `pendingInteraction` was stranded and the Approve/Deny buttons became permanent no-ops. Row cleanup now runs unconditionally, and it won't revive a `.done` task or resurrect a trimmed one.

Also closed a continuation leak while in there: a second `PermissionRequest` for the same session overwrote the first in `permissionContinuations`, dropping it unresumed (leaked continuation, and its `curl` hanging for the full 600s `--max-time`). The superseded one is now resumed with an empty decision — which, per §1, fails closed to a deny.
