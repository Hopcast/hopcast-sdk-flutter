// This demo drives dialogs from a controller through the global navigator key
// (never a widget context captured across an await), so the async-gap lint does
// not apply here.
// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:hopcast_flutter/hopcast_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'src/friendly_name.dart';
import 'src/home_page.dart';
import 'src/incoming_dialog.dart';
import 'src/trust.dart';

/// Discovery namespace for this demo. Only devices built with the SAME serviceId
/// discover each other. On iOS it MUST match the NSBonjourServices entries in
/// ios/Runner/Info.plist (`_hopcastdemo._tcp` / `_hopcastdemo._udp`).
const String kDemoServiceId = 'hopcastdemo';

/// Client SDK key used for the one-time device enrollment (provision).
/// Replace with YOUR key, or inject it at build time:
///   flutter run --dart-define=HOPCAST_SDK_KEY=pk_live_…
const String kDemoSdkKey = String.fromEnvironment(
  'HOPCAST_SDK_KEY',
  defaultValue: 'pk_live_demo',
);

/// User identifier associated with this device at enrollment. In a real app
/// this is your logged-in user's id.
const String kDemoUserId = String.fromEnvironment(
  'HOPCAST_USER_ID',
  defaultValue: 'demo-user',
);

/// Operating mode, injectable at build time:
///   flutter run --dart-define=HOPCAST_MODE=hybrid   (offlineOnly | onlineOnly | hybrid)
/// Online / hybrid open a cloud session after provisioning (see onlineEvents).
final HopcastMode kDemoMode = HopcastMode.parse(
  const String.fromEnvironment('HOPCAST_MODE', defaultValue: 'offlineOnly'),
);

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HopcastDemoApp());
}

class HopcastDemoApp extends StatelessWidget {
  const HopcastDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hopcast Demo',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F6FE4)),
        useMaterial3: true,
      ),
      home: const _Bootstrapper(),
    );
  }
}

/// A file received from a peer.
class ReceivedFile {
  ReceivedFile({required this.path, required this.from, required this.at});
  final String path;
  final String from;
  final DateTime at;

  String get name => path.split(Platform.pathSeparator).last;
}

/// Progress of an in-flight send (sender side).
class SendProgress {
  SendProgress({required this.label});
  final String label;
  double? fraction; // 0..1 or null (indeterminate)
  bool done = false;
  String? summary;
}

/// Holds all Hopcast state for the demo and orchestrates the SDK.
///
/// This is the generic wiring a real app would replicate: build + permissions +
/// startSharing on launch, a live neighbours list, the incoming-invitation trust
/// policy, and received-file tracking.
class HopcastController extends ChangeNotifier {
  HopcastController(this._appContext);

  final BuildContext Function() _appContext;
  final _hopcast = HopcastFlutter.instance;

  String deviceName = '…';
  bool ready = false;
  bool permissionDenied = false;
  bool wifiOn = true;
  String? provisionError;

  /// Online mode status line (null in offlineOnly).
  String? cloudStatus;
  HopcastTransferHandoff? lastHandoff;

  List<HopcastNeighbor> neighbors = const [];
  final List<ReceivedFile> received = [];
  SendProgress? sending;
  double? incomingFraction; // receive progress (null = idle)

  StreamSubscription<List<HopcastNeighbor>>? _neighborsSub;
  StreamSubscription<HopcastTransferEvent>? _transfersSub;
  StreamSubscription<HopcastOnlineEvent>? _onlineSub;
  StreamSubscription<HopcastTransferHandoff>? _handoffsSub;
  bool _dialogShowing = false;

