# API reference

Everything is reached through the singleton `HopcastFlutter.instance`.

```dart
import 'package:hopcast_flutter/hopcast_flutter.dart';
final hopcast = HopcastFlutter.instance;
```

Top-level constants:

| Constant | Value | Notes |
|---|---|---|
| `kHopcastDefaultServiceId` | `'hopcast'` | Default discovery namespace — override per app. |

---

## `HopcastFlutter`

### Methods

| Method | Description |
|---|---|
| `Future<void> build({required String deviceId, String serviceId = 'hopcast', HopcastMode mode = HopcastMode.offlineOnly, HopcastOnlineConfig? onlineConfig})` | Builds the native SDK. **Idempotent** (one native instance per process until `release`). `deviceId` = name advertised to peers (unique per device; in online/hybrid mode the SDK advertises `deviceUuid` instead); `serviceId` = discovery namespace (must match `NSBonjourServices` on iOS); `mode`/`onlineConfig` = see [Online mode](#online-mode). |
| `Future<void> provision({required String sdkKey, required String userId})` | **One-time online device enrollment** — call after `build`, typically right after your app login. Persists the device identity in the platform secure store (Keystore/Keychain); it then stays valid offline indefinitely and serves both offline and online modes. **Idempotent**: succeeds immediately without network while an identity exists. Until it succeeds once, the SDK is **inert**. Throws `HopcastIdentityException` (a `PlatformException`, code `PROVISION_FAILED` / `NOT_BUILT`), or `PlatformException` `BAD_ARGS`. |
| `Future<bool> isProvisioned()` | Whether a device identity is already persisted. `false` ⇒ call `provision` (once, online). |
| `Future<void> clearIdentity()` | Drops the persisted identity — the SDK is inert again until the next `provision`. Sequence `clearIdentity()` → `provision(…)` re-enrolls under a different `sdkKey`/`userId` on both platforms. |
| `Future<String> deviceUuid()` | Backend-assigned `device_id` (`"unknown"` until provisioned). |
| `Future<HopcastMode> mode()` | Mode the SDK was built with. |
| `Future<List<String>> getRequiredPermissions()` | Runtime permissions needed on this device/API level. Empty on iOS. |
| `Future<bool> requestPermissions()` | Requests missing permissions; `true` once all granted. Best-effort `true` on iOS. |
| `Future<void> startSharing()` | Starts advertising + discovery (continuous while running) — the offline-mode toggle (native `enableOfflineMode`). No-op in `onlineOnly`. |
| `Future<void> stopSharing()` | Stops advertising/discovery and tears down connections. |
| `Future<bool> isWifiEnabled()` | `true` if Wi-Fi is on (off ⇒ slow Bluetooth fallback). Best-effort `true` on iOS. |
| `Future<String?> sendFiles({required List<String> endpointIds, required List<String> filePaths, String? metadata})` | Sends files to peers; returns a bulk id, or `null` if nothing could be sent. |
| `Future<void> acceptTransfer(String transferId)` | Accepts an incoming invitation (receiver). |
| `Future<void> rejectTransfer(String transferId)` | Rejects an incoming invitation (receiver). |
| `Future<void> release()` | Releases the SDK and native resources. `build` again to reuse. |

### Streams

| Stream | Emits |
|---|---|
| `Stream<List<HopcastNeighbor>> neighbors` | A **full snapshot** of nearby devices on every change (empty list = nobody in range). Self is excluded; de-duplicated by `endpointId`; a late subscriber gets the last snapshot immediately. |
| `Stream<Map> transfers` | The **raw** transfer event maps (exact wire contract). Each has a `type` key + type-specific fields — see the table below. |
| `Stream<HopcastTransferEvent> transferEvents` | Typed convenience wrapper over `transfers`. |
| `Stream<HopcastOnlineEvent> onlineEvents` | Online-mode events (`EventChannel("hopcast/online")`). |
| `Stream<HopcastTransferHandoff> transferHandoffs` | Orchestrated-transfer summaries (`EventChannel("hopcast/handoffs")`). |

---

## `HopcastNeighbor`

| Field | Type | Notes |
|---|---|---|
| `endpointId` | `String` | Opaque, **volatile** transport id — pass to `sendFiles`. Changes between sessions; **never persist**. |
| `displayName` | `String` | The peer's advertised name (the `deviceId` it built with). |

---

## Transfer events

Every event carries `type` (see `HopcastTransferType`), `transferId` (String) and
`isReceiver` (bool). Additional fields by type:

| `type` | Extra fields |
|---|---|
| `invitation` | `senderName` (String), `fileCount` (int), `totalBytes` (int), `meta` (String?) — **receiver side**; approve with `acceptTransfer`/`rejectTransfer` |
| `bulkStarted` | `totalPeers` (int), `totalFiles` (int) — sender side |
| `transferProgress` | `bytesTransferred` (int), `totalBytes` (int), `peerName` (String) |
| `fileProgress` | `fileName` (String), `bytesTransferred` (int), `totalBytes` (int), `peerName` (String) |
| `fileCompleted` | `fileName` (String), `localPath` (String — **absolute path of the received file**), `fileIndex` (int), `fileTotal` (int), `peerName` (String) |
| `fileFailed` | `fileName` (String), `reason` (String), `peerName` (String) |
| `transferFailed` | `reason` (String), `peerName` (String) |
| `bulkFinished` | `outcomes`: list of `{ peerName, status, reason? }` |
| `unknown` | — (unmapped; ignore) |

> `reason` / `status` are the native SDK's **enum names** (e.g. `PEERDISCONNECTED`,
> `INVITATIONREJECTED`, `SUCCESS`, `FAILED`). Treat them as opaque strings and keep
> a default branch.

