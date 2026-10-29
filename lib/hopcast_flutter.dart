/// Hopcast device-to-device (D2D) file sharing for Flutter.
///
/// AirDrop-style peer-to-peer file sharing between nearby phones. Discovery and
/// transfers are fully **offline** (no server in the data path), but the SDK
/// requires a **one-time online enrollment** ([HopcastFlutter.provision]) that
/// registers the device against the Hopcast backend; exchange reports are then
/// queued locally and uploaded opportunistically when connectivity returns. The
/// proprietary core ships as a hardened binary bundled with this package (an
/// Android AAR and an iOS XCFramework); this Dart layer is only a thin, typed
/// facade over the platform channels.
///
/// See [HopcastFlutter] for the public API.
library hopcast_flutter;

import 'dart:async';

import 'package:flutter/services.dart';

import 'src/hopcast_identity_exception.dart';
import 'src/hopcast_neighbor.dart';
import 'src/hopcast_online.dart';
import 'src/hopcast_transfer_event.dart';
import 'src/hopcast_transfer_handoff.dart';

export 'src/hopcast_identity_exception.dart';
export 'src/hopcast_neighbor.dart';
export 'src/hopcast_online.dart';
export 'src/hopcast_transfer_event.dart';
export 'src/hopcast_transfer_handoff.dart';

/// Default Bonjour / Nearby service id. **Override it** with a value unique to
/// your app (see [HopcastFlutter.build]) — on iOS it must match the
/// `NSBonjourServices` entries in your `Info.plist`.
const String kHopcastDefaultServiceId = 'hopcast';

/// Thin, typed Dart facade over the native Hopcast SDK (Android + iOS).
///
/// All proprietary logic lives in the bundled, pre-hardened binaries; this class
/// only marshals calls and events across the platform channels:
///
/// * `MethodChannel("hopcast/methods")`
/// * `EventChannel("hopcast/neighbors")` — full neighbour snapshots
/// * `EventChannel("hopcast/transfers")` — typed transfer lifecycle events
/// * `EventChannel("hopcast/online")` — online-mode events (cloud session…)
/// * `EventChannel("hopcast/handoffs")` — orchestrated transfer handoffs
///
/// The same Dart API drives both platforms. There is **no cross-platform
/// interop**: Android talks to Android, iOS talks to iOS (different transports).
///
/// Typical lifecycle:
///
/// ```dart
/// final hopcast = HopcastFlutter.instance;
/// await hopcast.requestPermissions();
/// await hopcast.build(deviceId: 'My-Phone', serviceId: 'myapp');
/// if (!await hopcast.isProvisioned()) {
///   // One-time, requires connectivity — typically right after your app login.
///   await hopcast.provision(sdkKey: 'pk_live_YOUR_KEY', userId: user.id);
/// }
/// await hopcast.startSharing();
/// hopcast.neighbors.listen((peers) { /* update UI */ });
/// // …later
/// await hopcast.release();
/// ```
///
/// Until [provision] has succeeded once on the device, the SDK is **inert**:
/// every D2D call ([startSharing], [sendFiles], [acceptTransfer]…) is a native
/// no-op that only logs a warning.
class HopcastFlutter {
  HopcastFlutter._();

  /// The shared singleton instance.
  static final HopcastFlutter instance = HopcastFlutter._();

  static const MethodChannel _methods = MethodChannel('hopcast/methods');
  static const EventChannel _neighborsChannel =
      EventChannel('hopcast/neighbors');
  static const EventChannel _transfersChannel =
      EventChannel('hopcast/transfers');
  static const EventChannel _onlineChannel = EventChannel('hopcast/online');
  static const EventChannel _handoffsChannel =
      EventChannel('hopcast/handoffs');

  Stream<List<HopcastNeighbor>>? _neighbors;
  Stream<Map<dynamic, dynamic>>? _transfers;
  Stream<HopcastOnlineEvent>? _online;
  Stream<HopcastTransferHandoff>? _handoffs;

  /// Stream of the current set of nearby devices.
  ///
  /// A **full snapshot** is emitted on every change (an empty list means nobody
  /// is in range). The local device is excluded and entries are de-duplicated by
  /// `endpointId`. A late subscriber immediately receives the last known snapshot.
  Stream<List<HopcastNeighbor>> get neighbors {
    return _neighbors ??= _neighborsChannel
        .receiveBroadcastStream()
        .map((event) => ((event as List?) ?? const [])
            .whereType<Map>()
            .map((e) => HopcastNeighbor.fromMap(e))
            .toList(growable: false));
  }

