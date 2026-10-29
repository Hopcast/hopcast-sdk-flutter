# Troubleshooting

## No devices are discovered

- **Device not provisioned.** Since 0.3.0 the SDK is **inert** until
  `provision()` has succeeded once on the device: `startSharing()` silently
  no-ops (a warning shows in the native logs). Check `isProvisioned()` and call
  `provision(sdkKey: …, userId: …)` while online.
- **Different `serviceId`.** Both devices must build with the **same** `serviceId`.
  On iOS it must also match `NSBonjourServices` (`_<serviceId>._tcp` / `_udp`).
- **Cross-platform.** iOS↔Android never discover each other. Test iOS↔iOS or
  Android↔Android.
- **`startSharing()` not called** (or the app is backgrounded). Discovery only runs
  while foreground.
- **Permissions denied** (Android). Without Bluetooth/location/nearby permissions
  there is no discovery. Re-check `requestPermissions()`.
- **iOS Local Network prompt dismissed.** If the user denied "Local Network",
  discovery is blocked. Re-enable it in iOS Settings → your app → Local Network.
- **Radios off.** Turn Bluetooth on (both) and Wi-Fi on (for throughput).
- Give it a few seconds — calling `startSharing()` again (e.g. reopening the
  sharing screen) is safe and refreshes discovery.

## Permissions keep being denied (Android)

- The user may have selected "Don't ask again". Send them to app settings.
- On Android 12+, location must be enabled system-wide for BLE scanning to yield
  results in some OEM builds.
- Verify `getRequiredPermissions()` against what your consent UI actually requests.

## Build fails: "requires core library desugaring"

Enable core library desugaring in the host app — see
[integration.md §2.2](integration.md#22-core-library-desugaring).

## Build fails: duplicate `META-INF` / packaging errors (Android)

Add the packaging `excludes` / `pickFirsts` block — see
[integration.md §2.3](integration.md#23-packaging-exclusions).

## Build fails: could not resolve `fr.hopcast:sdk-hopcast-android`

The bundled Maven repo lives inside the plugin (`android/repo/`) and is injected
into all projects by the plugin's `build.gradle`. If resolution still fails,
ensure your app's `settings.gradle` does **not** force
`RepositoriesMode.FAIL_ON_PROJECT_REPOS` (Flutter's default template does not).

## iOS: "requires a higher minimum iOS deployment version"

Set `platform :ios, '15.0'` in `ios/Podfile` (and bump the Runner deployment
target to ≥ 15.0), then `pod install` — see
[integration.md §3.1](integration.md#31-deployment-target).

## Transfers are extremely slow

- **Wi-Fi is off.** The transport fell back to Bluetooth Classic. Enable Wi-Fi on
  both devices; ideally the same network.
- **A previous connection is pinning the high-speed Wi-Fi data-path.** The SDK
  auto-disconnects after each transfer to avoid this; if you send in a tight loop,
  serialise sends.
- **Android 13+ without `NEARBY_WIFI_DEVICES`.** The transfer can't rise to Wi-Fi.
- **Android: mobile hotspot on.** With the Wi-Fi hotspot (tethering) enabled on
  either device, Android does not let Nearby create the Wi-Fi Direct / Aware
  link: transfers work but stay on Bluetooth. OS limitation — ask users to turn
  the hotspot off for large transfers.
- **Android: every send to the same peer is slow to start.** Each new connection
  pays the Wi-Fi upgrade (up to ~15 s across different Wi-Fi networks). Build
  with `autoDisconnectAfterTransfer: false` to keep the link between sends.

## Android release build: transfers never complete / crash in R8 builds

`ClassCastException … LinkedTreeMap`, `Can't find '[toLeakAwareBuffer]'`, or
transfers that never finish in a minified build: plugin ≤ 0.4.0 (SDK 0.5.1)
was not robust to the app's R8 pass. Upgrade to 0.4.1 (SDK 0.5.2) and remove
any Hopcast-specific rule you added as a workaround — none is needed.

## Receiver never gets the file

- The invitation was never accepted. With the MANUAL policy nothing is received
  until `acceptTransfer`. Check your invitation handler runs (listen to
  `transferEvents` before sharing).
- The sender never connected (iOS `invite → established` timed out). Move the
  devices closer and retry.
- Look for a `bulkFinished` outcome with `status: FAILED` and inspect its `reason`.

## Nothing sent — `sendFiles` returned `null`

`null` means the inputs were invalid: no **readable, non-empty** file, or no
recipient. Verify the paths exist and `endpointIds` is non-empty and freshly
resolved.

## Online mode: never `cloudReady`

- Plugin 0.4.0 on Android: the bundled SDK 0.5.1 missed
  `io.netty:netty-codec-http` (the WebSocket transport). Fixed in 0.4.1 — drop
  any manual `netty-codec-http` dependency you added as a workaround.
- Built with `HopcastMode.offlineOnly` (default)? Online calls are no-ops —
  pass `mode: HopcastMode.hybrid` / `onlineOnly` to `build()` (the first
  `build()` of the process wins; `release()` first to change it).
- Not provisioned yet? `enableOnlineMode()` is replayed after a successful
  `provision()`, but nothing happens before.
- Check `deviceUuid()` is not `"unknown"`, and that the device can reach the
  broker (`wss://mqtt.hopcast.io/mqtt` unless overridden).

## `provision` throws `HopcastIdentityException`

- `error == server` → inspect `statusCode` (401/403: wrong `sdkKey`).
- `error == transport` → no connectivity; retry once online.
- `error == notBuilt` → call `build()` first.
