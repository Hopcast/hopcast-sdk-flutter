# Integration guide — Android & iOS

This guide covers everything a host app must configure to use `hopcast_flutter`.
For the full API surface see [api.md](api.md); for platform-specific behaviour
see [platform_notes.md](platform_notes.md).

---

## 0. Add the dependency

```yaml
# app/pubspec.yaml
dependencies:
  hopcast_flutter:
    git:
      url: https://github.com/Hopcast/hopcast-sdk-flutter
      ref: 0.4.1   # release tag
```

```bash
flutter pub get
```

The plugin **auto-registers** on both platforms (Flutter plugin loader) — no
manual wiring in `MainActivity` or `AppDelegate`.

---

## 1. Choose a `serviceId`

`serviceId` is the discovery namespace: **only devices built with the same
`serviceId` see each other**. Pick a short, app-specific, lowercase, ASCII value
(letters/digits, no spaces), e.g. `"myapp"`.

```dart
await HopcastFlutter.instance.build(deviceId: 'My-Phone', serviceId: 'myapp');
```

On **iOS** this value must match the `NSBonjourServices` entries in `Info.plist`
(see §3). If it doesn't, iOS silently blocks the Bonjour service — no discovery,
no prompt.

If you omit `serviceId`, it defaults to `'hopcast'` (Android additionally falls
back to the host package name when the value is blank). **Always set it
explicitly** for a shipped app.

---

## 2. Android setup

### 2.1 Min SDK

Hopcast requires **`minSdkVersion 21`** (Android 5.0). In `android/app/build.gradle`
(or `build.gradle.kts`):

```kotlin
// build.gradle.kts
defaultConfig {
    minSdk = maxOf(flutter.minSdkVersion, 21)
}
```

### 2.2 Core library desugaring

The SDK uses `java.time` / `java.nio` APIs and therefore requires **core library
desugaring** on the host app. In `android/app/build.gradle.kts`:

```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

<details>
<summary>Groovy equivalent</summary>

```groovy
android {
    compileOptions {
        coreLibraryDesugaringEnabled true
    }
}
dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'
}
```
</details>

Without it the build fails with *"Dependency 'fr.hopcast:sdk-hopcast-android'
requires core library desugaring to be enabled"*.

### 2.3 Packaging exclusions

Some transitive jars of the SDK (Nearby / Netty) ship duplicate `META-INF`
entries that collide at package time. Add to the app `android { }` block:

```kotlin
// build.gradle.kts
packaging {
    resources {
        excludes += setOf(
            "META-INF/INDEX.LIST",
            "META-INF/io.netty.versions.properties",
            "META-INF/DEPENDENCIES",
            "META-INF/LICENSE", "META-INF/LICENSE.txt",
            "META-INF/NOTICE", "META-INF/NOTICE.txt",
        )
        pickFirsts += setOf("META-INF/native-image/**")
    }
}
```

<details>
<summary>Groovy equivalent (<code>build.gradle</code>)</summary>

```groovy
android {
    packaging {
        resources {
            excludes += [
                'META-INF/INDEX.LIST', 'META-INF/io.netty.versions.properties',
                'META-INF/DEPENDENCIES', 'META-INF/LICENSE', 'META-INF/LICENSE.txt',
                'META-INF/NOTICE', 'META-INF/NOTICE.txt',
            ]
            pickFirsts += ['META-INF/native-image/**']
        }
    }
}
```
</details>

### 2.4 Permissions

All Nearby/Bluetooth/Wi-Fi/location permissions are **declared by the bundled
AAR** and merged into your app automatically — you do **not** need to add
`<uses-permission>` entries yourself. But on Android 6+ they must be **requested
at runtime**:

```dart
final granted = await HopcastFlutter.instance.requestPermissions();
if (!granted) {
  // Nearby sharing cannot start — inform the user.
}
```

`getRequiredPermissions()` returns the exact list for the current API level if
you want to drive your own consent UX. The set spans, by API level:

| API level | Permissions |
|---|---|
| all | `INTERNET`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_STATE`, `ACCESS_NETWORK_STATE` |
| 21–30 | `BLUETOOTH`, `BLUETOOTH_ADMIN` |
| ≤28 | `ACCESS_COARSE_LOCATION` |
| ≥29 | `ACCESS_FINE_LOCATION` |
| ≥31 | `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` |
| ≥33 | `NEARBY_WIFI_DEVICES` |

