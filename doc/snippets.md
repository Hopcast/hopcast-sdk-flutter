# Snippets

Short, copy-paste recipes. See [`example/`](../example/) for the whole flow.

## Bootstrap (permissions → build → provision → share)

```dart
final hopcast = HopcastFlutter.instance;

if (!await hopcast.requestPermissions()) {
  // Inform the user: nearby sharing can't start.
  return;
}
await hopcast.build(deviceId: myUniqueName, serviceId: 'myapp');

// One-time online enrollment; the SDK is inert until it succeeds once.
if (!await hopcast.isProvisioned()) {
  try {
    await hopcast.provision(sdkKey: 'pk_live_…', userId: user.id);
  } on PlatformException catch (e) {
    // Offline or rejected: retry later (e.g. next launch, once online).
    log('provision failed: ${e.message}');
  }
}

await hopcast.startSharing();
```

## Discover nearby devices

```dart
final sub = hopcast.neighbors.listen((peers) {
  // Full snapshot on every change. Empty = nobody in range.
  for (final p in peers) {
    print('${p.displayName}  (${p.endpointId})');
  }
});
```

## Send files to selected peers, with progress

```dart
final bulkId = await hopcast.sendFiles(
  endpointIds: selectedPeers.map((n) => n.endpointId).toList(), // resolve fresh!
  filePaths: ['/path/a.bin', '/path/b.jpg'],
  metadata: 'My caption',
);
if (bulkId == null) {
  // Nothing could be sent (no readable file / no reachable peer).
}

hopcast.transferEvents.where((e) => !e.isReceiver).listen((e) {
  switch (e.type) {
    case HopcastTransferType.transferProgress:
      final pct = ((e.progressFraction ?? 0) * 100).round();
      print('Sending to ${e.peerName}: $pct%');
      break;
    case HopcastTransferType.bulkFinished:
      final ok = e.outcomes?.where((o) => o.isSuccess).length ?? 0;
      final total = e.outcomes?.length ?? 0;
      print('Delivered to $ok/$total peers');
      break;
    default:
      break;
  }
});
```

## Receive: approve invitations and collect files

```dart
hopcast.transferEvents.where((e) => e.isReceiver).listen((e) async {
  switch (e.type) {
    case HopcastTransferType.invitation:
      final id = e.transferId!;
      final accept = await askUser(e.senderName, e.fileCount, e.totalBytes);
      accept ? await hopcast.acceptTransfer(id) : await hopcast.rejectTransfer(id);
      break;
    case HopcastTransferType.fileCompleted:
      final path = e.localPath!;   // absolute path in the SDK inbox
      // move/copy `path` into your own storage
      break;
    default:
      break;
  }
});
```

## Minimal trust policy (blocked / allowed / ask)

```dart
Future<void> onInvitation(HopcastTransferEvent e) async {
  final id = e.transferId!, sender = e.senderName ?? 'Unknown';
  if (await trust.isBlocked(sender)) return hopcast.rejectTransfer(id);
  if (await trust.isAllowed(sender)) return hopcast.acceptTransfer(id);
  // Unknown device → your mode: accept everyone, or prompt.
  final decision = await promptUser(sender);
  decision ? await hopcast.acceptTransfer(id) : await hopcast.rejectTransfer(id);
}
```

## Teardown

```dart
await sub.cancel();
await hopcast.stopSharing();
await hopcast.release();
```

## Online mode (hybrid)

```dart
await hopcast.build(
  deviceId: 'My-Phone',
  serviceId: 'myapp',
  mode: HopcastMode.hybrid,
  onlineConfig: const HopcastOnlineConfig(),
);
hopcast.onlineEvents.listen((e) {
  switch (e.type) {
    case HopcastOnlineEventType.cloudReady:
      print('cloud ready as ${e.deviceUuid}');
      break;
    case HopcastOnlineEventType.filesToBeDownloaded:
      print('backend wants ${e.fileIds}');
      break;
    default:
      break;
  }
});
hopcast.transferHandoffs.listen((h) =>
    print('instruction ${h.instructionId}: ${h.status.name}, ${h.bytesTotal} B'));
await hopcast.enableOnlineMode();
```

## Typed provisioning errors

```dart
try {
  await hopcast.provision(sdkKey: 'pk_live_YOUR_KEY', userId: user.id);
} on HopcastIdentityException catch (e) {
  if (e.error == HopcastIdentityError.server) print('HTTP ${e.statusCode}');
}
```
