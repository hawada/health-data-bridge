# Testing and evidence limits

## Core and service tests

```sh
swift test --jobs 2
swift run --jobs 2 WHOOPHealthSyncCoreChecks
bash scripts/verify_local.sh
```

Core tests cover normalization, overlap reconciliation, stable identifiers, recovery revisions, WAL/checkpoint recovery, bounded private-provider pagination, retry deadlines, account mismatch and incomplete history. Service checks cover authentication mocks, private-API transport mocks, persistence, legacy sleep/heart-rate scenarios, recovery setup, failed authorization, dedicated import, metadata, App Intents and capability/privacy lint. Public fixtures use synthetic identities and health values.

GitHub Actions runs core XCTest and core checks. It does not call WHOOP or write HealthKit samples. Hosted CI does not certify the physical iPhone acceptance cases below.

## Isolated simulator tests

Use Xcode 27 and a suitable runtime. **Never run synthetic HealthKit writes on your physical phone.** Tests enforce simulator-only guards and require a simulator name containing `WHOOP 0.2 QA`. This legacy harness name is deliberate.

Create/select a dedicated simulator, initialize Apple Health and resolve its authorization prompts. Choose the test scheme. For fixture-driven UI tests, pass:

```sh
xcodebuild -project iOS/WHOOPHealthSync.xcodeproj \
  -scheme WHOOPHealthSync -destination 'platform=iOS Simulator,id=YOUR_ISOLATED_SIMULATOR_UDID' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG WHOOP_IOS27_SDK WHOOP_VALIDATION_BUILD' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -jobs 2 \
  -parallel-testing-enabled NO test
```

The fixture path is simulator-gated, requires the isolated name and is absent from physical-device builds. UI fixtures do not contact WHOOP. Native HealthKit tests write only UUID-isolated synthetic samples and delete their exact returned samples; they must not use a personal Health store.

Exercise full-read, limited-history and denied-read configurations separately. Authorization prompts and runtime availability matter; record skipped tests rather than reporting them as successes.

## Development results before publication

| Scope | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Core XCTest (0.2 candidate) | 81 | 0 | 0 |
| Complete iOS 27 native/UI suite | 15 | 0 | 1 |
| Complete iOS 26.4 native/UI suite | 9 | 0 | 7 |
| iOS 27 full-read native suite | 9 | 0 | 1 |
| iOS 27 limited-read native suite | 8 | 0 | 2 |
| Rename to HealthDataBridge: iOS 27 UI | 6 | 0 | 0 |

Service/capability checks also passed. Skips reflect RMSSD/runtime availability, the limited-access configuration, or physical file-protection behavior unavailable on Simulator. Earlier failed UI-harness attempts were corrected and followed by successful final runs. These counts cover overlapping suites, not unique tests to add together.

The maintainer reported a successful basic real-account test on a personal iPhone. Build 0.2.0 (6) was subsequently installed as an update and the three persisted synchronization files were verified byte-for-byte unchanged. This is basic personal acceptance, not exhaustive public-device certification. Private logs, raw observations and device identifiers are intentionally not published.

## Physical cases still requiring broader acceptance

Real permission revocation, exporter coexistence, large real histories, interruptions/restarts, rate limits across actual sessions, file protection while locked and updates across other users' accounts need explicit physical testing. Simulator mocks do not establish these outcomes. The declared history period is not a provider-certified absolute-history endpoint.
