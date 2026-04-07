# CRITIQUE_1 — Screen Time Scheduler Design Review

Reviewer: senior software architect. Three plans reviewed against the six stated requirements and against what RESEARCH.md actually says is possible.

## PLAN_A — Native Swift + CloudKit (hybrid mirror + shield)

### 1. Requirement coverage
- Multiple Downtime windows/day: **partial**. Only the secondary windows are genuinely under program control via `managedSettingsShield`. The "dominant" window is a `.systemDowntimeMirror` that the code does not enforce — it merely *hopes* the human configured system Downtime identically. So "multiple windows" works, but at most one of them has AFMT.
- One-day override: **met**. `Override` is append-only with `expiresAt = next local midnight` and `OverrideEngine.effectiveWindows(for:)` resolves it at `intervalDidStart`.
- Parent + child in Family Sharing: **met with friction**. Sibling app + FamilyControls `.child` + CKShare; RESEARCH §4 and Plan_A Open Risk #5 both flag CKShare-to-child tightening.
- Control from iPhone and Mac: **met**. Multiplatform SwiftUI plus a LaunchAgent daemon.
- Offline parent iPhone: **met**. Mac daemon is a first-class writer; "any device can author".
- Preserve Apple AFMT: **partially met, and misleadingly so**. Only the single mirrored window keeps native AFMT. Every other window gets a reimplemented bridge. The plan's prose is candid but the architecture label oversells it.

### 2. Simplicity / surface area
Largest of the three. Three Xcode extensions (DAM, ShieldConfig, ShieldAction), GRDB cache, CloudKit schema with 6+ record types, a SyncCoordinator actor, ScheduleCompiler, OverrideEngine, TokenResolver, PushRouter, plus a separate macOS LaunchAgent target. ~15 subsystems. Every one is a place to leak bugs.

### 3. Interop with system Downtime and AFMT
The hybrid conflates two enforcement regimes on the same device. A `.systemDowntimeMirror` window is an *unverified assertion* — the code cannot read back Apple's system Downtime, so the "Periodic reconciliation reminder" in Failure modes #8 is the only consistency mechanism, and it is human-in-the-loop. Meanwhile the ShieldActionExtension reimplements AFMT on top of CloudKit; the "<10s round trip" target is optimistic given APNs silent-push latency and DAM extension wake semantics.

### 4. Adaptability
Best of the three. Per-window app sets, vacation mode, school-day rules, sibling iPads, more children all fall out naturally: the data model is already structured for it (`groupId: WindowGroupID`, `allowRequests: Bool`).

### 5. Other principles
- Failure isolation: weak. DAM extension, ShieldAction, sync coordinator and Mac daemon all share the CloudKit schema; a migration bug cascades everywhere.
- Testability: moderate. OverrideEngine and ScheduleCompiler are pure and testable; the extensions and CK sync are not.
- Observability: minimal. Only "Logging.swift" mentioned. No structured metrics, no health endpoint.
- Security: CloudKit private DB + CKShare is reasonable; tokens are never synced. Good.
- Deployability for non-developer: **poor**. Apple Developer Program, FamilyControls entitlement review, three extensions provisioned, App Group, LaunchAgent plist, Shield custom UI. Non-developer cannot install this.

### 6. Top risks
1. Entitlement review may reject a ShieldActionExtension that imitates AFMT. If rejected, the plan collapses to "one native window + nothing else".
2. The `.systemDowntimeMirror` contract is a silent handshake with the human; drift is invisible until a child complains.
3. Token portability UX: every device must run `FamilyActivityPicker` once per group, and again whenever an iOS upgrade invalidates tokens.

---

## PLAN_B — Mac-as-authoritative-server

