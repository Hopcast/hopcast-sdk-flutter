/// Operating mode of the native SDK, chosen once at [HopcastFlutter.build] time.
///
/// Mirrors the native `Mode` enum (iOS `Mode.offlineOnly/onlineOnly/hybrid`,
/// Android `Mode.OFFLINE_ONLY/ONLINE_ONLY/HYBRID`).
enum HopcastMode {
  /// Only the AirDrop-like device-to-device flow. No cloud session is ever
  /// opened. Default — behaves exactly like previous versions of the plugin.
  offlineOnly,

  /// Only the cloud-orchestrated flow: the backend pushes instructions (MQTT,
  /// FCM wake-up) and the SDK executes the D2D transfers on its own. Requires
  /// a [HopcastOnlineConfig].
  onlineOnly,

  /// Both subsystems coexist; the app toggles them with
  /// [HopcastFlutter.startSharing]/[HopcastFlutter.stopSharing] (offline) and
  /// [HopcastFlutter.enableOnlineMode]/[HopcastFlutter.disableOnlineMode]
  /// (online). Requires a [HopcastOnlineConfig].
  hybrid;

  /// Wire name used on the platform channel.
  String get wire => name;

  static HopcastMode parse(String? raw) {
    switch (raw) {
      case 'onlineOnly':
        return HopcastMode.onlineOnly;
      case 'hybrid':
        return HopcastMode.hybrid;
      default:
        return HopcastMode.offlineOnly;
    }
  }
}

/// Configuration of the cloud-orchestrated subsystem — required when building
/// in [HopcastMode.onlineOnly] or [HopcastMode.hybrid], ignored otherwise.
///
/// Authentication does **not** live here: the cloud session authenticates with
/// the device identity persisted by [HopcastFlutter.provision].
class HopcastOnlineConfig {
  const HopcastOnlineConfig({
    this.brokerUrl,
    this.isSecondaryFcm = true,
    this.runAsService = false,
  });

  /// MQTT-over-WebSocket URL of the Hopcast broker. `null` keeps the SDK's
  /// production default (`wss://mqtt.hopcast.io/mqtt`); override for staging /
  /// local development only.
  final String? brokerUrl;

  /// `true` (default) when the host app owns the FCM entry points — the usual
  /// case in Flutter, where `firebase_messaging` registers the messaging
  /// service / delegate. Forward push data and token refreshes through
  /// [HopcastFlutter.handleFcmMessage] and [HopcastFlutter.handleFcmToken].
  ///
  /// `false` is only meaningful on Android when the app declares the SDK's own
  /// `HopcastFirebaseMessagingService` and ships `firebase-messaging`.
  final bool isSecondaryFcm;

  /// Android: the host keeps the SDK foreground service running so the cloud
  /// session survives the activity. iOS: intent only (no equivalent).
  final bool runAsService;

  Map<String, Object?> toMap() => {
        'brokerUrl': brokerUrl,
        'isSecondaryFcm': isSecondaryFcm,
        'runAsService': runAsService,
      };
}

/// Where a content was actually retrieved from, declared through
/// [HopcastFlutter.reportDownloadedFile]. Wire values are byte-exact with both
/// native SDKs.
enum HopcastInfraType {
  /// Acquired device-to-device.
  d2d('d2d'),

  /// Downloaded by the host app over Wi-Fi.
  wifi('wifi'),

  /// Downloaded by the host app over cellular.
  cellular('cellular'),

  /// Content that was already on disk before the SDK ran.
  stored('already_stored');

  const HopcastInfraType(this.wire);

  /// Value sent to the backend.
  final String wire;
}

/// The kind of an online-mode event delivered on [HopcastFlutter.onlineEvents].
enum HopcastOnlineEventType {
  /// The backend wants this device to acquire [HopcastOnlineEvent.fileIds]
  /// without imposing a transport (`OnlineEventListener.onFilesToBeDownloaded`).
  filesToBeDownloaded,

  /// The cloud session is up; [HopcastOnlineEvent.deviceUuid] is set
  /// (`onCloudReady`). May fire again after each reconnection.
  cloudReady,

  /// The cloud session dropped; the SDK retries on its own
  /// (`onCloudDisconnected`).
  cloudDisconnected,

  /// The orchestrator reported an error; see [HopcastOnlineEvent.reason]
  /// (`onCloudError`).
  cloudError,

  /// An event type this version of the package does not map — ignore it.
  unknown;

  static HopcastOnlineEventType parse(String? raw) {
    switch (raw) {
      case 'filesToBeDownloaded':
        return HopcastOnlineEventType.filesToBeDownloaded;
      case 'cloudReady':
        return HopcastOnlineEventType.cloudReady;
      case 'cloudDisconnected':
        return HopcastOnlineEventType.cloudDisconnected;
      case 'cloudError':
        return HopcastOnlineEventType.cloudError;
      default:
        return HopcastOnlineEventType.unknown;
    }
  }
}

/// A typed online-mode event (mirror of the native `OnlineEventListener`).
class HopcastOnlineEvent {
  const HopcastOnlineEvent({
    required this.type,
    this.fileIds = const [],
    this.deviceUuid,
    this.reason,
  });

  final HopcastOnlineEventType type;

  /// Populated on [HopcastOnlineEventType.filesToBeDownloaded].
  final List<String> fileIds;

  /// Populated on [HopcastOnlineEventType.cloudReady].
  final String? deviceUuid;

  /// Populated on [HopcastOnlineEventType.cloudError].
  final String? reason;

  factory HopcastOnlineEvent.fromMap(Map<dynamic, dynamic> map) {
    final ids = map['fileIds'];
    return HopcastOnlineEvent(
      type: HopcastOnlineEventType.parse(map['type']?.toString()),
      fileIds: ids is List
          ? ids.map((e) => e.toString()).toList(growable: false)
          : const [],
      deviceUuid: map['deviceUuid']?.toString(),
      reason: map['reason']?.toString(),
    );
  }

  @override
  String toString() => 'HopcastOnlineEvent(${type.name})';
}
