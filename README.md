# hopcast_flutter

**Device-to-device (D2D) file sharing for Flutter — Android & iOS.**

AirDrop-style peer-to-peer file sharing between nearby phones. Discovery and
transfers are **fully offline** (no server in the data path): discovery goes over
Bluetooth; file data then flows over Wi-Fi for speed. In the default offline mode
the only network touchpoints are a **one-time online device enrollment**
(`provision`, at first login) and **deferred exchange reports**, queued locally
and uploaded opportunistically when connectivity returns. An optional **online
mode** lets the Hopcast backend orchestrate D2D transfers (see below).

The proprietary core ships as **hardened binaries** bundled with this package (an
Android AAR and an iOS XCFramework). You integrate against a thin, typed Dart
facade and never see the SDK internals.

---

## Features

- **Offline peer-to-peer** — no backend in the data path; transfers work with no
  internet (after the one-time enrollment).
- **Exchange reporting** — every transfer is journaled on-device and reported to
  the Hopcast backend when the device comes back online (offline-first, durable).
- **Android + iOS** — one Dart API on both platforms.
- **Multi-file, multi-peer** sends with per-file and per-peer progress.
- **Online mode (optional)** — `onlineOnly` / `hybrid`: the backend pushes
  instructions and the SDK executes the D2D transfers itself; declare
  inventory/needs, observe the cloud session and orchestrated handoffs.
- **Manual acceptance** — every incoming transfer surfaces an invitation your
  app approves or declines (build your own allow/block policy on top).
- **Binary-only core** — hardened AAR + XCFramework, no SDK source shipped.

## Support matrix

| | Android | iOS |
|---|---|---|
| Min version | API 21 (Android 5.0) | iOS 15 |
| Native core | AAR `sdk-hopcast-android:0.5.2` | XCFramework `HopcastSDKKit` (iOS SDK sources) |
| Registration | Automatic (plugin loader) | Automatic (plugin loader) |

> **No cross-platform interop.** The two platforms use different underlying
> transports, so sharing works **iOS↔iOS** or **Android↔Android** only — never
> iOS↔Android.

## Install

Add the package to your app's `pubspec.yaml` as a git dependency, pinned to a
release tag:

```yaml
dependencies:
  hopcast_flutter:
    git:
      url: https://github.com/Hopcast/hopcast-sdk-flutter
      ref: 0.4.1
```

Then run `flutter pub get`. The plugin auto-registers on both platforms — no
`MainActivity` / `AppDelegate` wiring needed.

There is platform setup to do (permissions, `Info.plist`, Gradle) — see the
**[Integration guide](doc/integration.md)**. Minified (R8) Android release builds
need **no Hopcast-specific rule**: the bundled AAR ships its own consumer rules.

### Getting your SDK key

Your SDK key (`pk_live_…`) is obtained from your Hopcast account management
console at **https://console.hopcast.io**. It is designed to be embedded in your
app and can be revoked at any time from the console.

## Quick start

```dart
import 'package:hopcast_flutter/hopcast_flutter.dart';

final hopcast = HopcastFlutter.instance;

// 1. Permissions (Android runtime; no-op best-effort on iOS).
await hopcast.requestPermissions();

// 2. Build the SDK (idempotent). deviceId = the name peers see; serviceId scopes
//    discovery (must match your NSBonjourServices on iOS).
await hopcast.build(deviceId: 'My-Phone', serviceId: 'myapp');

// 3. One-time device enrollment (needs connectivity the first time — typically
//    right after your app login). Until it succeeds once, the SDK is inert.
if (!await hopcast.isProvisioned()) {
  await hopcast.provision(sdkKey: 'pk_live_YOUR_KEY', userId: user.id);
}

// 4. Start advertising + discovery, and watch nearby devices.
await hopcast.startSharing();
hopcast.neighbors.listen((peers) {
  // Update your UI. Resolve endpointId right before sending — it is volatile.
});

// 5. Send files to selected peers.
await hopcast.sendFiles(
  endpointIds: [peer.endpointId],
  filePaths: ['/path/to/file.bin'],
);

// 6. Receive: approve invitations and collect completed files.
hopcast.transferEvents.listen((e) async {
  if (e.type == HopcastTransferType.invitation) {
    await hopcast.acceptTransfer(e.transferId!); // or rejectTransfer
  } else if (e.type == HopcastTransferType.fileCompleted) {
    print('Received: ${e.localPath}');
  }
});
```

### Online mode (optional)

```dart
await hopcast.build(
  deviceId: 'My-Phone',
  serviceId: 'myapp',
  mode: HopcastMode.hybrid,                    // or onlineOnly
  onlineConfig: const HopcastOnlineConfig(),   // production broker by default
);
// …provision as above, then:
hopcast.onlineEvents.listen((e) { /* cloudReady / cloudDisconnected / … */ });
hopcast.transferHandoffs.listen((h) { /* orchestrated transfer finished */ });
await hopcast.enableOnlineMode();

// Forward FCM (e.g. from firebase_messaging):
FirebaseMessaging.onMessage.listen((m) => hopcast.handleFcmMessage(m.data));
FirebaseMessaging.instance.onTokenRefresh.listen(hopcast.handleFcmToken);
```

See [Integration guide §6](doc/integration.md#6-online-mode-optional).

### Sending several times to the same peer (Android)

Each new Android connection pays a Bluetooth → Wi-Fi upgrade (up to ~15 s across
different Wi-Fi networks). To pay it once, keep the link open across sends:

```dart
await hopcast.build(deviceId: 'My-Phone', serviceId: 'myapp',
    autoDisconnectAfterTransfer: false); // Android only; ignored on iOS
```

See [Platform notes](doc/platform_notes.md#connections-are-released-after-each-transfer-by-default).

## Documentation

- **[Integration guide](doc/integration.md)** — Android & iOS setup, permissions,
  `Info.plist`, Gradle, `serviceId`, min versions, gotchas.
- **[API reference](doc/api.md)** — every class, method and stream, plus the full
  transfer-event table.
- **[Platform notes](doc/platform_notes.md)** — platform-specific behaviour:
  first-send delay on iOS, lifecycle-driven sharing on Android, received-file
  locations, no cross-platform interop.
- **[Lifecycle & best practices](doc/lifecycle.md)** — idempotent build, volatile
  endpointIds, Wi-Fi = throughput, `release()`.
- **[Troubleshooting](doc/troubleshooting.md)** — permissions, no discovery,
  receive not arriving.
- **[Snippets](doc/snippets.md)** — copy-paste discovery / send / receive.

A fully runnable demo lives in **[`example/`](example/)** — permissions, live
neighbours, multi-select send with progress, incoming-invitation dialog, and a
minimal trust policy.

## Support

contact@hopcast.io — © Hopcast. Proprietary, see [LICENSE](LICENSE).