### 1. Requirement coverage
- Multiple windows/day: **met**. Intent records compile windows into `{deviceId, windowId, startUTC, endUTC, mode}` with `mode ∈ {systemDowntime, thirdPartyShield, off}`.
- One-day override: **met**. `Override(kind, expiresAtUTC)` with midnight pruning; TTL recomputed per timezone.
- Parent + child Family Sharing: **met**. Sibling app on child in `.child` mode, CKShare per-child zone, TokenSet captured locally on child.
- Control from iPhone and Mac: **met**. Thin client controller writes to daemon HTTPS first, CloudKit fallback.
- Offline parent iPhone: **met, and explicitly designed for**. "Parent iPhone offline + Mac online (the common case): fully covered."
- Preserve AFMT: **partial, honestly labeled**. Primary window uses system Downtime → native AFMT intact. Secondary windows use a bridge. The plan ends with "This tradeoff must be confirmed with the user" — the only plan that refuses to paper over this.

### 2. Simplicity / surface area
Medium. One Swift CLI (`stsd`), one multiplatform app, one extension target. Clean separation: daemon = brain, app = UI, extension = muscle. SQLite on the Mac is the canonical store; CloudKit and Tailscale are transports, not sources of truth. The `Intent` abstraction (pre-compiled 48h horizon) is the single best design idea across all three plans.

### 3. Interop with system Downtime and AFMT
Identical structural tradeoff as Plan A for secondary windows, but the separation is cleaner: the `mode` enum on each Intent makes it explicit which windows do and do not retain native AFMT. There is no silent "mirror" fiction.

### 4. Adaptability
Excellent. Per-window app sets → `TokenSet` already keys by device. Vacation mode → one long Override. More children → add `Profile(kind=child)` + new CKShare zone. Sibling iPad → add `Device` row, same profile. School-day rules → `weekdayMask` already present.

### 5. Other principles
- Failure isolation: strongest of the three. Daemon crash → launchd restart; helpers run from 48h cache. CloudKit down → Tailscale path. Both down → cached intents still fire.
- Testability: high. Daemon is a headless CLI with SQLite; unit-testable. Intent compilation is a pure function.
- Observability: best articulated. Structured logs in `~/Library/Logs/stsd/`, `Heartbeat` table.
- Security: CKShare + encrypted TokenSet blobs; Tailscale replaces internet exposure. Weakness: HTTPS endpoint auth mechanism is unspecified.
- Deployability: still requires Developer Program + entitlement + multiple targets + Tailscale. The bootstrap runbook is the most complete of the three.

### 6. Top risks
1. Same entitlement risk as Plan A; same fragility around the bridge.
2. Single Mac = SPOF. The 48h horizon softens this but new overrides cannot be issued while the Mac is down.
3. macOS DeviceActivity parity may force a degraded code path on the Mac.

---

## PLAN_C — Configuration profiles + Shortcuts glue

### 1. Requirement coverage
- Multiple windows/day: **met technically, but only by profile rotation**. "Only one Downtime window per day is expressible in a single payload"; N+1 profiles are rotated by a launchd timer. Works only as long as the iPhone is reachable by MDM at each transition.
- One-day override: **met elegantly**. Override is itself a profile swap; midnight launchd restores normal rotation. Best override design of the three.
- Parent + child in Family Sharing: **partially met**. The plan sidesteps Family Sharing entirely for the schedule transport, using supervision/MDM instead. Technically covers the accounts but the answer is "wipe and supervise each iPhone".
- Control from iPhone and Mac: **partially met**. The iPhone is reduced to two Shortcuts hitting `https://mac.tailnet.ts.net:8443/override`. No real editing UI; the schedule lives in `schedule.yaml` on the Mac.
- Offline parent iPhone: **met** — iPhone is not on the hot path at all.
- Preserve AFMT: **fully met, and the only plan where that is true**. The only thing installed is Apple's native Downtime payload, so every user-facing surface — including "Ask For More Time" routing through Family Sharing APNs to the parent — is Apple's own code. Zero imitation.

### 2. Simplicity / surface area
Smallest by far: ~500 LOC, Python + launchd + YAML. No Xcode, no entitlements, no extensions, no sync protocol to design.

