import Flutter
import UIKit
import HopcastSDKKit

/// Flutter plugin (iOS) exposing the Hopcast bridge through one MethodChannel and two
/// EventChannels (discovered neighbours + transfer events). Mirrors EXACTLY the
/// `HopcastPlugin.kt` (Android) contract: same channel and method names.
///
///   MethodChannel  "hopcast/methods"
///   EventChannel   "hopcast/neighbors"   -> [ {endpointId, displayName} ]
///   EventChannel   "hopcast/transfers"   -> typed maps ("type": invitation, transferProgress…)
///
/// Auto-registered by the Flutter plugin loader (the pubspec declares
/// `ios: pluginClass: HopcastPlugin`) — nothing to add in the host `AppDelegate`.
public class HopcastPlugin: NSObject, FlutterPlugin {

    private static let methods = "hopcast/methods"
    private static let neighbors = "hopcast/neighbors"
    private static let transfers = "hopcast/transfers"
    private static let online = "hopcast/online"
    private static let handoffs = "hopcast/handoffs"

    private static let defaultDeviceId = "HopcastDevice"
    private static let defaultServiceId = "hopcast"

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()

        let instance = HopcastPlugin()
        let methodChannel = FlutterMethodChannel(name: methods, binaryMessenger: messenger)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let neighborsChannel = FlutterEventChannel(name: neighbors, binaryMessenger: messenger)
        neighborsChannel.setStreamHandler(NeighborsStreamHandler())

        let transfersChannel = FlutterEventChannel(name: transfers, binaryMessenger: messenger)
        transfersChannel.setStreamHandler(TransfersStreamHandler())

        let onlineChannel = FlutterEventChannel(name: online, binaryMessenger: messenger)
        onlineChannel.setStreamHandler(OnlineStreamHandler())

