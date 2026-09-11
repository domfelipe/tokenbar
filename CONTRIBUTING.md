# Contributing to TokenBar

Thanks for your interest in making TokenBar better. This guide covers the
day-to-day workflow and — the most common contribution — **adding a new
usage provider**.

## Project layout

```
Sources/
  TokenBarCore/         Domain, protocol, scheduler, persistence, alerts, settings
  TokenBarProviders/    One folder per provider (10 today) + Shared/
  TokenBarUI/           SwiftUI app layer: menu bar, panel, settings, coordinator (wiring)
  tokenbar/             Executable: app entry, history CLI, self-check
  genfixtures/          Synthetic corpus generator (tests/e2e only)
  panelrender/          QA harness: renders the REAL panel views to PNG (never runs in the app)
Tests/                  Swift Testing suites (565 tests green at v1.0.0)
docs/                   Specs, per-phase decisions (decisoes-f*.md), QA/Red Team evidence (pt-BR)
```

## Building and testing

Requirements: macOS 14+, Swift 6 toolchain (full Xcode **or** Command Line
Tools).

```bash
./run-tests.sh                 # build + full test suite — THE way to test locally
./scripts/make-app.sh          # → build/TokenBar.app (ad-hoc signed, no Xcode needed)
./scripts/e2e.sh               # full end-to-end: mock APIs, alerts, degradation, migration
./scripts/release.sh 1.0.0     # local release: .app + zip + sha256 + notes in build/
```

**Important — never run bare `swift test` on a Command Line Tools
toolchain.** The CLT does not put the Swift Testing framework on the default
search paths, and on some CLT versions `swift test` exits 0 without running
a single test (false green). `./run-tests.sh` passes the right `-F`/`-rpath`
flags. Full Xcode installs (and the CI runners) are not affected — the CI
runs plain `swift test` because GitHub's macOS images ship full Xcode.

## Reporting a bug

Open a GitHub issue with:

1. macOS version and how you installed TokenBar (release download / built
   from source, commit hash).
2. Which provider misbehaves and what you see vs. what you expect.
3. The heartbeat JSON if you can get one (`TOKENBAR_E2E_DIR` environment
   variable redirects it to a writable directory; the file is tokenized —
   no credentials, no token values).
4. Any environment overrides you used (see the table in the README).

**Never paste real tokens, API keys or credential file contents** into an
issue. Fixtures and examples in this repo use `fake-*` values only; keep it
that way.

## Add your provider

Every data source in TokenBar — API-backed or transcript-ingesting — is a
`UsageProvider`. This is the extension point the whole app consumes; the
scheduler, panel, alerts, history and multi-account machinery pick it up
automatically once it is registered.

### 1. Read the contract

`Sources/TokenBarCore/Providers/UsageProvider.swift`:

```swift
public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var capabilities: ProviderCapabilities { get }   // .apiUsage, .localIngest, .credits, .multiAccount

    func discoverAccounts() async -> [AccountRef]
    func fetchUsage(_ account: AccountRef) async throws -> UsageSnapshot
    func ingestLocal(_ account: AccountRef, from cursor: IngestCursor) async throws -> IngestBatch
}
```

A provider without `.apiUsage` never generates a network request; one
without `.localIngest` never enters the transcript ingest cycle. Auth
problems become snapshot state (`authState: .invalid`), never an error
message containing a credential.

### 2. Pick your model — API provider or local-only

- **API provider** → copy the shape of `Sources/TokenBarProviders/Codex/`
  (or any F5 provider such as `Grok/`, which is smaller): a credential
  reader (`<Name>CredentialReader` with a `resolve(environment:home:)`
  factory), a tolerant response decoder, and the provider class composing a
  `UsageHTTPClient`.
- **Local-only** (reads session files, no network) → copy
  `Sources/TokenBarProviders/Gemini/`. You will mostly implement
  `ingestLocal`; honor the **cursor contract** documented on the protocol:
  seed each cycle ONLY from your own previous `IngestBatch.nextCursor` (or
  a fresh cursor store read) — a foreign or stale cursor re-reads files and
  double-counts history permanently.

### 3. Response decoding rules (API providers)

Decode with the shared tolerant style (`AnyKey` + `FlexibleJSON`, as in
`CodexProvider.swift`): accept snake_case and camelCase aliases, accept
int/double/string numbers, treat every field as optional, ignore unknown
keys. A vendor adding a field must never break your provider.