### 3. Interop with system Downtime and AFMT
Perfect interop by construction. The plan does not *interoperate* with system Downtime — it *is* system Downtime, parameterized externally. AFMT is preserved by the absence of any competing shield.

### 4. Adaptability
Weakest. Open Risks #5 is frank: "No fine-grained per-app picking since we skip FamilyActivityPicker... If the user wants per-window app sets, this approach can't deliver it without re-introducing FamilyControls (and losing the headline)." Adding a teenager who leaves the LAN breaks the Wi-Fi-Configurator fallback.

### 5. Other principles
- Failure isolation: good for Mac (local `profiles` CLI), poor for iPhones (MDM path required; "Mac powered off... override persists past expiry — soft failure, user-visible").
- Testability: high for profilegen (pure function of YAML), low for the MDM delivery path.
- Observability: append-only JSON log and `/status` endpoint. Adequate.
- Security: Open Risks #6 correctly flags that the profile-signing key is a very high-value secret — compromise means "ability to install arbitrary profiles" on the family's phones. Qualitatively more dangerous than any secret in Plans A or B.
- Deployability for non-developer: **catastrophic**. Factory-wipe each iPhone, MDM vendor cert that "Apple does not freely issue to individuals", Tailscale, launchd, hand-edited YAML. A developer must own this forever.

### 6. Top risks
1. **The MDM vendor cert problem.** Without it, OTA profile rotation is impossible and the fallback is "child's iPhone must be on home Wi-Fi at every window boundary". For any teenager, this invalidates the architecture.
2. **Supervision friction.** Visible "Supervised by..." banner and a device wipe.
3. **No per-app granularity**: cannot express "block social apps from 9–12 but allow Duolingo".

---

## Head-to-head ranking

| Criterion | A | B | C |
|---|---|---|---|
| Multiple windows | Partial (1 mirrored) | Full | Full (via rotation) |
| One-day override | Good | Good | Best |
| Family Sharing fit | OK | OK | Poor (bypasses it) |
| iPhone + Mac control | Good | Best | Weak (Shortcuts only) |
| Offline iPhone | Good | Best | Best |
| AFMT preserved | 1 window | 1 window | **All windows** |
| Simplicity | Worst | Middle | Best |
| Adaptability | Best | Best | Worst |
| Non-dev deployability | Poor | Poor | Worst |
| Security blast radius | Moderate | Moderate | Largest (signing key) |

**Ranking: B > A > C.**

- Plan B dominates Plan A on every axis except extension count. Its `Intent`-compilation abstraction is the single cleanest idea across the three plans, its offline story directly addresses the stated parent-iPhone-offline requirement, and it is the only plan intellectually honest about the AFMT tradeoff without burying it under a "mirror" fiction.
- Plan A is a respectable native-first design that would be the right answer for a full product. For a household-scale personal tool, its surface area is disproportionate.
- Plan C is the most *interesting* plan and the only plan that fully satisfies the AFMT requirement. It fails the "manage family" and "non-developer" dimensions and rests on an MDM cert the user cannot easily obtain.

## Recommendation

**Adopt PLAN_B as the baseline, with one targeted borrow from PLAN_C.** Specifically:
1. Build Plan B's Mac daemon, Intent-compilation pipeline, sibling child app, and CloudKit+Tailscale transport.
2. For the **primary** nightly Downtime window, do not model it as a `systemDowntime`-mode Intent — instead, borrow PLAN_C's idea and ship a signed configuration profile the user installs once on the Mac (and optionally on the parent iPhone), parameterizing Apple's native Downtime. That keeps Plan B's honest "native AFMT only on this one window" story but removes the silent-handshake risk in Plan A #8.
3. Defer PLAN_C's full MDM/supervision path unless the user confirms they will never need per-app granularity.
4. Before any code: resolve the user-facing question Plan B raises — "This tradeoff must be confirmed with the user." If the answer is "AFMT must work on every window", none of these plans satisfy the requirement and the project should not start.
