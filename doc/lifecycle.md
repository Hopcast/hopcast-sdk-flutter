# Lifecycle & best practices

## Build once, idempotently

`build()` creates a single native instance per process. Calling it again is a
no-op until you `release()`. It's safe to call `build()` on every app start —
wire it into your bootstrap.

```dart
await hopcast.requestPermissions();
await hopcast.build(deviceId: myUniqueName, serviceId: 'myapp');
if (!await hopcast.isProvisioned()) {
  await hopcast.provision(sdkKey: 'pk_live_…', userId: user.id);
}
await hopcast.startSharing();
```

## Provision once, right after login

`provision()` is the one call that needs connectivity — do it right after your
app's first login, when the device is guaranteed online. The identity is stored
in the platform secure store and survives restarts and airplane mode; there is
no re-enrollment on later launches (guard with `isProvisioned()`). Until it has
succeeded once, **every D2D call is a native no-op** — a common "nothing
happens" cause. If `provision` fails (offline, rejected key), keep the app
usable and retry on the next launch or connectivity change.

To switch the enrolled user or rotate the tenant key, clear then re-provision:

```dart
await hopcast.clearIdentity();
await hopcast.provision(sdkKey: newKey, userId: newUser.id);
```

## Pick a stable `deviceId`

`deviceId` is what peers see and, if you build a trust policy, the key you match
on. Generate it once and persist it (e.g. an "Adjective + Animal" friendly name,
as the demo does). Don't regenerate it on every launch.

## `endpointId` is volatile

`HopcastNeighbor.endpointId` is only valid for the current discovery session and
changes between sessions. **Never persist it.** Always resolve it from the latest
`neighbors` snapshot immediately before calling `sendFiles`:

```dart
final peers = await hopcast.neighbors.first;      // or your cached last snapshot
final ids = peers.where(isSelected).map((n) => n.endpointId).toList();
await hopcast.sendFiles(endpointIds: ids, filePaths: paths);
```

## Subscribe before you share

Attach your `neighbors` and `transferEvents` listeners **before** `startSharing()`
so you don't miss early events. Late subscribers to `neighbors` still get the last
snapshot replayed, but transfer events are not buffered.

## Wi-Fi = throughput

Discovery works on Bluetooth alone, but transfers are only fast over Wi-Fi. Check
`isWifiEnabled()` (Android) and prompt the user to turn Wi-Fi on before a large
send. On Android 13+, make sure `NEARBY_WIFI_DEVICES` is granted (covered by
`requestPermissions()`).

## Foreground continuous discovery

Keep the app foreground while sharing. The plugin advertises/discovers
continuously in the foreground and stops in the background to save the radios
(Android drives this off the process lifecycle automatically).

## Serialise big sends

Only one transfer is active at a time per device. For many recipients or large
payloads, prefer sending sequentially (send to A, await `bulkFinished`, then B)
rather than fanning out.

## Approve incoming transfers (MANUAL policy)

Every incoming transfer arrives as an `invitation` event; nothing is received
until you call `acceptTransfer` (or `rejectTransfer`). Build your policy on top —
the demo shows allow/block lists plus an "everyone / ask each time" mode.

```dart
hopcast.transferEvents
    .where((e) => e.isInvitation)
    .listen((e) async {
  final id = e.transferId!;
  if (await myPolicy.isBlocked(e.senderName!)) {
    await hopcast.rejectTransfer(id);
  } else {
    await hopcast.acceptTransfer(id);
  }
});
```

## Collect received files

On `fileCompleted` (receiver), `localPath` is the absolute path of the file in
the SDK inbox. Move/copy it into your own storage promptly; the inbox is a cache.

## Release when done

Call `release()` when the sharing feature closes (or the user logs out). It stops
sharing, removes listeners and frees native resources. `build()` again to reuse.

```dart
@override
void dispose() {
  _neighborsSub.cancel();
  _transfersSub.cancel();
  hopcast.release();
  super.dispose();
}
```
