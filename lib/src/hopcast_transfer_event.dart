/// The kind of a transfer lifecycle event delivered on
/// [HopcastFlutter.transferEvents] (or as the `type` key of the raw
/// [HopcastFlutter.transfers] maps).
enum HopcastTransferType {
  /// An incoming transfer is requesting approval (receiver side, MANUAL policy).
  /// Answer with [HopcastFlutter.acceptTransfer] / [HopcastFlutter.rejectTransfer].
  invitation,

  /// A multi-file / multi-peer send has started (sender side).
  bulkStarted,

  /// Aggregate byte progress for a transfer.
  transferProgress,

  /// Byte progress for a single file within a transfer.
  fileProgress,

  /// A single file finished; [HopcastTransferEvent.localPath] points to it (receiver).
  fileCompleted,

  /// A single file failed.
  fileFailed,

  /// The whole transfer failed.
  transferFailed,

  /// A multi-peer send finished; see [HopcastTransferEvent.outcomes] for the
  /// per-recipient result.
  bulkFinished,

  /// An event type this version of the package does not map — ignore it.
  unknown;

  static HopcastTransferType parse(String? raw) {
    switch (raw) {
      case 'invitation':
        return HopcastTransferType.invitation;
      case 'bulkStarted':
        return HopcastTransferType.bulkStarted;
      case 'transferProgress':
        return HopcastTransferType.transferProgress;
      case 'fileProgress':
        return HopcastTransferType.fileProgress;
      case 'fileCompleted':
        return HopcastTransferType.fileCompleted;
      case 'fileFailed':
        return HopcastTransferType.fileFailed;
      case 'transferFailed':
        return HopcastTransferType.transferFailed;
      case 'bulkFinished':
        return HopcastTransferType.bulkFinished;
      default:
        return HopcastTransferType.unknown;
    }
  }
}

/// The result of a send towards a single recipient, part of a
/// [HopcastTransferType.bulkFinished] event.
class HopcastTransferOutcome {
  const HopcastTransferOutcome({
    required this.peerName,
    required this.status,
    this.reason,
  });

  /// Display name of the recipient.
  final String peerName;

  /// `SUCCESS` or `FAILED` (opaque enum name from the native SDK).
  final String status;

  /// Failure reason when [status] is `FAILED` (opaque enum name), else null.
  final String? reason;

  bool get isSuccess => status == 'SUCCESS';

  factory HopcastTransferOutcome.fromMap(Map<dynamic, dynamic> map) =>
      HopcastTransferOutcome(
        peerName: (map['peerName'] ?? '').toString(),
        status: (map['status'] ?? '').toString(),
        reason: map['reason']?.toString(),
      );
}

/// A strongly-typed view over a `hopcast/transfers` event map.
///
/// The raw map is still available through [HopcastFlutter.transfers]; this class
/// is a convenience wrapper produced by [HopcastFlutter.transferEvents]. Only the
/// fields relevant to a given [type] are populated (see the event table in the
/// README / API reference).
class HopcastTransferEvent {
  const HopcastTransferEvent({
    required this.type,
    required this.isReceiver,
    this.transferId,
    this.peerName,
    this.fileName,
    this.localPath,
    this.reason,
    this.bytesTransferred,
    this.totalBytes,
    this.fileIndex,
    this.fileTotal,
    this.totalPeers,
    this.totalFiles,
    this.senderName,
    this.fileCount,
    this.meta,
    this.outcomes,
  });

  /// The event kind. Prefer switching on this rather than on the raw string.
  final HopcastTransferType type;

  /// True when this device is the receiver of the transfer, false when sender.
  final bool isReceiver;

  final String? transferId;
  final String? peerName;
  final String? fileName;

  /// Absolute path of a received file (populated on
  /// [HopcastTransferType.fileCompleted], receiver side).
  final String? localPath;

  /// Opaque failure reason enum name (on `*Failed` events).
  final String? reason;

  final int? bytesTransferred;
  final int? totalBytes;
  final int? fileIndex;
  final int? fileTotal;
  final int? totalPeers;
  final int? totalFiles;

  // --- Incoming invitation only (type == invitation) ---
  final String? senderName;
  final int? fileCount;

  /// Free-form metadata string set by the sender in [HopcastFlutter.sendFiles].
  final String? meta;

  // --- bulkFinished only ---
  final List<HopcastTransferOutcome>? outcomes;

  factory HopcastTransferEvent.fromMap(Map<dynamic, dynamic> map) {
    int? asInt(dynamic v) => (v is num) ? v.toInt() : null;
    final rawOutcomes = map['outcomes'];
    return HopcastTransferEvent(
      type: HopcastTransferType.parse(map['type']?.toString()),
      isReceiver: map['isReceiver'] == true,
      transferId: map['transferId']?.toString(),
      peerName: map['peerName']?.toString(),
      fileName: map['fileName']?.toString(),
      localPath: map['localPath']?.toString(),
      reason: map['reason']?.toString(),
      bytesTransferred: asInt(map['bytesTransferred']),
      totalBytes: asInt(map['totalBytes']),
      fileIndex: asInt(map['fileIndex']),
      fileTotal: asInt(map['fileTotal']),
      totalPeers: asInt(map['totalPeers']),
      totalFiles: asInt(map['totalFiles']),
      senderName: map['senderName']?.toString(),
      fileCount: asInt(map['fileCount']),
      meta: map['meta']?.toString(),
      outcomes: rawOutcomes is List
          ? rawOutcomes
              .whereType<Map>()
              .map(HopcastTransferOutcome.fromMap)
              .toList(growable: false)
          : null,
    );
  }

  bool get isInvitation => type == HopcastTransferType.invitation;
  bool get isFileCompleted => type == HopcastTransferType.fileCompleted;
  bool get isBulkFinished => type == HopcastTransferType.bulkFinished;
  bool get isFailed =>
      type == HopcastTransferType.transferFailed ||
      type == HopcastTransferType.fileFailed;

  /// At least one recipient received successfully (bulkFinished).
  bool get anyOutcomeSuccess =>
      (outcomes ?? const []).any((o) => o.isSuccess);

  /// The transfer was rejected (receiver declined, or the sender was blocked).
  bool get wasRejected {
    if (reason != null && reason!.toUpperCase().contains('REJECT')) return true;
    return (outcomes ?? const []).any(
        (o) => (o.reason?.toUpperCase().contains('REJECT') ?? false));
  }

  /// Progress fraction in `[0, 1]`, or null when indeterminate.
  double? get progressFraction {
    final total = totalBytes;
    final done = bytesTransferred;
    if (total == null || done == null || total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }

  @override
  String toString() =>
      'HopcastTransferEvent(${type.name}, receiver=$isReceiver, peer=$peerName)';
}
