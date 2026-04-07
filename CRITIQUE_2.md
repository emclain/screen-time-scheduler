# CRITIQUE_2 — Implementation Realism Review of PLAN_A / PLAN_B / PLAN_C

Reviewer lens: senior iOS/macOS engineer with shipping FamilyControls/DeviceActivity experience. Grading each plan on (1) API-constraint reality, (2) build/entitlement complexity, (3) honesty about AFMT preservation, (4) operational realism for a non-dev family, (5) future adaptability, and finally picking a winner or hybrid.

## PLAN_A — Native Swift + CloudKit (hybrid enforcement)

### 1. Does it work under RESEARCH.md constraints?
Mostly yes, but the load-bearing assumption — that the user will designate "exactly one window per day" as `.systemDowntimeMirror` and manually mirror it in Settings — is a fiction dressed up as an architecture decision. RESEARCH §2 is explicit: there is no public API to toggle system Downtime, and Shortcuts cannot flip it. PLAN_A quietly concedes this and labels the third-party shields as "additional windows," but never confronts the consequence: any window that is not the hand-configured system one does not have native AFMT. The "Ask-For-More-Time preserved" section is misleadingly titled — it is preserved for exactly one window and reimplemented for the rest. RESEARCH §7 already calls this out ("Only by leaving system Downtime alone OR reimplementing the request flow in-app") and PLAN_A chooses both simultaneously without admitting the asymmetry in the headline.

The cross-device token story (`TokenBundle`) is correct and honest: tokens are device-scoped and each device runs its own picker. Good.

The "daily 00:01 recovery anchor" is the right instinct — matches community wisdom that DAM callbacks are flaky — but registering "seven schedules per window" plus per-window anchors will push against DeviceActivity's undocumented schedule count ceiling fast. For N windows this is 7N+1 registered schedules per device; at N=5 windows this is 36 schedules, which is in the zone where community reports (forum 742131) start showing dropped callbacks. PLAN_A does not budget for this.

### 2. Build complexity and entitlement burden
Large. Targets: multiplatform app, 3 extensions (DAM, ShieldConfiguration, ShieldAction), macOS LaunchAgent daemon. ~12 top-level Swift modules. The `com.apple.developer.family-controls` entitlement is required on the app AND all three extensions on both platforms — each a separate reviewer conversation. CloudKit schema with 6 record types + subscriptions + CKShare to a child Apple ID. Realistic estimate: 6–10 weeks of focused work for a solo senior engineer plus 2–6 weeks of entitlement review.

### 3. AFMT honesty
Dishonest by omission. AFMT is preserved for one window and reimplemented for the others. The plan also glosses over the reviewer risk that a ShieldActionExtension mimicking Apple's Ask-For-More-Time sheet is exactly the kind of "duplicating system UI" pattern App Review dings. Listed under "Open risks" #2 but treated as a minor caveat rather than a core feasibility threat.

### 4. Operational realism
Poor for a non-dev family. Setup requires entering Family Controls prompts on 3 devices, running FamilyActivityPicker on each device per window group, CKShare acceptance on a child Apple ID (known to be flaky with under-13), pairing the Mac daemon, and manually configuring system Downtime to match one designated window. Failure modes #3 ("Token drift after iOS upgrade") and #6 ("iCloud account change → CK zone resets; re-onboarding required") are catastrophic from a non-dev parent's perspective.

### 5. Adaptability
High. Once built, adding new window types, enforcement modes, and overrides is cheap. This is PLAN_A's real strength.

---

## PLAN_B — Mac-as-Authoritative-Server

### 1. Does it work under RESEARCH.md constraints?
PLAN_B gets the hard constraint right: the Mac never dereferences tokens; it only references them by `TokenSetId`. This is the correct design — better than PLAN_A's `TokenBundle` language, which blurs the same idea. Point 4 ("Adding a new app to a token set is the only operation requiring physical access to the child device") is the honest statement PLAN_A avoids.

