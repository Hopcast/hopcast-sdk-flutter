# Platform notes

The Dart API is identical on both platforms, but the underlying transports
differ. This page documents the platform-specific behaviour you can observe
from your app.

---

## Provisioned identity (both platforms)

The device identity created by `provision()` is stored in the platform secure
store. It survives app restarts and airplane mode — one identity per phone,
no re-enrollment on later launches. While unprovisioned the SDK is inert:
every D2D call silently does nothing. Check `isProvisioned()` when "nothing
happens". Exchange reporting is fully automatic — no Dart-side work is needed.

---

## No cross-platform interop

**iOS talks to iOS; Android talks to Android.** Each platform uses its own native
peer-to-peer transport, and the two are mutually incompatible.

An iPhone and an Android phone will **not** discover each other, by design.
Surface this in your UX if your user base is mixed.

---

## iOS

### First send to a new peer has a short delay

`sendFiles` returns its bulk id immediately, but the actual transfer starts
after the connection to each recipient is established (automatic, up to ~25 s
per peer). Expect a short pause before the first `transferProgress` event when
sending to a peer for the first time; subsequent sends are faster.

### Bulk events

The `bulkStarted … bulkFinished` bracket is delivered on both platforms:
`bulkStarted` right after `sendFiles`, `bulkFinished` once every recipient
reaches a terminal state (at the latest ~90 s after a stalled send), carrying
the per-peer `outcomes`.

### Repeated `startSharing()`

Calling `startSharing()` again at any time is safe and refreshes discovery —
e.g. when the user reopens your sharing screen.

### `requestPermissions` / `isWifiEnabled`

iOS exposes no API to explicitly request "Local Network" or to read the Wi-Fi
state, so both return best-effort `true`. The Local Network prompt is shown by
the system on the first Bonjour discovery (first `startSharing()`).

### Received files location

Received files land in
`<Application Support>/hopcast_inbox/…`; that absolute path is what
`fileCompleted.localPath` reports. Move/copy them out promptly if you want them
elsewhere.

---

## Android

### Binary AAR — do not re-process

The AAR ships already correctly configured. Do **not** re-process it (strip,
shrink, or repackage): doing so can break the SDK and badly regress D2D
throughput. Integrate it as-is.

### Connections are released after each transfer

When a transfer finishes, the connection to the peer is released — this keeps
the next transfer (possibly to a different device) at full Wi-Fi speed. The
peer stays discoverable and is reconnected transparently on the next send; you
don't manage connections yourself.

### Sharing follows the app lifecycle

Discovery + advertising run continuously while the app is in the foreground
and stop in the background (releasing Bluetooth/Wi-Fi). Calling
`startSharing()` again at any time is safe and refreshes discovery.

### Received files location

Received files land in `filesDir/hopcast_inbox/…`; that absolute path is what
`fileCompleted.localPath` reports.

---

## Transport & performance (both platforms)

- **Wi-Fi must be on** on both devices for a fast transfer. Off ⇒ Bluetooth
  fallback (~100× slower). Use `isWifiEnabled()` (Android) and nudge the
  user to enable Wi-Fi.
- **One active transfer at a time** per device. Serialise multi-target sends
  where possible.
- Discovery + signalling ride Bluetooth; the file bytes ride Wi-Fi.

## Online mode (both platforms)

- Exposed API = the common denominator of the two native SDKs (iOS naming).
  Android-only extras of the native SDK are **not** exposed: the extra
  `TransferHandoff` fields (`sessionId`, `peerDeviceId`, `startedAt`,
  `completedAt`), the legacy single handoff listener (every transfer, incl.
  user-triggered), `provision(context, …)` before build, auto-sync /
  `ContentProvider`, `NeighborArrivalListener`, app-bytes side channel, Wi-Fi
  state listener, trust store and `sessionId`.
- `transferHandoffs` only carries orchestrated transfers (`instructionId` is
  always set), on both platforms.
- In online / hybrid mode the SDK advertises its backend `deviceUuid` to peers
  instead of `deviceId`. On iOS the advertised name is fixed at `build()` time
  (before provisioning it is a per-install UUID): if you build before the first
  `provision`, `release()` + `build()` once afterwards so peers see the
  `device_id`. Android resolves it lazily.
- **Android:** while online mode is enabled the bridge keeps the radios on when
  the app goes to background (instead of stopping sharing); in `onlineOnly`
  the app lifecycle does not drive sharing at all.
- `HopcastOnlineConfig.isSecondaryFcm` defaults to `true` in Dart on both
  platforms (the native Android default is `false`), matching the usual
  `firebase_messaging` setup.
