# hopcast_flutter — example app

A runnable demo of the `hopcast_flutter` package. It shows the full generic flow
with a UI:

- **Bootstrap** — request permissions, `build(deviceId:, serviceId:)`, `startSharing()`.
- **Live neighbours** — a list that updates as devices appear/disappear, with
  multi-select.
- **Send** — generate demo files (~256 KB each) and `sendFiles()` to the selected
  peers, with a progress bar (`transferProgress` / `fileProgress`) and a final
  delivery summary (`bulkFinished`).
- **Receive** — an incoming `invitation` dialog (Accept / Decline / Always /
  Block → `acceptTransfer` / `rejectTransfer`), receive progress, and a list of
  received files (their `localPath`).
- **Trust policy** — a minimal allow/block list plus an "accept everyone / ask
  each time" mode (behind the settings icon).

There is **no domain logic** here — everything is expressed in terms of generic
"files".

## Run it

You need **two devices on the same platform** (iOS↔iOS or Android↔Android —
there is no cross-platform interop).

```bash
cd example
flutter pub get
flutter run          # on each device
```

- **Android**: real devices or emulators with Bluetooth/Wi-Fi. Grant the runtime
  permissions when prompted.
- **iOS**: **real devices only** for transfers (peer discovery does not work on
  the simulator). Accept the "Local Network" prompt on first launch.

Give the devices a few seconds to find each other, select a peer, and tap
**Send**.

## Where to look

| File | What it shows |
|---|---|
| `lib/main.dart` | `HopcastController`: build/permissions/share, streams, send, and the incoming-invitation trust policy |
| `lib/src/home_page.dart` | UI: neighbours list, multi-select send, received files, settings |
| `lib/src/incoming_dialog.dart` | the Accept/Decline/Always/Block dialog |
| `lib/src/trust.dart` | generic allow/block + accept-mode policy |
| `lib/src/friendly_name.dart` | stable per-install device name |
| `android/app/build.gradle.kts` | minSdk 21, core library desugaring, packaging excludes |
| `ios/Runner/Info.plist` | `NSLocalNetworkUsageDescription`, `NSBonjourServices`, Bluetooth usage |
| `ios/Podfile` | `platform :ios, '14.0'` |

The demo's `serviceId` is `hopcastdemo` (see `kDemoServiceId` in `main.dart`),
which matches the `NSBonjourServices` entries in `ios/Runner/Info.plist`.

## Online mode demo

Build with a real SDK key and an online mode to see the cloud session status
and the last orchestrated transfer handoff on the home screen:

```sh
flutter run --dart-define=HOPCAST_SDK_KEY=pk_live_YOUR_KEY --dart-define=HOPCAST_MODE=hybrid
```

`HOPCAST_MODE` accepts `offlineOnly` (default), `onlineOnly` or `hybrid`.