> **Android 13+**: `NEARBY_WIFI_DEVICES` is **required** for the transfer to rise
> to Wi-Fi. Without it everything stays on (slow) Bluetooth. `requestPermissions()`
> covers it — don't skip it in your consent flow.

### 2.5 The bundled AAR

The SDK is shipped as a self-contained local Maven repo inside the plugin
(`android/repo/`, binary only — `sdk-hopcast-android:0.5.2`). Its POM/module
pulls the SDK's transitive dependencies, which resolve from the consumer's
`google()` / `mavenCentral()` — including `io.netty:netty-codec-http`, the
WebSocket transport of the online mode. Nothing extra to declare (with plugin
0.4.0 / SDK 0.5.1 online mode never reached `cloudReady` without it).

### 2.6 R8 / minified release builds

No rule to write. The AAR ships consumer rules that R8 applies to your app
automatically (full mode, AGP 8+ default): the SDK's public API and services,
the MQTT stack (HiveMQ / Netty / JCTools) and the `-dontwarn` entries for the
optional classes those libraries reference. Since SDK 0.5.2 the
device-to-device protocol uses no reflection, so a debug build and a release
build of your app exchange files normally (0.4.0 release builds could crash
with `ClassCastException … LinkedTreeMap` or `Can't find '[toLeakAwareBuffer]'`).
Don't `-keep` / `-dontshrink` the whole SDK in your own rules — not needed.

---

## 3. iOS setup

### 3.1 Deployment target

The plugin requires **iOS 15.0** (Xcode 27 no longer builds for older
targets). Ensure your Runner's iOS Deployment Target is ≥ 15.0 (Xcode → Runner
target → General), and in `ios/Podfile`:

```ruby
platform :ios, '15.0'
```

### 3.2 Info.plist keys

Add these to `ios/Runner/Info.plist`. **`NSBonjourServices` must match your
`serviceId`** (`_<serviceId>._tcp` and `_<serviceId>._udp`):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover and share files with nearby devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_myapp._tcp</string>
    <string>_myapp._udp</string>
</array>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby devices for file sharing.</string>
```

There is no explicit API to request the "Local Network" permission on iOS: the
system prompt appears automatically on the first Bonjour discovery (i.e. the
first `startSharing()`). `requestPermissions()` returns `true` best-effort so
your Dart flow can proceed to `build()` + `startSharing()`.

### 3.3 The bundled XCFramework

The SDK ships as `ios/Frameworks/HopcastSDKKit.xcframework` (device + simulator
slices, binary only). CocoaPods vendors it automatically via the plugin's
podspec — nothing extra to declare.

> **Testing transfers requires two real devices.** The simulator builds and links
> fine, but iOS peer discovery/transfer only works on hardware.

---

## 4. Wire it up (Dart)

```dart
final hopcast = HopcastFlutter.instance;

// Permissions → build → provision (once, online) → start.
await hopcast.requestPermissions();
await hopcast.build(deviceId: myUniqueName, serviceId: 'myapp');
if (!await hopcast.isProvisioned()) {
  await hopcast.provision(sdkKey: 'pk_live_…', userId: user.id);
}
await hopcast.startSharing();

// Neighbours (full snapshot on every change).
final sub = hopcast.neighbors.listen((peers) { /* update UI */ });

// Transfer events (invitations, progress, completion).
final evs = hopcast.transferEvents.listen((e) async {
  switch (e.type) {
    case HopcastTransferType.invitation:
      await hopcast.acceptTransfer(e.transferId!); // your policy decides
      break;
    case HopcastTransferType.fileCompleted:
      // e.localPath = absolute path of the received file
      break;
    default:
      break;
  }
});

