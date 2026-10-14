/// A nearby device discovered over Hopcast device-to-device (D2D) transport.
///
/// A snapshot of the currently reachable neighbours is delivered on every change
/// through [HopcastFlutter.neighbors]. The list already excludes the local device
/// and is de-duplicated by [endpointId].
class HopcastNeighbor {
  const HopcastNeighbor({required this.endpointId, required this.displayName});

  /// Opaque, **volatile** transport id — pass this to [HopcastFlutter.sendFiles].
  ///
  /// It is only valid for the current discovery session and changes between
  /// sessions. Never persist it: resolve it from the latest [neighbors] snapshot
  /// just before sending.
  final String endpointId;

  /// Human-readable name advertised by the peer (the `deviceId` it built with).
  final String displayName;

  factory HopcastNeighbor.fromMap(Map<dynamic, dynamic> map) => HopcastNeighbor(
        endpointId: (map['endpointId'] ?? '').toString(),
        displayName: (map['displayName'] ?? '').toString(),
      );

  @override
  bool operator ==(Object other) =>
      other is HopcastNeighbor &&
      other.endpointId == endpointId &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(endpointId, displayName);

  @override
  String toString() => 'HopcastNeighbor($displayName, $endpointId)';
}
