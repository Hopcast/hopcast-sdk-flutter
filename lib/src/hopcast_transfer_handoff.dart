/// Terminal outcome of an orchestrated transfer ([HopcastTransferHandoff.status]).
enum HopcastHandoffStatus {
  success,
  failure;

  static HopcastHandoffStatus parse(String? raw) =>
      raw?.toLowerCase() == 'success'
          ? HopcastHandoffStatus.success
          : HopcastHandoffStatus.failure;
}

/// Direction of a file from this device's own point of view.
enum HopcastExchangeDirection {
  /// Bytes received by this device.
  download,

  /// Bytes sent by this device.
  upload;

  static HopcastExchangeDirection parse(String? raw) =>
      raw?.toLowerCase() == 'upload'
          ? HopcastExchangeDirection.upload
          : HopcastExchangeDirection.download;
}

/// Per-file detail of a [HopcastTransferHandoff].
class HopcastHandoffFile {
  const HopcastHandoffFile({
    required this.fileId,
    required this.bytes,
    required this.direction,
  });

  /// Content identifier of the file.
  final String fileId;

  /// Applicative bytes actually transferred for this file.
  final int bytes;

  final HopcastExchangeDirection direction;

  factory HopcastHandoffFile.fromMap(Map<dynamic, dynamic> map) =>
      HopcastHandoffFile(
        fileId: (map['fileId'] ?? '').toString(),
        bytes: (map['bytes'] is num) ? (map['bytes'] as num).toInt() : 0,
        direction: HopcastExchangeDirection.parse(map['direction']?.toString()),
      );
}

/// Typed completion summary of an **orchestrated** transfer (one driven by a
/// backend instruction), delivered on [HopcastFlutter.transferHandoffs].
///
/// Mirror of the native `TransferHandoff` (common denominator of iOS and
/// Android). The SDK already acknowledges the instruction to the backend on
/// its own; the app only observes, for UI / analytics.
class HopcastTransferHandoff {
  const HopcastTransferHandoff({
    required this.instructionId,
    required this.status,
    this.reason,
    this.bytesTotal,
    this.files,
  });

  /// The backend instruction this transfer executed.
  final String instructionId;

  final HopcastHandoffStatus status;

  /// Failure cause when [status] is [HopcastHandoffStatus.failure].
  final String? reason;

  /// Sum of the applicative bytes transferred (Σ files), from this device's
  /// point of view. `null` when not measurable.
  final int? bytesTotal;

  /// Optional per-file breakdown (files that actually completed).
  final List<HopcastHandoffFile>? files;

  bool get isSuccess => status == HopcastHandoffStatus.success;

  factory HopcastTransferHandoff.fromMap(Map<dynamic, dynamic> map) {
    final rawFiles = map['files'];
    final total = map['bytesTotal'];
    return HopcastTransferHandoff(
      instructionId: (map['instructionId'] ?? '').toString(),
      status: HopcastHandoffStatus.parse(map['status']?.toString()),
      reason: map['reason']?.toString(),
      bytesTotal: total is num ? total.toInt() : null,
      files: rawFiles is List
          ? rawFiles
              .whereType<Map>()
              .map(HopcastHandoffFile.fromMap)
              .toList(growable: false)
          : null,
    );
  }

  @override
  String toString() =>
      'HopcastTransferHandoff($instructionId, ${status.name}, bytes=$bytesTotal)';
}