// …on teardown:
await sub.cancel();
await evs.cancel();
await hopcast.release();
```

See [snippets.md](snippets.md) for focused discovery / send / receive examples,
and the runnable [`example/`](../example/) app for the whole flow with a UI.

---

## 5. Provisioning & exchange reporting

Since 0.3.0 the SDK requires a **provisioned device identity**:

- `provision(sdkKey: 'pk_live_YOUR_KEY', userId: …)` performs a one-time enrollment
  against the Hopcast backend. Call it **after** `build()`, while the device is
  online — typically right after your app's first login. Your `sdkKey` is
  provided by Hopcast; `userId` is your own user identifier.
- The identity is persisted in the platform secure store, survives restarts,
  and stays valid **offline indefinitely**. Guard with `isProvisioned()` to
  skip the call on later launches.
- **Until provisioned, the SDK is inert**: `startSharing`, `sendFiles`,
  `acceptTransfer`… silently do nothing. Sharing starts automatically once
  `provision` succeeds if it had been requested.
- Exchange reporting is automatic: transfers are recorded on-device and
  uploaded when connectivity is available. No integration work. These two
  flows (enrollment + reports) are the SDK's only network touchpoints — the
  D2D data path itself never touches a server.

- `provision` is **idempotent**: while an identity exists it succeeds without
  any network call. Failures throw a `HopcastIdentityException`
  (`error == server` with `statusCode`, `transport`, `invalidResponse`…).

---

## 6. Online mode (optional)

By default (`HopcastMode.offlineOnly`) nothing changes. To let the Hopcast
backend orchestrate D2D transfers, build in `onlineOnly` or `hybrid`:

```dart
await hopcast.build(
  deviceId: 'My-Phone',
  serviceId: 'myapp',
  mode: HopcastMode.hybrid,
  onlineConfig: const HopcastOnlineConfig(), // isSecondaryFcm: true by default
);
if (!await hopcast.isProvisioned()) {
  await hopcast.provision(sdkKey: 'pk_live_YOUR_KEY', userId: user.id);
}
hopcast.onlineEvents.listen(onOnlineEvent);
hopcast.transferHandoffs.listen(onHandoff);
await hopcast.enableOnlineMode();

// After a download performed by your app:
await hopcast.reportDownloadedFile(
    infraType: HopcastInfraType.cellular, contentIds: ['content-42']);
// Ask the backend to deliver a content from a nearby device:
final needId = await hopcast.declareNeed(contentId: 'content-43', ttlSeconds: 3600);
```

- The cloud session authenticates with the provisioned identity — no extra
  credential. `deviceUuid()` returns the backend `device_id`, which is also the
  name advertised to peers in online / hybrid mode.
- `hybrid`: `startSharing`/`stopSharing` drive the offline (user-initiated)
  subsystem, `enableOnlineMode`/`disableOnlineMode` the cloud one; both can be
  on at the same time. `onlineOnly`: only the cloud flow.
- Don't call `declareNeed` while one of your own `sendFiles` is still running
  (wait for its `bulkFinished`): the orchestrated delivery would compete with
  it for the device's single D2D link. The Android SDK 0.5.2 serializes these
  cases natively, but the plugin does not expose its transfer-state API (not
  available on iOS), so track your sends through `transferEvents`.

### 6.1 Push (FCM)

The backend wakes sleeping devices with an FCM data push. In Flutter the app
normally owns FCM through `firebase_messaging`, so keep
`isSecondaryFcm: true` (default) and forward:

```dart
FirebaseMessaging.onMessage.listen((m) => hopcast.handleFcmMessage(m.data));
FirebaseMessaging.instance.onTokenRefresh.listen(hopcast.handleFcmToken);
final token = await FirebaseMessaging.instance.getToken();
if (token != null) await hopcast.handleFcmToken(token);
```

Forwarding every message is safe — the SDK ignores what is not its own.
Without push, the cloud session still works whenever the app is alive.

**Android:** the native SDK declares `firebase-messaging` as `compileOnly`;
apps using push already ship it via `firebase_messaging`. Without it the SDK
degrades to "no push".