  Future<void> init() async {
    deviceName = await friendlyDeviceName();
    notifyListeners();

    // 1. Permissions (Android runtime; no-op best-effort on iOS).
    final granted = await _hopcast.requestPermissions();
    if (!granted) {
      permissionDenied = true;
      notifyListeners();
      return;
    }

    // 2. Build the SDK (idempotent). deviceId = the name shown to peers.
    await _hopcast.build(
      deviceId: deviceName,
      serviceId: kDemoServiceId,
      mode: kDemoMode,
      onlineConfig: const HopcastOnlineConfig(), // ignored in offlineOnly
    );

    // 3. One-time device enrollment (requires connectivity the first time).
    //    Until it succeeds once, the SDK is inert (startSharing/sendFiles no-op).
    if (!await _hopcast.isProvisioned()) {
      try {
        await _hopcast.provision(sdkKey: kDemoSdkKey, userId: kDemoUserId);
      } on HopcastIdentityException catch (e) {
        provisionError = e.error == HopcastIdentityError.server
            ? 'HTTP ${e.statusCode}'
            : (e.message ?? e.error.name);
        notifyListeners();
      } on PlatformException catch (e) {
        provisionError = e.message ?? e.code;
        notifyListeners();
        // Keep going: discovery streams get wired and provision can be retried
        // later by restarting the app once online.
      }
    }

    // 4. Wire the streams BEFORE sharing so we don't miss early events.
    _neighborsSub = _hopcast.neighbors.listen((list) {
      neighbors = list;
      notifyListeners();
    });
    _transfersSub = _hopcast.transferEvents.listen(_onTransfer);

    // 4b. Online / hybrid: cloud session events + orchestrated transfer handoffs.
    if (kDemoMode != HopcastMode.offlineOnly) {
      cloudStatus = 'Cloud: connecting…';
      _onlineSub = _hopcast.onlineEvents.listen((e) {
        switch (e.type) {
          case HopcastOnlineEventType.cloudReady:
            cloudStatus = 'Cloud: ready (${e.deviceUuid})';
            break;
          case HopcastOnlineEventType.cloudDisconnected:
            cloudStatus = 'Cloud: disconnected (retrying)';
            break;
          case HopcastOnlineEventType.cloudError:
            cloudStatus = 'Cloud error: ${e.reason}';
            break;
          case HopcastOnlineEventType.filesToBeDownloaded:
            cloudStatus = 'Backend wants ${e.fileIds.length} file(s)';
            break;
          case HopcastOnlineEventType.unknown:
            break;
        }
        notifyListeners();
      });
      _handoffsSub = _hopcast.transferHandoffs.listen((h) {
        lastHandoff = h;
        notifyListeners();
      });
      await _hopcast.enableOnlineMode();
    }

    // 5. Start advertising + discovery.
    await _hopcast.startSharing();

    wifiOn = await _hopcast.isWifiEnabled();
    ready = true;
    notifyListeners();
  }

  // --- Sending ---------------------------------------------------------------

  /// Generates [count] demo files (~[kb] KB each) in a temp folder, then sends
  /// them to [endpointIds]. A real app would send user-selected files instead
  /// (e.g. via a file picker) — the call is identical.
  Future<void> sendDemoFiles({
    required List<String> endpointIds,
    int count = 1,
    int kb = 256,
  }) async {
    if (endpointIds.isEmpty) return;
    final paths = await _makeDemoFiles(count, kb);
    sending = SendProgress(
        label: 'Sending $count file${count == 1 ? '' : 's'} to '
            '${endpointIds.length} peer${endpointIds.length == 1 ? '' : 's'}…');
    notifyListeners();

    final bulkId = await _hopcast.sendFiles(
      endpointIds: endpointIds,
      filePaths: paths,
      metadata: 'Demo bundle ($count file${count == 1 ? '' : 's'})',
    );
    if (bulkId == null) {
      sending!
        ..done = true
        ..summary = 'Nothing could be sent (no file / no reachable peer).';
      notifyListeners();
    }
    // Otherwise progress + summary arrive through _onTransfer (bulkStarted…bulkFinished).
  }

  Future<List<String>> _makeDemoFiles(int count, int kb) async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(
        '${tmp.path}${Platform.pathSeparator}hopcast_outbox_${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final payload = List<int>.filled(1024, 65); // 1 KB of 'A'
    final paths = <String>[];
    for (var i = 0; i < count; i++) {
      final f = File('${dir.path}${Platform.pathSeparator}demo_${i + 1}.bin');
      final sink = f.openWrite();
      for (var k = 0; k < kb; k++) {
        sink.add(payload);
      }
      await sink.close();
      paths.add(f.path);
    }
    return paths;
  }

  // --- Incoming events + trust policy ---------------------------------------