The AFMT section also explicitly says "This tradeoff must be confirmed with the user. If every window must use Apple's native flow, the only honest answer is that Apple does not expose this and the requirement cannot be fully met without MDM (see PLAN_C)." This is the most intellectually honest paragraph in any of the three plans.

Load-bearing assumptions that might be wrong:
- (a) "Tailscale HTTPS in-home fast lane" — a DeviceActivityMonitor extension is not going to do a Tailscale HTTPS request reliably in its 30s background budget; Tailscale's network extension may not even be loaded when the monitor wakes. The fast-lane helps the controller UI, not enforcement. The plan conflates the two.
- (b) The "5-minute APNs heartbeat" is optimistic: silent pushes to DAM extensions are rate-limited by iOS and will be throttled under low power; 5 minutes is a floor, not a ceiling.
- (c) `stsd` running on macOS as a Swift CLI that invokes FamilyControls `.individual` — FamilyControls is an app framework, not a daemon framework, and `.individual` auth UI requires an app context. The daemon cannot itself hold the authorization; the macOS Controller app must do it and the daemon must talk to a helper XPC. PLAN_B is loose about this.

### 2. Build complexity
Medium-high. Three targets is a lot but fewer extensions than PLAN_A — though the AFMT bridge implies a ShieldAction extension that PLAN_B glosses over. SQLite + CloudKit + Tailscale + LaunchAgent: a lot of moving infra, but each piece is well-understood. Entitlement burden the same as PLAN_A.

### 3. AFMT honesty
The most honest of the three. The "Confirm with user" flag and explicit pointer to PLAN_C is what I want to see in a spec.

### 4. Operational realism
Medium. The Mac-as-brain architecture matches the household's actual setup (always-on Mac, flaky parent iPhone) — this is the right call. Bootstrap is 7 steps across 3 devices; still heavy but each step is discrete. Recovery from CKShare-to-child breakage has an explicit QR fallback.

### 5. Adaptability
High. Token-set abstraction means new windows never require touching tokens. Swapping CloudKit for a different transport is straightforward because the daemon owns intents.

---

## PLAN_C — Configuration Profiles + Shortcuts

### 1. Does it work under RESEARCH.md constraints?
PLAN_C correctly identifies that the ONLY way to truly preserve native AFMT is to drive Apple's own system Downtime, and the ONLY way to drive that off-device is via a `com.apple.screentime` profile payload on a supervised device. That part is right. But the plan steps on two rakes:

(a) Supervision requires a factory wipe via Apple Configurator 2 and leaves a permanent "Supervised by ..." banner. The plan says this but dramatically underweights it. A consumer family with a teenager is not going to accept a permanent supervision banner on a personal iPhone they paid for. Listed as Open risks #1 but the severity is "this kills the approach," not "worth noting."

(b) The MDM APNs vendor cert "is the painful part — you need an MDM vendor cert which Apple does not freely issue to individuals." Then the plan proposes NanoMDM anyway. This section is **wrong**: without the MDM vendor cert, NanoMDM cannot send commands, and the Configurator-over-Wi-Fi fallback requires the iPhone to be on the home LAN and paired — for a teenager out of the house all day, profile rotation simply does not happen. PLAN_C's own Open risks #2 admits this breaks the whole use case for kids not on home Wi-Fi. That is not a "risk"; it is a disqualifying constraint.

(c) Profile install over MDM is asynchronous and can take tens of seconds to minutes to apply; rotating profiles every window boundary (say at 09:00 sharp) means the new window will be late by an indeterminate amount each time. The plan does not quantify this.

### 2. Build complexity
By far the lowest code volume (~500 LOC). No FamilyControls entitlement, no extensions, no CloudKit. BUT the non-code complexity is enormous: MDM infrastructure, APNs vendor cert (not obtainable), Apple Configurator supervision workflow, profile signing key custody. The headline "small auditable codebase" is true but misleading — the operational surface area is larger than either A or B.