### 4. Credentials: read-only, never logged

- Read credential files / env vars **read-only**; never write, never log
  their contents, never put them in errors or snapshots.
- Missing credential → `discoverAccounts() == []` and the provider simply
  does not appear. No error, no noise.
- 401/403 → snapshot with `authState: .invalid` ("auth invalid" badge),
  last good state kept.
- Network/HTTP failure → **rethrow**. The `AdaptiveScheduler` owns backoff
  (×2 capped at 30 min). Never retry inside the provider.
- Expose a `TOKENBAR_<NAME>_API` environment override for the base URL
  (testability + e2e), like every existing provider does.

### 5. Register an id and a menu-bar letter

- Add the case to `ProviderID`
  (`Sources/TokenBarCore/Domain/ProviderID.swift`).
- Reserve the menu-bar letter in `MenuBarContent.siglas`
  (`Sources/TokenBarUI/MenuBarContent.swift`). This is the **D5 table**:
  `C`=Claude, `X`=Codex, `G`=Gemini, `Z`=Z.ai, `U`=Cursor, `O`=OpenRouter,
  `Q`=Qwen/Alibaba, `V`=Antigravity, `D`=DeepSeek, `K`=Grok. Pick a letter
  with **no collision** (that is why DeepSeek is `D` but Grok is `K`, not
  `G` — `G` was taken by Gemini). Providers outside the table fall back to
  the first letter of their raw value — but prefer an explicit entry.

### 6. Wire it in

`Sources/TokenBarUI/ProviderCoordinator.swift`:

- Construct your provider next to the others (credential reader +
  `UsageHTTPClient(baseURL:)` + optional `accounts: accountRegistry` for
  multi-account) and add it to the `ProviderRegistry(providers: [...])
  array.
- If it supports registered accounts (`.multiAccount`), add a case in
  `makeAccountProvider(_:entry:)` so "Add account…" works.

### 7. Tests — fixture-replay is mandatory

Follow `Tests/TokenBarProvidersTests/GrokProviderTests.swift` (small) or
`CodexProviderTests.swift` (complete):

- **Synthetic fixtures only**: inline JSON strings (or `F5StubURLProtocol`
  for full request/response replay) with `fake-*` credentials. No captured
  production payloads, no real domains (use `example.com` hosts).
- Cover at least: happy path, missing credential (→ no accounts), 401/403
  (→ `.invalid`), malformed/foreign-keyed body (→ tolerant decode holds),
  and replay determinism (same fixture in → same snapshot out).
- Keep the suites in Swift Testing (`@Suite`/`@Test`/`#expect`).
  `ClaudeUsageProviderConformanceTests` shows how to pin the protocol
  contract itself; `ParserFuzzTests` shows hostile-input style if your
  parser is non-trivial.

### 8. If you are porting from CodexBar

The reference (`steipete/CodexBar`, MIT) has ~50 providers. Ported ones cite
the upstream source file and endpoint in the module header doc comment and
in `docs/specs/f5-providers.md` — including what was deliberately **not**
ported and why. If you copy an SVG icon intact, it must be listed in
`NOTICE` (root of the repo). Do not invent data: a section without data is
omitted, never faked.

### Provider checklist

- [ ] `ProviderID` case + no-collision letter in `MenuBarContent.siglas`
- [ ] `UsageProvider` implementation (capabilities declared honestly)
- [ ] Credentials read-only, never logged; `fake-*` in everything test-owned
- [ ] Missing credential → hidden; 401/403 → `.invalid`; network error → rethrow
- [ ] `TOKENBAR_<NAME>_API` override
- [ ] Registered in `ProviderCoordinator` (+ `makeAccountProvider` if multi-account)
- [ ] Fixture-replay tests green via `./run-tests.sh`
- [ ] README provider table row + (if ported) `docs/specs/f5-providers.md` entry

## Pull requests

- `./run-tests.sh` green (paste the tail of the run in the PR).
- One provider per PR when adding providers.
- Comments and user-facing strings: the codebase documents in pt-BR and
  ships user-facing strings in English — match the file you are editing.
- The repo is public: no real credentials, endpoints' tokens, or personal
  data anywhere — code, fixtures, docs or screenshots.

## License

By contributing you agree that your contributions are licensed under the
MIT License that covers this project (see `LICENSE`; ported CodexBar
material keeps its attribution in `NOTICE`).