  Future<void> _onTransfer(HopcastTransferEvent e) async {
    switch (e.type) {
      case HopcastTransferType.invitation:
        await _handleInvitation(e);
        break;

      case HopcastTransferType.bulkStarted:
        sending ??= SendProgress(label: 'Sending…');
        notifyListeners();
        break;

      case HopcastTransferType.transferProgress:
      case HopcastTransferType.fileProgress:
        if (e.isReceiver) {
          incomingFraction = e.progressFraction;
        } else {
          sending?.fraction = e.progressFraction;
        }
        notifyListeners();
        break;

      case HopcastTransferType.fileCompleted:
        if (e.isReceiver && e.localPath != null && e.localPath!.isNotEmpty) {
          received.insert(
              0,
              ReceivedFile(
                path: e.localPath!,
                from: e.peerName ?? 'nearby device',
                at: DateTime.now(),
              ));
          incomingFraction = null;
          notifyListeners();
        }
        break;

      case HopcastTransferType.bulkFinished:
        if (sending != null) {
          final outcomes = e.outcomes ?? const [];
          final n = outcomes.length;
          final okN = outcomes.where((o) => o.isSuccess).length;
          sending!
            ..done = true
            ..fraction = 1.0
            ..summary = e.anyOutcomeSuccess
                ? 'Delivered to $okN/$n peer${n == 1 ? '' : 's'}.'
                : 'Delivery failed to all $n peer${n == 1 ? '' : 's'}.';
          notifyListeners();
        }
        break;

      case HopcastTransferType.transferFailed:
      case HopcastTransferType.fileFailed:
        if (e.isReceiver) {
          incomingFraction = null;
        } else {
          sending
            ?..done = true
            ..summary = 'Transfer failed (${e.reason ?? 'unknown'}).';
        }
        notifyListeners();
        break;

      case HopcastTransferType.unknown:
        break;
    }
  }

  /// The MANUAL-policy decision, mirroring a real app:
  /// blocked → reject; allowed → accept; unknown → per the accept mode
  /// ("everyone" → accept, "ask" → prompt).
  Future<void> _handleInvitation(HopcastTransferEvent e) async {
    final id = e.transferId;
    final sender = e.senderName ?? 'Unknown device';
    if (id == null) return;

    if (await Trust.instance.isBlocked(sender)) {
      await _hopcast.rejectTransfer(id);
      return;
    }
    if (await Trust.instance.isAllowed(sender)) {
      await _hopcast.acceptTransfer(id);
      return;
    }

    final mode = await Trust.instance.acceptMode();
    if (mode == AcceptMode.everyone) {
      await _hopcast.acceptTransfer(id);
      return;
    }

    // "ask" mode: prompt the user. The context is resolved fresh from the global
    // navigator key (not captured across the await), so it is safe to use here.
    final ctx = _appContext();
    if (_dialogShowing) {
      await _hopcast.rejectTransfer(id);
      return;
    }
    _dialogShowing = true;
    final decision = await showIncomingRequestDialog(
      ctx,
      senderName: sender,
      fileCount: e.fileCount,
      totalBytes: e.totalBytes,
      meta: e.meta,
    );
    _dialogShowing = false;

    switch (decision) {
      case IncomingDecision.accept:
        await _hopcast.acceptTransfer(id);
        break;
      case IncomingDecision.always:
        await Trust.instance.allow(sender);
        await _hopcast.acceptTransfer(id);
        break;
      case IncomingDecision.block:
        await Trust.instance.block(sender);
        await _hopcast.rejectTransfer(id);
        break;
      case IncomingDecision.reject:
      case null:
        await _hopcast.rejectTransfer(id);
        break;
    }
    notifyListeners();
  }

  void clearSending() {
    sending = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _neighborsSub?.cancel();
    _transfersSub?.cancel();
    _onlineSub?.cancel();
    _handoffsSub?.cancel();
    _hopcast.release();
    super.dispose();
  }
}

/// Boots the controller and shows the home page (or a permission-denied screen).
class _Bootstrapper extends StatefulWidget {
  const _Bootstrapper();

  @override
  State<_Bootstrapper> createState() => _BootstrapperState();
}

class _BootstrapperState extends State<_Bootstrapper> {
  late final HopcastController _controller =
      HopcastController(() => navigatorKey.currentContext ?? context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.init());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => HomePage(controller: _controller),
    );
  }
}