  /// Raw stream of transfer lifecycle events, as delivered by the native bridge.
  ///
  /// Each event is a `Map` with a `type` key (`invitation`, `bulkStarted`,
  /// `transferProgress`, `fileProgress`, `fileCompleted`, `fileFailed`,
  /// `transferFailed`, `bulkFinished`) plus type-specific fields. This is the
  /// exact wire contract; prefer [transferEvents] for a typed view.
  Stream<Map<dynamic, dynamic>> get transfers {
    return _transfers ??= _transfersChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => e as Map);
  }

  /// Typed convenience wrapper over [transfers].
  Stream<HopcastTransferEvent> get transferEvents =>
      transfers.map(HopcastTransferEvent.fromMap);

  /// Online-mode events (mirror of the native `OnlineEventListener`): cloud
  /// session up/down, orchestrator errors, files the backend wants this device
  /// to acquire. Only emits when built in [HopcastMode.onlineOnly] /
  /// [HopcastMode.hybrid] with online mode enabled.
  Stream<HopcastOnlineEvent> get onlineEvents {
    return _online ??= _onlineChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => HopcastOnlineEvent.fromMap(e as Map));
  }

  /// Typed summaries emitted at the end of every **orchestrated** transfer
  /// (driven by a backend instruction — `instructionId` is always set).
  /// User-triggered ([sendFiles]) transfers are not reported here: follow them
  /// through [transferEvents].
  Stream<HopcastTransferHandoff> get transferHandoffs {
    return _handoffs ??= _handoffsChannel
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => HopcastTransferHandoff.fromMap(e as Map));
  }

  /// Builds the native SDK. **Idempotent** — a single native instance exists per
  /// process; a second call is a no-op until [release] (configuration changes
  /// are then ignored).
  ///
  /// * [deviceId] — the name advertised to peers; must be unique per device.
  ///   In [HopcastMode.onlineOnly] / [HopcastMode.hybrid] the SDK advertises
  ///   its backend [deviceUuid] instead (instructions address peers by it).
  /// * [serviceId] — the discovery namespace. Only devices built with the **same**
  ///   `serviceId` see each other. On iOS it must match the `NSBonjourServices`
  ///   entries (`_<serviceId>._tcp` / `_<serviceId>._udp`) in your `Info.plist`.
  /// * [mode] — operating mode, [HopcastMode.offlineOnly] by default.
  /// * [onlineConfig] — required for [HopcastMode.onlineOnly] /
  ///   [HopcastMode.hybrid] (a default [HopcastOnlineConfig] is used if omitted).
  /// * [autoDisconnectAfterTransfer] — **Android only.** `true` (default,
  ///   unchanged behaviour) drops the device-to-device link after every
  ///   [sendFiles], so the next transfer — possibly to another device — starts
  ///   from a fresh link. `false` keeps the link open across sends: consecutive
  ///   [sendFiles] to the same peer skip the connection + Wi-Fi upgrade (up to
  ///   ~15 s between devices on different Wi-Fi networks). The link is then
  ///   freed when you send to another peer or call [stopSharing]. Ignored on
  ///   iOS, where the MultipeerConnectivity session already stays open until
  ///   [stopSharing] / [release].
  Future<void> build({
    required String deviceId,
    String serviceId = kHopcastDefaultServiceId,
    HopcastMode mode = HopcastMode.offlineOnly,
    HopcastOnlineConfig? onlineConfig,
    bool autoDisconnectAfterTransfer = true,
  }) =>
      _methods.invokeMethod('build', {
        'deviceId': deviceId,
        'serviceId': serviceId,
        'mode': mode.wire,
        'autoDisconnectAfterTransfer': autoDisconnectAfterTransfer,
        if (mode != HopcastMode.offlineOnly)
          'onlineConfig': (onlineConfig ?? const HopcastOnlineConfig()).toMap(),
      });

  /// One-time device enrollment against the Hopcast backend. Call **after**
  /// [build], while the device is online — typically right after the first
  /// login in your app.
  ///
  /// Registers the device with your [sdkKey] (`pk_live_…`) and associates it
  /// with [userId], then persists the device identity (device id + tokens) in
  /// the platform secure store (Android Keystore / iOS Keychain). Once
  /// persisted the identity survives restarts and stays valid **offline
  /// indefinitely**. The same identity serves the offline and online modes.
  ///
  /// **Idempotent** on both platforms: while an identity is persisted the call
  /// succeeds immediately without any network round-trip (the arguments are
  /// then ignored). To re-enroll under a different `sdkKey`/`userId`, call
  /// [clearIdentity] first.
  ///
  /// Until this succeeds once, the SDK is inert: every D2D / reporting call is
  /// a native no-op (see [isProvisioned]).
  ///
  /// The reporting/backend host is fixed and owned by the SDK; the app never
  /// chooses it, so enrollment, token refreshes and deferred exchange reports
  /// always target the same server.
  ///
  /// Throws a [HopcastIdentityException] (a [PlatformException] with
  /// `code: "PROVISION_FAILED"`, or `"NOT_BUILT"` if called before [build])
  /// whose [HopcastIdentityException.error] tells `server` (with
  /// `statusCode`), `invalidResponse`, `transport`… apart.
  Future<void> provision({
    required String sdkKey,
    required String userId,
  }) async {
    try {
      await _methods.invokeMethod('provision', {
        'sdkKey': sdkKey,
        'userId': userId,
      });
    } on PlatformException catch (e) {
      if (e.code == 'PROVISION_FAILED' || e.code == 'NOT_BUILT') {
        throw HopcastIdentityException.fromPlatform(e);
      }
      rethrow;
    }
  }

  /// Whether a device identity is already persisted on this device.
  ///
  /// `false` means the SDK is inert and you must call [provision] (once,
  /// online). On Android this requires [build] to have been called first.
  Future<bool> isProvisioned() async =>
      await _methods.invokeMethod<bool>('isProvisioned') ?? false;

  /// Drops the persisted device identity; the SDK becomes inert again until
  /// the next successful [provision].
  ///
  /// Use it to re-enroll under a different `sdkKey` / `userId` (key rotation,
  /// user switch): `await clearIdentity(); await provision(…)`. The sequence
  /// behaves identically on both platforms.
  Future<void> clearIdentity() => _methods.invokeMethod('clearIdentity');

  /// The backend-assigned device id (`dev_…`) obtained at [provision] — the
  /// identifier the cloud orchestrator uses, and the name advertised to peers
  /// in online / hybrid mode. `"unknown"` until provisioned (or, on Android,
  /// before [build]).
  Future<String> deviceUuid() async =>
      await _methods.invokeMethod<String>('deviceUuid') ?? 'unknown';

  /// The mode the native SDK was built with ([HopcastMode.offlineOnly] before
  /// [build]).
  Future<HopcastMode> mode() async =>
      HopcastMode.parse(await _methods.invokeMethod<String>('getMode'));

  // --- Online mode (HopcastMode.onlineOnly / hybrid) ---

  /// Opens the cloud session (presence, instructions, acks) and makes the
  /// device available for cloud-orchestrated transfers; the radios are started
  /// too. Idempotent. Native no-op while unprovisioned, in
  /// [HopcastMode.offlineOnly], or without an online config.
  Future<void> enableOnlineMode() => _methods.invokeMethod('enableOnlineMode');

  /// Closes the cloud session; the offline subsystem keeps running if it was
  /// on. Idempotent.
  Future<void> disableOnlineMode() =>
      _methods.invokeMethod('disableOnlineMode');

  /// Declares to the backend that this device now holds [contentIds]
  /// (`has/new`), e.g. after a download performed by the app itself. D2D
  /// receptions executed under an instruction are declared automatically.
  Future<void> reportDownloadedFile({
    required HopcastInfraType infraType,
    required List<String> contentIds,
  }) =>
      _methods.invokeMethod('reportDownloadedFile', {
        'infraType': infraType.wire,
        'contentIds': contentIds,
      });

  /// Withdraws [contentIds] from the backend inventory (`has/remove`) after
  /// they were deleted locally.
  Future<void> reportRemovedFile(List<String> contentIds) =>
      _methods.invokeMethod('reportRemovedFile', {'contentIds': contentIds});

  /// Files a need for [contentId] (`needs/new`): the backend orchestrates a D2D
  /// delivery toward this device from a neighbour that has it. Returns the
  /// `needId` (for [cancelNeed]), or `null` when unprovisioned / no online
  /// subsystem.
  ///
  /// Avoid filing a need while one of your own [sendFiles] is still running
  /// (wait for its `bulkFinished` on [transferEvents]): the orchestrated
  /// delivery would compete with it for the single device-to-device link.
  Future<String?> declareNeed({
    required String contentId,
    required int ttlSeconds,
  }) =>
      _methods.invokeMethod<String>('declareNeed', {
        'contentId': contentId,
        'ttlSeconds': ttlSeconds,
      });

  /// Cancels a need previously filed with [declareNeed] (`needs/cancel`).
  Future<void> cancelNeed(String needId) =>
      _methods.invokeMethod('cancelNeed', {'needId': needId});

  /// Forwards a raw FCM data message (e.g. `RemoteMessage.data` from
  /// `firebase_messaging`) to the SDK. Messages it does not recognise are
  /// ignored, so forwarding everything is safe. Values are stringified.
  Future<void> handleFcmMessage(Map<String, dynamic> data) =>
      _methods.invokeMethod('handleFcmMessage', {
        'data': data.map((k, v) => MapEntry(k, v?.toString() ?? '')),
      });

  /// Forwards a refreshed FCM registration token to the SDK, which registers
  /// it with the backend so the wake-up push can reach a sleeping app.
  Future<void> handleFcmToken(String token) =>
      _methods.invokeMethod('handleFcmToken', {'token': token});

  /// The runtime permissions the SDK needs on this device / API level.
  ///
  /// On iOS this returns an empty list (permissions are prompted lazily by the
  /// system on first Bonjour discovery).
  Future<List<String>> getRequiredPermissions() async {
    final list =
        await _methods.invokeMethod<List<dynamic>>('getRequiredPermissions');
    return (list ?? const []).cast<String>();
  }

  /// Requests any missing runtime permissions; resolves `true` once all are
  /// granted. On iOS this is best-effort `true` (the "Local Network" prompt is
  /// shown by the system on first discovery).
  Future<bool> requestPermissions() async =>
      await _methods.invokeMethod<bool>('requestPermissions') ?? false;

  /// Starts advertising + discovery (continuous while running) — the offline
  /// subsystem toggle (native `startSharing` / `enableOfflineMode`). Native
  /// no-op in [HopcastMode.onlineOnly].
  Future<void> startSharing() => _methods.invokeMethod('startSharing');

  /// Stops advertising + discovery and tears down connections.
  Future<void> stopSharing() => _methods.invokeMethod('stopSharing');

  /// Whether Wi-Fi is on. Wi-Fi is required for a fast transfer; with it off the
  /// transport falls back to (much slower) Bluetooth. On iOS this is best-effort
  /// `true`.
  Future<bool> isWifiEnabled() async =>
      await _methods.invokeMethod<bool>('isWifiEnabled') ?? true;

  /// Sends [filePaths] to the given [endpointIds].
  ///
  /// Returns a bulk transfer id, or `null` if nothing could be sent (no readable
  /// file / no recipient). Resolve [endpointIds] from the latest [neighbors]
  /// snapshot **just before** calling — they are volatile.
  ///
  /// [metadata] is an optional free-form string delivered to the receiver in the
  /// `invitation` event (`meta` field).
  ///
  /// Progress and completion are reported through [transfers] / [transferEvents]
  /// (`bulkStarted` → `transferProgress`/`fileProgress`/`fileCompleted` →
  /// `bulkFinished`).
  Future<String?> sendFiles({
    required List<String> endpointIds,
    required List<String> filePaths,
    String? metadata,
  }) =>
      _methods.invokeMethod<String>('sendFiles', {
        'endpointIds': endpointIds,
        'filePaths': filePaths,
        'metadata': metadata,
      });

  /// Accepts an incoming transfer invitation (MANUAL policy).
  Future<void> acceptTransfer(String transferId) =>
      _methods.invokeMethod('acceptTransfer', {'transferId': transferId});

  /// Rejects an incoming transfer invitation (MANUAL policy).
  Future<void> rejectTransfer(String transferId) =>
      _methods.invokeMethod('rejectTransfer', {'transferId': transferId});

  /// Releases the SDK and all native resources. After [release] you may [build]
  /// again to reuse the SDK.
  Future<void> release() => _methods.invokeMethod('release');
}
