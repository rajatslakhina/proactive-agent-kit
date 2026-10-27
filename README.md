# ProactiveAgentKit

**An agent that acts before you ask is only safe if three things are true: it cannot leak what it reads, it cannot act twice, and it cannot do anything consequential without a "yes" bound to that exact action. This package makes all three properties of the type system and the pipeline, not of the prompt.**

[![CI](https://github.com/rajatslakhina/proactive-agent-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/proactive-agent-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20Linux%20(core)-blue) ![License](https://img.shields.io/badge/license-MIT-green)

Demo app: (added after the companion repo is pushed — see below)

---

## The problem

In October 2026 Anthropic shipped Claude Duet, a proactive agent that "comes to you with what needs you". Its published safety design is a useful checklist for anyone building the same thing inside an iOS app: approval before consequential actions, a classifier that splits data into *never share* and *needs consent to share*, and a hard boundary between what the device sees and what the cloud model sees. A day later Anthropic's agent-building guidance argued for folding specialist sub-agents back into **one main loop** with progressive disclosure of tools.

An iOS app that wants this has a systems problem, not a prompt problem:

- Signals arrive from App Intents, notifications, EventKit and background tasks, in bursts, sometimes twice, and the process can be killed at any point.
- An on-device model (Foundation Models) can triage cheaply but is sometimes unavailable; the cloud model plans better but costs battery, tokens and privacy.
- A notification that says "Your code is 482913" must never reach the cloud model, even if a classifier has a bug.
- "Send Sam a message" approved on screen must not turn into a different message by the time it executes, and must not be sent twice after a crash.

## What's in it

```
Signal ─▶ EventLog ─▶ TriageModel ─▶ EgressPolicy ─▶ CloudPlanner ─▶ approval gate ─▶ ActionExecutor
          (durable,    (on device,     (classifier +    (only accepts   (digest-bound,   (journaled,
           bounded,     budgeted,       independent      EgressTicket)    single-use,      idempotent)
           de-duped)    energy-aware)   LeakScanner)                      expiring)
                                  └────────── all driven by one AgentLoop actor ──────────┘
```

| Type | Responsibility | Load-bearing decision |
|---|---|---|
| `EventLog` (actor) | Durable, bounded log with per-source quota and fair shedding | **Write-then-publish**: every mutation is computed on a copy, persisted, then made visible. A failed save leaves memory unchanged, so memory never gets ahead of disk. `inFlight`/`parked` revert to `pending` on relaunch. |
| `TriageModel` / `HeuristicTriageModel` | On-device intent + urgency | A protocol seam for a Foundation Models session. When the model is unavailable the result is a *fallback* that may only notify, never act. |
| `StageBudget`, `EnergyPolicy` | Per-stage token windows; battery / Low Power gating | Cloud and on-device stages have **separate** budgets so one running dry can't starve the other. Critical signals still escalate in Low Power Mode. Offline requests are refunded. |
| `EgressPolicy` → `EgressDecision` | `allow(EgressTicket)` / `needsConsent` / `localOnly` | `neverShare` (credentials, one-time codes, cards, health) is redacted even under full consent; `ConsentLedger` refuses to record consent for it. |
| `LeakScanner` | Second, independent check on the redacted payload | Looks only at value shapes, never at keys or classifier output, so a classifier bug cannot blind it. Never-share shapes (Luhn-valid card runs, 6–8 digit OTP runs, credential markers) fail closed. Contact shapes (emails, 10–12 digit phone runs) fall back to a consent prompt unless contact sharing is already consented. |
| `EgressTicket` | The only input `CloudPlanner` accepts | Its initialiser is `internal`: code outside the module — including your network layer — **cannot construct one**. The boundary is enforced by the compiler. |
| `ToolCatalog` | One loop, tool modules disclosed per intent | Fold sub-agents into the main loop: a purchase discloses only `commerce.*` (660 schema tokens vs 1,530 eager). A planner proposing a tool outside the disclosed module is refused. |
| `ApprovalRequest` + `AgentLoop.approve` | Human gate for `consequential` tools | Bound to a **process-stable FNV-1a digest** (not `Hasher`, which is per-process) of the tool, the planner's summary *and* every argument. The console renders the raw arguments (`PlannedAction.disclosure`), not just the planner-written summary. Single-use (removed before the executor `await`), expiring, and a digest mismatch is rejected. |
| `ActionJournal` | Side-effect de-duplication across retries and relaunches | Keyed by **signal id**, not by the action: each event executes exactly one action, and after a crash a cloud model re-plans with different wording, so an action-keyed journal would miss. Checked right after a claim (before any re-triage, re-plan or fresh approval card) and again before executing. Recorded in the same synchronous stretch as the executor's return; `Codable`, persisted by the host. |
| `AgentLoop` (actor) | The single agent loop | `step` is serialised: a call that arrives while another is suspended returns `.busy` (flag set before the first `await`). State that another call could change across an `await` is re-validated afterwards (e.g. consent granted while an event was being parked). |

`ProactiveAgentUI` adds `AgentConsoleView` / `AgentConsoleModel`, a SwiftUI console that drives the real loop with fault injection. It compiles to an empty module on Linux and is built for macOS and the iOS Simulator in CI. A separate test target that imports the core without `@testable` exercises every public symbol the console uses, so an access-level regression fails on Linux too, not only on Apple platforms.

## Trade-offs and rejected alternatives

- **At-least-once processing + an idempotency journal, not exactly-once.** Exactly-once would need a two-phase commit with every executor (Messages, a payment sheet). Instead the executor receives an `idempotencyKey` derived from the signal id alone, so it is identical across retries, re-plans and relaunches, and the journal suppresses a repeat in-process and after relaunch if the host persists it. The residual window — the process dying between the executor returning and the host persisting the journal — is what the key is for: the downstream system can de-duplicate on it, because a re-plan cannot change it.
- **A specialist agent per domain (messaging agent, commerce agent) — rejected.** It multiplies coordination failure modes and puts every tool schema in context. One loop with per-intent disclosure is cheaper and easier to reason about.
- **Trusting the classifier — rejected.** Classifiers miss things. The scanner is deliberately dumber and independent; tests prove that without it, a broken classifier leaks both a one-time code and an email address. Its honest limit: consent-tier data with no recognisable shape (a place name, a message body, calendar details) still depends on the classifier.
- **Showing only the planner's summary on the approval card — rejected.** The summary is free text from the cloud model. A summary of "Reply to Sam" over arguments that say `to: collector@attacker.example` is exactly the prompt-injection case, so the card shows the arguments and the digest covers both.
- **Redacting unconsented personal data silently — available, not default.** `UnconsentedPersonalData.ask` matches Duet's "needs consent to share". `.redact` exists for products where a prompt is worse than a degraded plan.
- **Approving by request id alone — rejected.** An id says *which* prompt was answered, not *what* was approved. Binding to the action digest means a stale or tampered UI cannot approve something it didn't show.
- **Shedding the newest event under pressure — rejected.** The log sheds the oldest *pending* event of the busiest source, so a notification storm sacrifices its own backlog rather than a calendar conflict. In-flight and parked events are never shed: a human may be looking at them.
- **Known limits.** The FIFO claim order is per-log, not per-priority. A storage failure *after* an action has executed (or in a retry path) leaves that event in flight until relaunch, when it returns to pending and the journal suppresses the repeat; the loop reports it as `.storageFailure` rather than guessing. Parked events (waiting on consent or approval) count against their source's quota, so a backlog of unanswered prompts throttles that source until they are answered or the app relaunches; that is deliberate back-pressure, but it is visible. Offline deferral doesn't consume attempts, so an always-offline device keeps events pending (by design: they are not failures). `HeuristicTriageModel` is a keyword stand-in for a Foundation Models session, not a classifier you should ship.

## How to run it

```bash
git clone https://github.com/rajatslakhina/proactive-agent-kit.git
cd proactive-agent-kit
swift build -Xswiftc -warnings-as-errors   # core builds on Linux too; the UI module needs an Apple platform
swift test
```

For the interactive console, open the companion demo app (link above) in Xcode.

## How to use it

```swift
.package(url: "https://github.com/rajatslakhina/proactive-agent-kit.git", from: "1.0.0")
```

```swift
import ProactiveAgent

let log = try EventLog(storage: FileEventLogStorage(url: logURL))
let journal = (try? JSONDecoder().decode(ActionJournal.self, from: Data(contentsOf: journalURL))) ?? ActionJournal()
let loop = AgentLoop(log: log,
                     triage: MyFoundationModelsTriage(),      // conforms to TriageModel
                     policy: EgressPolicy(),
                     planner: MyClaudePlanner(),              // receives only EgressTicket
                     executor: MyActionExecutor(),
                     journal: journal,                        // survives relaunch: no repeated side effects
                     clock: { Date().timeIntervalSince1970 })

_ = try await log.append(Signal(id: notification.id, source: .notification,
                                receivedAt: Date().timeIntervalSince1970, title: notification.title))

switch await loop.step(energy: EnergyState(batteryLevel: 0.8, lowPowerMode: false)) {
case .awaitingConsent(_, let categories): showConsentPrompt(categories)
case .awaitingApproval(let request):      showApproval(request)   // later: loop.approve(request.id, digest: request.digest)
default: break
}

// After a step that executed something, and when the app backgrounds, persist the journal:
try JSONEncoder().encode(await loop.status().journal).write(to: journalURL, options: .atomic)
```

## Verification

- Linux, Swift 6.0.3: `rm -rf .build && swift build -Xswiftc -warnings-as-errors` → 0 warnings; `swift test` → **78 tests, 0 failures** (77 in `ProactiveAgentTests`, 1 in `ProactiveAgentPublicAPITests`).
- Tests include broken-implementation checks for the properties this README claims. With the scanner removed, a broken classifier **does** leak a one-time code and an email address. With the journal dropped, a side effect **does** repeat after a simulated crash. With a planner whose wording changes on every call, a crash after execution is still suppressed on relaunch, before re-planning. Other checks: a tampered digest or a different summary is rejected; two concurrent approvals execute once; an approval after its TTL does not execute; consent granted while the loop is suspended inside `park` requeues the event; a concurrent `step` is refused; the triage cache stays bounded when the log sheds deferred events. Digest values are checked against known answers from an independent Python implementation.
- Mutation checks: independent reviewers applied mutants to scratch copies. Five that survived (or hung) an earlier version of the suite were re-run after the tests were strengthened, and each now fails at least one test: moving the approval removal after the executor `await`, dropping the triage-cache bound, disabling the consent re-check after `park`, disabling the contact-shape fallback, and removing the `step` busy guard (which used to hang the test instead of failing it). Making `OutcomeDescription`'s initialiser internal again now fails the public-API test target at compile time.
- Writing the tests also caught a real trap: `backoff(afterAttempt: Int.min)` overflowed on `attempt - 1`. It is now saturating.
- CI ([Actions](https://github.com/rajatslakhina/proactive-agent-kit/actions/workflows/ci.yml)), green on the first run:
  - **Linux** (`swift:6.0` container): clean `swift build -Xswiftc -warnings-as-errors`, 0 warnings; `swift test`, 78 tests, 0 failures.
  - **macOS** (`macos-15`, Xcode 16.4, Swift 6.1.2): `swift test -Xswiftc -warnings-as-errors` compiles both modules, including `ProactiveAgentUI`, and runs the same 78 tests with 0 failures. Then `xcodebuild build` for `generic/platform=iOS Simulator` succeeds for the `ProactiveAgent` and `ProactiveAgentUI` schemes with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
- Before CI existed, a reviewer found a real cross-module bug in the SwiftUI module by reading it: an internal initialiser was called from the UI module. It was fixed and is now guarded by the public-API test target. The macOS job above was the module's first real compile.
- Simulator: see the demo repo for exactly what was and was not run.

## License

MIT