### `HopcastTransferType` (enum)

`invitation`, `bulkStarted`, `transferProgress`, `fileProgress`, `fileCompleted`,
`fileFailed`, `transferFailed`, `bulkFinished`, `unknown`.

### `HopcastTransferEvent`

Typed view of an event map. Fields mirror the table above
(`type`, `isReceiver`, `transferId`, `peerName`, `fileName`, `localPath`,
`reason`, `bytesTransferred`, `totalBytes`, `fileIndex`, `fileTotal`,
`totalPeers`, `totalFiles`, `senderName`, `fileCount`, `meta`, `outcomes`).

Convenience getters:

| Getter | Meaning |
|---|---|
| `isInvitation` / `isFileCompleted` / `isBulkFinished` / `isFailed` | type shortcuts |
| `progressFraction` | `bytesTransferred / totalBytes` in `[0,1]`, or `null` if indeterminate |
| `anyOutcomeSuccess` | at least one recipient succeeded (`bulkFinished`) |
| `wasRejected` | the transfer was declined / sender blocked |

### `HopcastTransferOutcome`

One entry of `bulkFinished.outcomes`.

| Field | Type | Notes |
|---|---|---|
| `peerName` | `String` | recipient display name |
| `status` | `String` | `SUCCESS` or `FAILED` |
| `reason` | `String?` | failure reason when `FAILED` |
| `isSuccess` | `bool` | `status == 'SUCCESS'` |

---

## A typical event sequence

**Sender** (`sendFiles` to 1 peer, 2 files):

```
bulkStarted → transferProgress* → fileProgress* → fileCompleted (×2) → bulkFinished
```

**Receiver** (after accepting an `invitation`):

```
invitation → (acceptTransfer) → transferProgress* → fileProgress* → fileCompleted (×2)
```

---

## Online mode

Available when built with `HopcastMode.onlineOnly` or `HopcastMode.hybrid`
(+ `HopcastOnlineConfig`), once provisioned. Every call is a native no-op
otherwise.

| Method | Description |
|---|---|
| `Future<void> enableOnlineMode()` | Opens the cloud session (presence, instructions, acks); also starts the radios. Idempotent. Replayed automatically after a successful `provision` if requested earlier. |
| `Future<void> disableOnlineMode()` | Closes the cloud session; offline sharing keeps running if it was on. |
| `Future<void> reportDownloadedFile({required HopcastInfraType infraType, required List<String> contentIds})` | `has/new` — this device now holds the contents (downloaded by the app, or already stored). |
| `Future<void> reportRemovedFile(List<String> contentIds)` | `has/remove` — contents deleted locally. |
| `Future<String?> declareNeed({required String contentId, required int ttlSeconds})` | `needs/new` — ask the backend to deliver the content D2D. Returns the `needId`, or `null`. |
| `Future<void> cancelNeed(String needId)` | `needs/cancel`. |
| `Future<void> handleFcmMessage(Map<String, dynamic> data)` | Forward a raw FCM data message (unknown messages are ignored). |
| `Future<void> handleFcmToken(String token)` | Forward a refreshed FCM token. |

### `HopcastMode` (enum)

`offlineOnly` (default) · `onlineOnly` · `hybrid`.

### `HopcastOnlineConfig`

| Field | Type | Default | Notes |
|---|---|---|---|
| `brokerUrl` | `String?` | `null` ⇒ `wss://mqtt.hopcast.io/mqtt` | Override for staging only. |
| `isSecondaryFcm` | `bool` | `true` | The app owns FCM (e.g. `firebase_messaging`) and forwards via `handleFcm*`. |
| `runAsService` | `bool` | `false` | Android foreground-service intent; no-op on iOS. |

### `HopcastInfraType` (enum)

`d2d` · `wifi` · `cellular` · `stored` (wire `already_stored`).

### `HopcastOnlineEvent`

| `type` (`HopcastOnlineEventType`) | Field | Native callback |
|---|---|---|
| `filesToBeDownloaded` | `fileIds` | `onFilesToBeDownloaded` |
| `cloudReady` | `deviceUuid` | `onCloudReady` (may repeat after reconnections) |
| `cloudDisconnected` | — | `onCloudDisconnected` (SDK retries itself) |
| `cloudError` | `reason` | `onCloudError` |

### `HopcastTransferHandoff`

Emitted at the end of every **orchestrated** transfer (user-triggered
`sendFiles` transfers are not reported here).

| Field | Type | Notes |
|---|---|---|
| `instructionId` | `String` | Backend instruction executed. |
| `status` | `HopcastHandoffStatus` | `success` / `failure`. |
| `reason` | `String?` | Failure cause (camelCase, e.g. `peerDisconnected`). |
| `bytesTotal` | `int?` | Σ applicative bytes from this device's point of view; `null` if not measurable. |
| `files` | `List<HopcastHandoffFile>?` | `fileId`, `bytes`, `direction` (`download` / `upload`). |

---

## `HopcastIdentityException`

Thrown by `provision`. Extends `PlatformException` (`code` = `PROVISION_FAILED`
or `NOT_BUILT`).

| Field | Type | Notes |
|---|---|---|
| `error` | `HopcastIdentityError` | `server`, `invalidResponse`, `notProvisioned`, `transport`, `notBuilt`, `unknown`. |
| `statusCode` | `int?` | HTTP status when `error == server`. |