        let handoffsChannel = FlutterEventChannel(name: handoffs, binaryMessenger: messenger)
        handoffsChannel.setStreamHandler(HandoffsStreamHandler())
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let bridge = HopcastBridge.shared
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "build":
            let deviceId = (args?["deviceId"] as? String) ?? HopcastPlugin.defaultDeviceId
            // serviceId MUST match the NSBonjourServices entries in the host Info.plist.
            let serviceId = (args?["serviceId"] as? String) ?? HopcastPlugin.defaultServiceId
            let mode: Mode
            switch args?["mode"] as? String {
            case "onlineOnly": mode = .onlineOnly
            case "hybrid": mode = .hybrid
            default: mode = .offlineOnly
            }
            var onlineConfig: OnlineConfig?
            if let m = args?["onlineConfig"] as? [String: Any] {
                let broker = (m["brokerUrl"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                onlineConfig = OnlineConfig(
                    brokerUrl: broker ?? OnlineConfig.defaultBrokerUrl,
                    isSecondaryFcm: (m["isSecondaryFcm"] as? Bool) ?? true,
                    runAsService: (m["runAsService"] as? Bool) ?? false)
            }
            // "autoDisconnectAfterTransfer" is Android-only and deliberately ignored: the
            // MultipeerConnectivity session already stays open until stopSharing/release.
            bridge.build(deviceId: deviceId, serviceId: serviceId, mode: mode, onlineConfig: onlineConfig)
            result(true)

        case "provision":
            guard let sdkKey = args?["sdkKey"] as? String, !sdkKey.isEmpty,
                  let userId = args?["userId"] as? String, !userId.isEmpty else {
                result(FlutterError(code: "BAD_ARGS", message: "provision requires sdkKey and userId", details: nil))
                return
            }
            guard bridge.isBuilt() else {
                result(FlutterError(code: "NOT_BUILT", message: "Call build() before provision()", details: nil))
                return
            }
            bridge.provision(sdkKey: sdkKey, userId: userId) { r in
                DispatchQueue.main.async {
                    switch r {
                    case .success:
                        result(true)
                    case .failure(let error):
                        result(FlutterError(code: "PROVISION_FAILED", message: error.localizedDescription,
                                            details: HopcastPlugin.identityErrorDetails(error)))
                    }
                }
            }

        case "isProvisioned":
            result(bridge.isProvisioned())

        case "clearIdentity":
            bridge.clearIdentity()
            result(nil)

        case "deviceUuid":
            result(bridge.deviceUuid())

        case "getMode":
            result(bridge.modeName())

        case "enableOnlineMode":
            bridge.enableOnlineMode()
            result(nil)

        case "disableOnlineMode":
            bridge.disableOnlineMode()
            result(nil)

        case "reportDownloadedFile":
            bridge.reportDownloadedFile(
                infraType: (args?["infraType"] as? String) ?? "",
                contentIds: (args?["contentIds"] as? [String]) ?? [])
            result(nil)

        case "reportRemovedFile":
            bridge.reportRemovedFile(contentIds: (args?["contentIds"] as? [String]) ?? [])
            result(nil)

        case "declareNeed":
            guard let contentId = args?["contentId"] as? String, !contentId.isEmpty,
                  let ttl = args?["ttlSeconds"] as? Int else {
                result(FlutterError(code: "BAD_ARGS", message: "declareNeed requires contentId and ttlSeconds", details: nil))
                return
            }
            result(bridge.declareNeed(contentId: contentId, ttlSeconds: ttl))

        case "cancelNeed":
            if let id = args?["needId"] as? String { bridge.cancelNeed(needId: id) }
            result(nil)

        case "handleFcmMessage":
            let raw = (args?["data"] as? [String: Any]) ?? [:]
            bridge.handleFcmMessage(raw.mapValues { "\($0)" })
            result(nil)

        case "handleFcmToken":
            if let token = args?["token"] as? String { bridge.handleFcmToken(token) }
            result(nil)

        case "getRequiredPermissions":
            result(bridge.getRequiredPermissions())

        case "requestPermissions":
            // iOS has no API to explicitly request/check the "Local Network" permission:
            // the system prompt appears on the first Bonjour discovery (startSharing).
            // Best-effort: true (Dart then proceeds to build + startSharing).
            result(true)

        case "startSharing":
            bridge.startSharing()
            result(nil)

        case "stopSharing":
            bridge.stopSharing()
            result(nil)

        case "isWifiEnabled":
            result(bridge.isWifiEnabled())

        case "sendFiles":
            let endpointIds = (args?["endpointIds"] as? [String]) ?? []
            let filePaths = (args?["filePaths"] as? [String]) ?? []
            let metadata = (args?["metadata"] as? String).flatMap { $0.data(using: .utf8) }
            result(bridge.sendFiles(endpointIds: endpointIds, filePaths: filePaths, metadata: metadata))

        case "acceptTransfer":
            if let id = args?["transferId"] as? String { bridge.acceptTransfer(id) }
            result(nil)

        case "rejectTransfer":
            if let id = args?["transferId"] as? String { bridge.rejectTransfer(id) }
            result(nil)

        case "release":
            bridge.release()
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

extension HopcastPlugin {
    /// Typed cause for the Dart HopcastIdentityException (`details.kind` / `statusCode`).
    static func identityErrorDetails(_ error: Error) -> [String: Any] {
        if let e = error as? HopcastIdentityError {
            switch e {
            case .notProvisioned: return ["kind": "notProvisioned"]
            case .invalidResponse: return ["kind": "invalidResponse"]
            case .server(let statusCode): return ["kind": "server", "statusCode": statusCode]
            @unknown default: return ["kind": "unknown"]
            }
        }
        if (error as NSError).domain == "fr.hopcast.flutter" { return ["kind": "notBuilt"] }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return ["kind": "transport"] }
        return ["kind": "unknown"]
    }
}

/// Relays the "online" stream to the bridge.
private class OnlineStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        HopcastBridge.shared.setOnlineSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        HopcastBridge.shared.setOnlineSink(nil)
        return nil
    }
}

/// Relays the "handoffs" stream to the bridge.
private class HandoffsStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        HopcastBridge.shared.setHandoffsSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        HopcastBridge.shared.setHandoffsSink(nil)
        return nil
    }
}

/// Relays the "neighbours" stream to the bridge.
private class NeighborsStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        HopcastBridge.shared.setNeighborsSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        HopcastBridge.shared.setNeighborsSink(nil)
        return nil
    }
}

/// Relays the "transfers" stream to the bridge.
private class TransfersStreamHandler: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        HopcastBridge.shared.setTransfersSink(events)
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        HopcastBridge.shared.setTransfersSink(nil)
        return nil
    }
}
