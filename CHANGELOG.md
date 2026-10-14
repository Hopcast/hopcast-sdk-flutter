# Changelog

All notable changes to `hopcast_flutter` are documented here.

## 0.4.0

Parity with the native SDKs, now aligned with each other (Android 0.5.1 /
iOS reference). Only features present on **both** platforms are exposed, with
the iOS naming.

### Added

- **Online (cloud-orchestrated) mode.** `build()` takes `mode:`
  (`HopcastMode.offlineOnly` — default, unchanged behaviour — `onlineOnly`,
  `hybrid`) and `onlineConfig:` (`HopcastOnlineConfig`: `brokerUrl`,
  `isSecondaryFcm` — `true` by default, the Flutter/`firebase_messaging` case —
  `runAsService`).
- `enableOnlineMode()` / `disableOnlineMode()`, `reportDownloadedFile()`
  (`HopcastInfraType`), `reportRemovedFile()`, `declareNeed()` /
  `cancelNeed()`, `handleFcmMessage()` / `handleFcmToken()`.
- `onlineEvents` stream (`HopcastOnlineEvent`: `filesToBeDownloaded`,
  `cloudReady`, `cloudDisconnected`, `cloudError`) — new
  `EventChannel("hopcast/online")`.
- `transferHandoffs` stream (`HopcastTransferHandoff`: `instructionId`,
  `status`, `reason`, `bytesTotal`, `files`) — orchestrated transfers only,
  like the native tagged listeners — new `EventChannel("hopcast/handoffs")`.
- `deviceUuid()` (backend `device_id`) and `mode()`.
- `HopcastIdentityException` (`error`: `server` + `statusCode`,
  `invalidResponse`, `notProvisioned`, `transport`, `notBuilt`) thrown by
  `provision()`. It **extends `PlatformException`** with the historical codes
  (`PROVISION_FAILED`, `NOT_BUILT`): existing handlers keep working.

### Changed

- `provision()` is documented as **idempotent on both platforms** (no network
  round-trip while an identity exists; `clearIdentity()` first to re-enroll).
- Android: `clearIdentity()` now really drops the identity (the native SDK
  gained the API); it was a no-op before.
- Android: while online mode is enabled the radios are no longer stopped when
  the app goes to background (the receiver of an orchestrated transfer must
  stay reachable); in `onlineOnly` the lifecycle no longer drives sharing.
- Native cores: Android AAR `sdk-hopcast-android:0.5.1`; iOS
  `HopcastSDKKit.xcframework` rebuilt from the current iOS SDK sources.

## 0.3.3

### Fixed

- **Offline exchange reports now actually reach the backend (iOS + Android).**
  The native SDKs defaulted to a backend host (`api.hopcast.fr`) that does not
  resolve. The correct host was only applied when the host app happened to pass
  a URL at `provision()` time, so an already-enrolled device — which never
  re-provisions — silently posted every report into the void and the durable
  exchange queue was never purged. Both native cores now default to the live
  `api.hopcast.io` backend. (The 0.3.1 note below turned out to be incomplete:
  it fixed how records were captured, not where they were sent.)

### Changed

- **The SDK owns its backend URL; the app no longer chooses it.** `provision()`
  no longer accepts an `apiBaseUrl` (Android had it as a positional argument;
  the Dart/native glue no longer forwards one). Staging overrides remain
  available through an internal, test-only hook that is never exposed to the
  host app.
- iOS native core rebuilt as the hardened `HopcastSDKKit.xcframework` 0.3.3;
  Android native core rebuilt as `sdk-hopcast-android` 0.3.3.

## 0.3.2

### Fixed

- **iOS: possible crash when `startSharing()` was called repeatedly** (e.g.
  reopening the sharing screen). Calling `startSharing()` again is now always
  safe on both platforms and refreshes discovery.

### Changed

- iOS native core updated (0.3.1 rebuild): SDK logs are no longer emitted in
  release builds, and the shipped binary is smaller.

## 0.3.1

### Fixed

- **iOS: exchange reports now reach the backend.** Previously no exchange was
  recorded for transfers performed on iOS. Device provisioning was unaffected.

### Added

- **`clearIdentity()`** — drops the persisted device identity; the SDK becomes
  inert again until the next successful `provision`. Use
  `clearIdentity()` → `provision(…)` to re-enroll under a different
  `sdkKey`/`userId` (key rotation, user switch). The sequence behaves
  identically on both platforms.

## 0.3.0

Provisioned identity + automatic exchange reporting.

### Added

- **`provision({sdkKey, userId})`** — one-time online device enrollment, to
  call once after `build()` (typically right after your app login). The device
  identity is persisted in the platform secure store and stays valid offline
  indefinitely.
- **`isProvisioned()`** — whether a device identity is already persisted.

### Changed (breaking)

- **The SDK is inert until provisioned**: `startSharing`, `sendFiles`,
  `acceptTransfer`… silently do nothing while `isProvisioned()` is `false`.
  Existing apps MUST add the `provision` call.
- Transfers are now automatically recorded and reported to the Hopcast backend
  when connectivity is available — no integration work required. The D2D data
  path itself remains fully offline; the one-time enrollment is the only call
  that requires connectivity.

## 0.2.1

First unified Android + iOS release.

### Added

- Unified Dart facade `HopcastFlutter` (singleton) with the same API on both
  platforms.
- Typed models: `HopcastNeighbor`, `HopcastTransferEvent`, `HopcastTransferType`,
  `HopcastTransferOutcome`, plus the raw `Stream<Map> transfers` for direct access.
- **Configurable `serviceId`** on `build(deviceId:, serviceId:)` — discovery
  namespace. On iOS it must match `NSBonjourServices`.
- Consistent transfer lifecycle on both platforms:
  `bulkStarted → transferProgress/fileProgress/fileCompleted → bulkFinished`,
  with manual acceptance of incoming transfers (`invitation` events).
- Runnable `example/` app: permissions, live neighbours, multi-select send with
  progress, incoming-invitation dialog, and a minimal allow/block trust policy.

### Notes

- **No cross-platform interop** (different underlying transports): iOS↔iOS or
  Android↔Android only.
- The shipped binaries are already correctly configured — do not re-process them.