### 3. AFMT honesty
The cleanest of the three on this axis. PLAN_C is the only plan where AFMT is preserved by construction, not by engineering effort. If (and only if) the supervision + MDM cert problems were solvable for this household, PLAN_C would be the obvious winner.

### 4. Operational realism
Worst of the three for this household. Factory-wiping a teen's iPhone is a non-starter in most families; the supervision banner changes the device's character. "Strongest for households where the kids' iPhones are routinely on home Wi-Fi, weakest for teens out of the house all day" — the user's stated requirements don't narrow to home-Wi-Fi-only kids.

### 5. Adaptability
Low. "No fine-grained per-app picking since we skip FamilyActivityPicker." If the user ever wants per-window app sets, PLAN_C cannot deliver it without morphing into A/B. Hard ceiling.

---

## What I would actually build: PLAN_B core + targeted PLAN_A borrowings; PLAN_C rejected

### Winner: PLAN_B as the skeleton
PLAN_C is out. Supervision wipe + unobtainable MDM vendor cert + home-Wi-Fi-only enforcement make it infeasible for a consumer family with a mobile teen, regardless of its elegance on the AFMT axis. Its own Open risks §1 and §2 are disqualifying, not cautionary.

Between A and B, PLAN_B's Mac-authoritative architecture is the correct match for the household profile. The `TokenSetId` indirection is a cleaner formulation than PLAN_A's `TokenBundle`. PLAN_B is also the only plan honest about AFMT in writing, which is a proxy for how the rest of the spec will hold up under pressure.

### Specific borrowings from PLAN_A
1. PLAN_A's module layout is more developed than PLAN_B's component list and should be adopted as the Swift target structure, substituting PLAN_B's `stsd` for PLAN_A's `macOSDaemon/`.
2. PLAN_A's daily 00:01 recovery anchor for re-registering DAM schedules is a good belt-and-braces tactic that should replace PLAN_B's "5-minute heartbeat" (rate-limit-optimistic; a daily anchor is deterministic).
3. PLAN_A's ShieldActionExtension design for the in-app AFMT bridge is more fleshed-out than PLAN_B's vague "custom ShieldConfiguration extension whose primary button is Request more time." Use PLAN_A's extension shape under PLAN_B's intent/override data model.

### Corrections both plans need before building
1. **Stop claiming AFMT is "preserved."** Adopt PLAN_B's honesty: AFMT is preserved only for the one window the user mirrors in Apple's own Settings; all other windows use an in-app imitation. Put this in the product description, not buried in a tradeoff section.
2. **The macOS daemon cannot hold FamilyControls authorization.** FamilyControls `.individual` auth lives in the Controller app on macOS; the daemon talks to a helper via XPC.
3. **Budget for DeviceActivity schedule count.** Don't register 7 schedules per window per day. Register one per window and branch on weekday inside `intervalDidStart`, consulting the local cache. PLAN_A's 7x multiplication is a reliability liability.
4. **Drop Tailscale from the enforcement path.** Keep it only for the Controller UI's fast-lane override writes. Enforcement paths must assume CloudKit + local cache only.
5. **Plan for CKShare-to-child failure from day 1.** Build the QR-bootstrap fallback as the primary path — CKShare to child Apple IDs has been unreliable enough that treating it as primary is unwise.
6. **Define the "one manual system Downtime window" as a product feature, not a workaround.** Onboarding should walk the parent through configuring it in Settings and periodically verify it hasn't drifted.

### Things I'd NOT build (yet)
- Mac-side shield enforcement. macOS Screen Time API parity is uneven. Ship iPhone enforcement first; treat Mac as brain only.
- The Tailscale HTTPS path. YAGNI for v1; CloudKit + local cache is enough.

### Effort estimate
8–12 weeks for one senior engineer, plus 2–6 weeks entitlement review in parallel. The critical-path risks are CKShare-to-child reliability and App Review tolerance of the in-app AFMT bridge UI — both of which need spikes in week 1, not week 8.
