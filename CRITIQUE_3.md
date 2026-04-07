# CRITIQUE_3 — Staff Engineer Review of PLAN_A / PLAN_B / PLAN_C

## 1. Interoperability with Apple's existing Screen Time Downtime

**PLAN_A (hybrid)** — Fights the system more than it admits. The `.systemDowntimeMirror` enum case is not a real integration: it is a *convention* that the user manually mirrored a window into Settings. The app has no read-back of the system schedule, so drift is inevitable (acknowledged weakly in risk 6). Meanwhile `.managedSettingsShield` windows coexist with the system Downtime window, meaning two independent enforcement layers operate on the same device with no arbitration. When both fire (e.g. a shield window overlapping the system window because the user edited one and not the other), clearing the third-party shield at `intervalDidEnd` will not unlock the system Downtime, which will confuse users into thinking the app is broken. It composes *adjacent to* Downtime, not *with* it.

**PLAN_B** — Same fundamental hybrid as A, but more honest about it ("This tradeoff must be confirmed with the user"). The Mac-as-brain design does not actually improve interop with system Downtime — the daemon still cannot toggle it. B at least separates `mode ∈ {systemDowntime, thirdPartyShield, off}` as first-class intent rather than a mirror fiction, but the `systemDowntime` mode is still a no-op that relies on the user having configured Settings correctly. Cleaner bookkeeping than A, same underlying fight.

