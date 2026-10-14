import 'package:flutter/services.dart';

/// Cause of a [HopcastIdentityException] — mirror of the native
/// `HopcastIdentityError` (iOS) / `HopcastIdentityException` (Android), plus
/// the transport / lifecycle cases the bridge can report.
enum HopcastIdentityError {
  /// The SDK has no persisted identity — call [HopcastFlutter.provision].
  notProvisioned,

  /// The backend answered 2xx with an empty or undecodable payload.
  invalidResponse,

  /// The backend answered with a non-2xx HTTP status
  /// ([HopcastIdentityException.statusCode]).
  server,

  /// Transport-level failure (no route, timeout, TLS…). Retry when online.
  transport,

  /// [HopcastFlutter.provision] was called before [HopcastFlutter.build].
  notBuilt,

  /// Any other failure.
  unknown;

  static HopcastIdentityError parse(String? raw) {
    for (final v in HopcastIdentityError.values) {
      if (v.name == raw) return v;
    }
    return HopcastIdentityError.unknown;
  }
}

/// Thrown by [HopcastFlutter.provision] when enrollment fails.
///
/// Extends [PlatformException] with the historical code `PROVISION_FAILED`
/// (or `NOT_BUILT`), so existing `on PlatformException catch (e)` handlers
/// keep working.
class HopcastIdentityException extends PlatformException {
  HopcastIdentityException({
    required this.error,
    this.statusCode,
    super.message,
    super.code = 'PROVISION_FAILED',
  });

  /// Typed cause.
  final HopcastIdentityError error;

  /// HTTP status when [error] is [HopcastIdentityError.server].
  final int? statusCode;

  /// Builds the typed exception from the bridge's [PlatformException]
  /// (`details: {"kind": …, "statusCode": …}`).
  factory HopcastIdentityException.fromPlatform(PlatformException e) {
    final details = e.details;
    String? kind;
    int? status;
    if (details is Map) {
      kind = details['kind']?.toString();
      final s = details['statusCode'];
      status = s is num ? s.toInt() : null;
    }
    final error = e.code == 'NOT_BUILT'
        ? HopcastIdentityError.notBuilt
        : HopcastIdentityError.parse(kind);
    return HopcastIdentityException(
      error: error,
      statusCode: status,
      message: e.message,
      code: e.code,
    );
  }

  @override
  String toString() =>
      'HopcastIdentityException(${error.name}${statusCode != null ? ', HTTP $statusCode' : ''}, $message)';
}