**PLAN_C** — The only plan that actually composes with system Downtime because it *is* system Downtime. Every installed profile writes `com.apple.screentime`, and the `PayloadIdentifier` collision trick guarantees atomic replacement with no stacking. There is exactly one source of truth (Apple's own). The price (PLAN_C risks 1-2) is supervision and an MDM vendor cert, which is substantial — but from a pure interop standpoint C is the only plan that does not fight the OS.

## 2. Adaptability to future requirements

- **More children / new devices**: A and B both require a full sibling-app install, FamilyControls `.child` approval, CKShare acceptance, and a `FamilyActivityPicker` round-trip per device to capture tokens. C requires a one-time Configurator supervision wipe per new device, then the profile library rotates automatically. C is *cheaper per child*, A/B are *more granular per child*.
- **App categories that change over time**: A/B shine here — token sets are editable from the child device. C cannot express per-window app sets at all (PLAN_C risk 5). If "block Instagram only during homework hours" becomes a requirement, C dies.
- **iOS major version upgrades**: A/B depend on DeviceActivity/ManagedSettings/ShieldAction extension semantics holding — Apple has broken these at WWDC before. Both plans acknowledge this. C depends on `com.apple.screentime` payload stability, which has historically been *more* stable than the private DeviceActivity scheduler internals, but not perfectly so. Net: C is less exposed to WWDC roulette.
- **School-managed accounts**: C is already on MDM-adjacent rails and would compose naturally with ABM/ASM if it ever materialized. A and B would need a parallel code path.
- **New iPhone purchase**: A/B require re-running the full onboarding (entitlements, child auth, picker). C requires a supervision wipe, which is worse UX but mechanically deterministic.

## 3. Maintenance burden (1 year / 3 years out)

**PLAN_A**: Highest rot velocity. Three extensions (DeviceActivityMonitor, ShieldConfiguration, ShieldAction), GRDB local cache, CloudKit schema, custom LaunchAgent daemon, reimplemented AFMT request/approve loop, silent-push plumbing. Each moving part is a rot surface. Year 1: token drift on iOS upgrade, CKShare quirks. Year 3: likely abandoned or rewritten. ~8 subsystems to keep alive.

**PLAN_B**: Similar complexity to A but with cleaner separation (Mac owns truth). The SQLite-on-Mac authority model is genuinely better architecture than A's peer-to-peer LWW. But B adds a Tailscale HTTPS server and APNs pusher on top of what A has, so surface area is roughly equal. B rots about as fast as A but is easier to debug because the Mac log is authoritative.

**PLAN_C**: ~500 LOC total. Rot surface: (a) the YAML→mobileconfig renderer, (b) payload schema compatibility with the current iOS major, (c) APNs/MDM cert renewal cycle (annually — this *will* bite), (d) Configurator pairing state. Year 1: fine, modulo MDM cert renewal. Year 3: the MDM cert and supervision setup are the only things likely to have required attention. **C rots slowest by a wide margin** — unless Apple changes the Screen Time payload schema meaningfully, in which case a ~200 LOC script gets updated.

Ranking by rot resistance: **C >> B > A**.

## 4. Reversibility / lock-in

- **A → B**: Very easy. B is a refactor of A where the Mac becomes authoritative. Data model is near-identical. You keep your entitlements, your extensions, your tokens. A is essentially a strict subset of B.
- **A → C**: Hard. Throw away all extensions, the entitlement, the CloudKit schema, and the in-app AFMT bridge. But your *user-facing schedule model* (windows per weekday, one-day overrides) maps cleanly to PLAN_C's YAML. Code is lost; mental model is preserved. You do have to supervise the devices.
- **B → C**: Same as A→C; throw away the Swift code but keep the schedule semantics.
- **C → A/B**: Easiest of all. C touches nothing that A or B would conflict with (no FamilyControls entitlement held, no extensions installed, no tokens captured). Remove the profile, un-supervise if desired, and start fresh. The supervision wipe is the only sting.

**Least lock-in: PLAN_C.** It holds the fewest Apple-level hooks into your devices and the fewest bespoke data structures. Its only sticky piece is device supervision, which is reversible (wipe). Ironically A and B — despite looking "lighter" because they're "just apps" — install long-lived entitlements and device-scoped token bundles that are a hassle to unwind across a family.

## 5. Failure modes the plans did not list

**PLAN_A missed**:
- The `.systemDowntimeMirror` convention has no way to detect that the user *deleted* the system Downtime window. The app will happily think enforcement is live while nothing is blocked.
- ShieldActionExtension has a tight memory budget; CloudKit writes from inside it can be killed by the OS mid-write, dropping extension requests silently.
- Two `ManagedSettingsStore`s writing during overlapping schedules will ping-pong if the `intervalDidEnd` of one races the `intervalDidStart` of another. PLAN_A registers up to 7 schedules per window which multiplies the race surface.
- LWW on `updatedAt` across a Mac daemon and two iPhones with clock skew will occasionally revert a parent's edit.

**PLAN_B missed**:
- Tailscale on the child device is not discussed; if the controller-as-fast-path is a design goal, children without Tailscale experience degraded responsiveness and the design quietly falls back to CloudKit. The "<1s override" claim only applies to the parent's own phone.
- `stsd` as a LaunchAgent runs only while the Mac user is logged in. If the Mac reboots to the login window and nobody logs in, the brain is down. LaunchDaemon would be more appropriate, but that requires root and complicates the Tailscale socket.
- CloudKit record-level encryption keys exchanged by QR is hand-waved; key rotation is not addressed.

**PLAN_C missed**:
- MDM vendor cert cannot legally be obtained by an individual without an Apple Developer Enterprise account or partnering with an MDM vendor. The plan acknowledges this but does not acknowledge that NanoMDM without a vendor cert is effectively dead for OTA — meaning the realistic deployment is Configurator-over-Wi-Fi only, which *requires the child phone be on home Wi-Fi at rotation time*. Kids out of the house at 9am don't get their 9am profile until they come home.
- Profile installs on supervised devices produce user-visible notifications on some iOS versions; rotating several times per day may be noisy.
- If the daemon installs a profile while the device is asleep and the next rotation arrives before the first is acknowledged, NanoMDM's command queue can coalesce or drop — silent enforcement gaps.
- "Ignore Limit" tap on the native Downtime sheet will bypass a window entirely; since the profile-based approach has no visibility into that, the daemon has no idea the user bypassed, and cannot surface audit.

## 6. Security / privacy concerns

**PLAN_A**:
- `TokenBundle` references stored in CloudKit keyed by device — low risk, but the `SyncCoordinator` actor crosses an App Group boundary where a compromised extension could exfiltrate schedule metadata.
- CKShare into a child iCloud account exposes the child's iCloud to a shared zone containing parent-authored schedules. Child Apple ID under 13 has historically had quirky CKShare behavior (acknowledged in B, ignored in A).

**PLAN_B**:
- Tailscale endpoint on `127.0.0.1` and tailnet. The shared-secret auth is not specified — this is a security hole in the plan. If you run an HTTPS service on the tailnet that can reconfigure your child's phone, auth must be first-class, not afterthought. Tailscale ACLs help but are not enough.
- CloudKit record-level encryption key exchange via QR is a hand-wave. Compromised parent Mac = compromised keys = ability to impersonate override approvals.
- The "Mac brokers approvals even when parent iPhone is offline" means the Mac holds approval authority for child time extensions. If the Mac is compromised, the child can be silently granted unlimited time. A clear audit log is not specified.

**PLAN_C**:
- **Profile signing key custody is the single biggest risk across all three plans.** Whoever holds the signing key can install *arbitrary* profiles on supervised devices — VPN configs, trust roots, anything. C acknowledges this but defers mitigation to "out of scope for v1", which is unacceptable. At minimum: key in Secure Enclave / hardware token, FileVault mandatory, offline backup of the key in a sealed envelope.
- MDM APNs topic, if ever obtained, is a long-lived credential tied to an Apple Developer account; its compromise would let an attacker MDM-command the family's devices.
- Supervision removes a bunch of Apple privacy protections (supervised-only MDM commands can read more device state). Family members should consent knowingly.

## 7. Final ranking and recommendation

**Ranking (long-horizon, for this user's requirements):**

1. **PLAN_C** — best interop, lowest rot, least lock-in, cleanest preservation of the user's hard requirement (native AFMT). But it lives or dies on the MDM vendor cert question.
2. **PLAN_B** — honest, well-architected, but it fundamentally cannot satisfy "MUST preserve Apple's native request more time" for any window beyond the single primary system Downtime window. It is the best answer *if* C's supervision cost is unacceptable.
3. **PLAN_A** — strictly dominated by B. There is no axis on which A beats B. A's peer-to-peer LWW sync with no authoritative writer is worse than B's Mac-authoritative model; A and B have identical extension/entitlement exposure; A's hybrid `.systemDowntimeMirror` fiction is strictly worse than B's explicit `mode` field.

**What I would actually pursue**: **PLAN_C, conditional on a successful 2-week spike** on the MDM vendor cert problem. Specifically: can this user get an MDM vendor cert via the Apple Developer Enterprise path or a partnership with an existing MDM (Jamf Now, Mosyle Business family tier, SimpleMDM), for a cost and legal posture they accept? If yes, build C. The codebase stays ~500 LOC, AFMT is preserved *by construction*, and the plan composes cleanly with anything Apple ships at the next WWDC because it uses only Apple's own Downtime machinery.

If the MDM cert spike fails, fall back to **PLAN_B**, with the user's written acknowledgment that "request more time" is native for exactly one window per day and imitated for the rest.

**What I would refuse to build**: **PLAN_A**. It is strictly dominated by B and is architecturally dishonest about its hybrid — it will rot fast, it races on multiple `ManagedSettingsStore` writes, and its LWW sync model will occasionally eat parent edits. There is no version of this user's requirements where A is the right tool.

**Things to demand from the user before any plan starts**:
- Explicit acceptance of the AFMT compromise for B, or explicit acceptance of supervision + MDM cert cost for C.
- Threat model for the signing key (C) or the Tailscale-exposed daemon (B).
- Commitment to a migration plan off the system if the spike fails (C → B is easy; A → anything is painful).
