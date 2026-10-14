import Foundation
import Flutter
// The SDK module is named "HopcastSDKKit"; its public type is `enum HopcastSDK`.
import HopcastSDKKit

/// Singleton wrapping the Hopcast SDK (XCFramework binary) and relaying its
/// events (neighbours + transfers) to the Flutter EventChannels. Built once per process.
/// Mirrors EXACTLY the `HopcastBridge.kt` (Android) contract: same method names, same
/// event maps.
///
/// On iOS, `sendFiles` connects to the recipients first (automatic, bounded wait) and
/// the bridge emits the same `bulkStarted … bulkFinished` bracket as Android.
final class HopcastBridge: NSObject {

    static let shared = HopcastBridge()
    private override init() {}

    private static let transferTag = "hopcast_global"
    private static let defaultDeviceId = "HopcastDevice"
    private static let defaultServiceId = "hopcast"

    // Serial queue guarding all mutable state below.
    private let q = DispatchQueue(label: "fr.hopcast.flutter.bridge")

    private var built = false
    private var myDeviceId = defaultDeviceId

    private var neighborsSink: FlutterEventSink?
    private var transfersSink: FlutterEventSink?
    private var onlineSink: FlutterEventSink?
    private var handoffsSink: FlutterEventSink?

    private var builtMode: Mode = .offlineOnly
    // Online mode requested by Dart. Replayed after a successful provision() (an
    // enableOnlineMode() issued while unprovisioned is a native no-op).
    private var onlineRequested = false

    // Last filtered snapshot, replayed to every new subscriber (SDK only emits on change).
    private var lastNeighbors: [[String: Any]] = []

    // endpointIds currently connected (fed by the ConnectionListener).
    private var establishedEndpoints = Set<String>()

    // In-flight sends, keyed by real transferId: tracked to emit bulkFinished.
    private var outgoing: [String: OutgoingSend] = [:]

    // Sender-side tracking to build the per-recipient outcome.
    private struct OutgoingSend {
        var expectedTotal: Int                          // total expected recipients
        var outcomes: [String: (status: String, reason: String?)] // by displayName
        var watchdog: DispatchWorkItem?
    }

    // MARK: - Lifecycle

    func isBuilt() -> Bool { q.sync { built } }

    /// Directory where received files land. Aligned with the Dart receiver on iOS
    /// (`getApplicationSupportDirectory()/hopcast_inbox`) — the same path reported in
    /// `fileCompleted.localPath`.
    static func inboxDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let inbox = base.appendingPathComponent("hopcast_inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Builds the SDK once. [serviceId] scopes discovery and MUST match the host
    /// Info.plist NSBonjourServices entries (`_<serviceId>._tcp` / `_<serviceId>._udp`) —
    /// otherwise iOS silently blocks the Bonjour service (no discovery, no prompt).
    func build(deviceId: String, serviceId: String, mode: Mode = .offlineOnly, onlineConfig: OnlineConfig? = nil) {
        q.sync {
            if built { return }
            let name = deviceId.isEmpty ? HopcastBridge.defaultDeviceId : deviceId
            let service = serviceId.isEmpty ? HopcastBridge.defaultServiceId : serviceId
            myDeviceId = name

            let builder = HopcastSDK.builder(deviceId: name, cacheDirectory: HopcastBridge.inboxDirectory())
                .setMode(mode)
            if mode != .offlineOnly {
                builder.setOnlineConfig(onlineConfig ?? OnlineConfig())
            }
            _ = builder
                .setServiceId(service)
                // Silent connection (like AUTO_ACCEPT on the connection side on Android).
                .setAutoAcceptConnections(true)
                // MANUAL: every incoming transfer surfaces via onTransferInvitation; Flutter
                // decides accept/reject. iOS equivalent of IncomingTransferPolicy.MANUAL.
                .setAutoAcceptTransfers(false)
                .build()

            HopcastSDK.setDeviceDiscoveryListener(self)
            HopcastSDK.setConnectionListener(self, tag: HopcastBridge.transferTag)
            HopcastSDK.setTransferListener(self, tag: HopcastBridge.transferTag)
            // No-op natively in offlineOnly (no online subsystem).
            HopcastSDK.setOnlineEventListener(self, tag: HopcastBridge.transferTag)
            HopcastSDK.setTransferHandoffListener(self, tag: HopcastBridge.transferTag)
            builtMode = mode
            built = true
            NSLog("HopcastBridge: SDK built deviceId='\(name)' serviceId='\(service)' mode=\(mode)")
        }
    }

    func getRequiredPermissions() -> [String] { HopcastSDK.requiredPermissions }

    // Sharing intent, as requested by Dart. Replayed after a successful provision():
    // a startSharing() issued while the SDK was unprovisioned was a native no-op (gating).
    private var sharingRequested = false

    /// One-time device enrollment (see `HopcastSDK.provision`). Must run after `build`.
    /// The reporting/backend host is owned by the SDK (a fixed default) — the host app
    /// does not choose it, so enrollment, token refreshes and exchange reports always
    /// target the same server across launches, provisioned or not.
    func provision(
        sdkKey: String,
        userId: String,
        completion: @escaping (Swift.Result<Void, Error>) -> Void
    ) {
        guard isBuilt() else {
            completion(.failure(NSError(
                domain: "fr.hopcast.flutter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SDK not built — call build() first"])))
            return
        }
        HopcastSDK.provision(sdkKey: sdkKey, userId: userId) { [weak self] result in
            if case .success = result, let self = self {
                let (sharing, online) = self.q.sync { (self.sharingRequested, self.onlineRequested) }
                if sharing { self.startSharing() }
                if online { HopcastSDK.enableOnlineMode() }
            }
            completion(result)
        }
    }

    /// Backend-assigned device id ("unknown" until provisioned).
    func deviceUuid() -> String { HopcastSDK.deviceUuid }

    func modeName() -> String {
        switch q.sync(execute: { built ? builtMode : .offlineOnly }) {
        case .offlineOnly: return "offlineOnly"
        case .onlineOnly: return "onlineOnly"
        case .hybrid: return "hybrid"
        @unknown default: return "offlineOnly"
        }
    }

    // MARK: - Online mode

    func enableOnlineMode() {
        guard isBuilt() else { return }
        q.sync { onlineRequested = true }
        HopcastSDK.enableOnlineMode()
    }

    func disableOnlineMode() {
        q.sync { onlineRequested = false }
        guard isBuilt() else { return }
        HopcastSDK.disableOnlineMode()
    }

    func reportDownloadedFile(infraType: String, contentIds: [String]) {
        guard isBuilt() else { return }
        guard let infra = InfraType(rawValue: infraType) else {
            NSLog("HopcastBridge: reportDownloadedFile — unknown infraType '\(infraType)'")
            return
        }
        HopcastSDK.reportDownloadedFile(infraType: infra, contentIds: contentIds)
    }

    func reportRemovedFile(contentIds: [String]) {
        guard isBuilt() else { return }
        HopcastSDK.reportRemovedFile(contentIds: contentIds)
    }

    func declareNeed(contentId: String, ttlSeconds: Int) -> String? {
        guard isBuilt() else { return nil }
        return HopcastSDK.declareNeed(contentId: contentId, ttlSeconds: ttlSeconds)
    }

    func cancelNeed(needId: String) {
        guard isBuilt() else { return }
        HopcastSDK.cancelNeed(needId: needId)
    }

    func handleFcmMessage(_ data: [String: String]) {
        guard isBuilt() else { return }
        HopcastSDK.handleFcmMessage(data)
    }

    func handleFcmToken(_ token: String) {
        guard isBuilt() else { return }
        HopcastSDK.handleFcmToken(token)
    }

    /// True once a device identity is persisted in the Keychain.
    func isProvisioned() -> Bool { HopcastSDK.isProvisioned }

    /// Drops the persisted identity (Keychain) — the SDK is inert again until the next
    /// successful provision(). Needed on iOS before re-enrolling under a different
    /// sdkKey/userId, since provision() short-circuits while an identity exists.
    func clearIdentity() { HopcastSDK.clearIdentity() }

    func startSharing() {
        guard isBuilt() else { return }
        q.sync { sharingRequested = true }
        // Do NOT stopSharing() first: re-issuing startSharing() alone is safe (idempotent
        // natively) and refreshes a stalled discovery without tearing anything down.
        HopcastSDK.startSharing()
        NSLog("HopcastBridge: startSharing")
    }

    func stopSharing() {
        guard isBuilt() else { return }
        q.sync { sharingRequested = false }
        HopcastSDK.stopSharing()
    }

    /// iOS exposes no reliable public API for the Wi-Fi state. Best-effort: true
    /// (the Dart layer already tolerates this). A transfer falls back to Bluetooth on
    /// its own when Wi-Fi is absent.
    func isWifiEnabled() -> Bool { true }

    func acceptTransfer(_ transferId: String) {
        guard isBuilt() else { return }
        HopcastSDK.acceptTransfer(transferId: transferId)
    }

    func rejectTransfer(_ transferId: String) {
        guard isBuilt() else { return }
        HopcastSDK.rejectTransfer(transferId: transferId)
    }

    func release() {
        q.sync {
            if built {
                HopcastSDK.removeOnlineEventListener(tag: HopcastBridge.transferTag)
                HopcastSDK.removeTransferHandoffListener(tag: HopcastBridge.transferTag)
                HopcastSDK.removeTransferListener(tag: HopcastBridge.transferTag)
                HopcastSDK.removeConnectionListener(tag: HopcastBridge.transferTag)
                HopcastSDK.setDeviceDiscoveryListener(nil)
                HopcastSDK.release()
            }
            built = false
            sharingRequested = false
            onlineRequested = false
            builtMode = .offlineOnly
            establishedEndpoints.removeAll()
            outgoing.removeAll()
        }
    }

    // MARK: - Send (connect to recipients → sendFiles → per-peer outcomes)

    /// Returns a synthetic bulkId immediately (the real send is asynchronous: connections
    /// must be established first). Returns nil ONLY on invalid inputs (no readable file /
    /// no recipient) — same semantics as Android.
    func sendFiles(endpointIds: [String], filePaths: [String], metadata: Data?) -> String? {
        guard isBuilt() else { return nil }

        let fm = FileManager.default
        let urls: [URL] = filePaths.compactMap { path in
            guard fm.isReadableFile(atPath: path) else { return nil }
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return size > 0 ? URL(fileURLWithPath: path) : nil
        }
        guard !endpointIds.isEmpty, !urls.isEmpty else { return nil }

        let bulkId = UUID().uuidString

        // Target names (for the outcome) resolved from the last neighbour snapshot.
        let nameByEndpoint: [String: String] = q.sync {
            var m = [String: String]()
            for n in lastNeighbors {
                if let e = n["endpointId"] as? String, let d = n["displayName"] as? String { m[e] = d }
            }
            return m
        }
        let targetNames = Set(endpointIds.map { nameByEndpoint[$0] ?? $0 })

        // Emit bulkStarted right away (same bracket as Android).
        emitTransfer([
            "type": "bulkStarted",
            "isReceiver": false,
            "transferId": bulkId,
            "totalPeers": targetNames.count,
            "totalFiles": urls.count,
        ])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            HopcastSDK.inviteNeighbors(endpointIds: endpointIds)

            // Wait for establishment (≤ 25 s).
            var connectedIds: [String] = []
            for _ in 0..<125 {
                let established = self.q.sync { self.establishedEndpoints }
                connectedIds = endpointIds.filter { established.contains($0) }
                let connectedNames = Set(connectedIds.map { nameByEndpoint[$0] ?? $0 })
                if connectedNames.count >= targetNames.count { break }
                Thread.sleep(forTimeInterval: 0.2)
            }

            // One endpoint per device (avoid double-send if a device has both a stale and a
            // fresh endpoint connected).
            var seenNames = Set<String>()
            let targets = connectedIds.filter { id in
                let nm = nameByEndpoint[id] ?? id
                return seenNames.insert(nm).inserted
            }
            let connectedNames = Set(targets.map { nameByEndpoint[$0] ?? $0 })
            let unconnected = targetNames.subtracting(connectedNames)

            if targets.isEmpty {
                // Nobody answered: global failure + all-failed outcome.
                self.emitTransfer([
                    "type": "transferFailed", "isReceiver": false, "transferId": bulkId,
                    "reason": "PEERDISCONNECTED",
                    "peerName": targetNames.first ?? "",
                ])
                let outcomes = targetNames.map { ["peerName": $0, "status": "FAILED", "reason": "PEERDISCONNECTED"] }
                self.emitTransfer([
                    "type": "bulkFinished", "isReceiver": false, "transferId": bulkId,
                    "outcomes": outcomes,
                ])
                return
            }

            guard let realId = HopcastSDK.sendFiles(endpointIds: targets, files: urls, metadata: metadata) else {
                let outcomes = targetNames.map { ["peerName": $0, "status": "FAILED", "reason": "SOURCEUNREADABLE"] }
                self.emitTransfer([
                    "type": "bulkFinished", "isReceiver": false, "transferId": bulkId,
                    "outcomes": outcomes,
                ])
                return
            }

            // Track per-peer outcomes to emit bulkFinished once every peer reaches a
            // terminal state. Unconnected peers are pre-marked as failed.
            self.q.sync {
                var seeded = [String: (status: String, reason: String?)]()
                for nm in unconnected { seeded[nm] = ("FAILED", "PEERDISCONNECTED") }
                // The watchdog is scheduled ON q: its body already runs on the queue, so it
                // calls the "Locked" variant directly (no re-entrant q.sync).
                let watchdog = DispatchWorkItem { [weak self] in self?.finishOutgoingLocked(realId) }
                self.outgoing[realId] = OutgoingSend(
                    expectedTotal: targetNames.count, outcomes: seeded, watchdog: watchdog)
                // Safety net: force the outcome after 90 s if terminal states are missing.
                self.q.asyncAfter(deadline: .now() + 90, execute: watchdog)
                self.maybeFinishOutgoingLocked(realId)
            }
        }

        return bulkId
    }

    // Marks a peer as terminal (SUCCESS/FAILED) sender-side and closes if complete.
    private func recordOutcome(transferId: String, peerName: String, status: String, reason: String?) {
        q.sync {
            guard var send = outgoing[transferId] else { return }
            if send.outcomes[peerName] == nil {   // first terminal state wins
                send.outcomes[peerName] = (status, reason)
                outgoing[transferId] = send
            }
            maybeFinishOutgoingLocked(transferId)
        }
    }

    // Call INSIDE q. Emits bulkFinished once every recipient has an outcome.
    private func maybeFinishOutgoingLocked(_ transferId: String) {
        guard let send = outgoing[transferId] else { return }
        if send.outcomes.count >= send.expectedTotal {
            finishOutgoingLocked(transferId)
        }
    }

    // Call INSIDE q.
    private func finishOutgoingLocked(_ transferId: String) {
        guard let send = outgoing.removeValue(forKey: transferId) else { return }
        send.watchdog?.cancel()
        let outcomes = send.outcomes.map { (name, v) -> [String: Any?] in
            ["peerName": name, "status": v.status, "reason": v.reason]
        }
        emitTransfer([
            "type": "bulkFinished", "isReceiver": false, "transferId": transferId,
            "outcomes": outcomes,
        ])
    }

    // MARK: - Sinks (called by HopcastPlugin)
    //
    // The sinks are ONLY touched on the main thread (Flutter StreamHandlers run there, and
    // FlutterEventSink must be invoked there). Shared state (lastNeighbors, established,
    // outgoing) stays guarded by `q`. No q.sync is nested inside an emitter → no re-entrance
    // on the serial queue.

    func setNeighborsSink(_ sink: FlutterEventSink?) {
        let snapshot = q.sync { lastNeighbors }
        DispatchQueue.main.async {
            self.neighborsSink = sink
            if sink != nil, !snapshot.isEmpty { sink?(snapshot) }  // replay last snapshot
        }
    }

    func setTransfersSink(_ sink: FlutterEventSink?) {
        DispatchQueue.main.async { self.transfersSink = sink }
    }

    func setOnlineSink(_ sink: FlutterEventSink?) {
        DispatchQueue.main.async { self.onlineSink = sink }
    }

    func setHandoffsSink(_ sink: FlutterEventSink?) {
        DispatchQueue.main.async { self.handoffsSink = sink }
    }

    fileprivate func emitOnline(_ map: [String: Any?]) {
        let cleaned = map.compactMapValues { $0 }
        DispatchQueue.main.async { self.onlineSink?(cleaned) }
    }

    fileprivate func emitHandoff(_ map: [String: Any?]) {
        let cleaned = map.compactMapValues { $0 }
        DispatchQueue.main.async { self.handoffsSink?(cleaned) }
    }

    private func emitTransfer(_ map: [String: Any?]) {
        let cleaned = map.compactMapValues { $0 }
        DispatchQueue.main.async { self.transfersSink?(cleaned) }
    }

    private func reasonName(_ r: TransferErrorReason) -> String {
        // Mirror of Kotlin `enum.name` (uppercase) so the Dart layer can detect "REJECT".
        String(describing: r).uppercased()
    }
}

// MARK: - DeviceDiscoveryListener

extension HopcastBridge: DeviceDiscoveryListener {
    func onNeighborsChanged(_ neighbors: [Neighbor]) {
        // Exclude self (by displayName) and de-duplicate by endpointId — identical to Android.
        let me = q.sync { myDeviceId }
        var seen = Set<String>()
        let payload: [[String: Any]] = neighbors.compactMap { n in
            guard n.displayName != me else { return nil }
            guard seen.insert(n.endpointId).inserted else { return nil }
            return ["endpointId": n.endpointId, "displayName": n.displayName]
        }
        q.sync { lastNeighbors = payload }
        DispatchQueue.main.async { self.neighborsSink?(payload) }
    }
}

// MARK: - ConnectionListener (tracks established connections for sending)

extension HopcastBridge: ConnectionListener {
    func onIncomingConnectionRequest(neighbor: Neighbor) {
        // setAutoAcceptConnections(true): nothing to do (accepted by the SDK).
    }

    func onConnectionStateChanged(state: ConnectionState, neighbor: Neighbor) {
        q.sync {
            switch state {
            case .established: establishedEndpoints.insert(neighbor.endpointId)
            case .disconnected, .rejected: establishedEndpoints.remove(neighbor.endpointId)
            default: break
            }
        }
    }
}

// MARK: - TransferListener

extension HopcastBridge: TransferListener {
    func onTransferInvitation(_ invitation: TransferInvitation) {
        // MANUAL policy: surface the invitation to Flutter, which decides accept/reject.
        let meta = invitation.customMetadata.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        emitTransfer([
            "type": "invitation",
            "isReceiver": true,
            "transferId": invitation.transferId,
            "senderName": invitation.sender.displayName,
            "fileCount": invitation.files.count,
            "totalBytes": invitation.totalBytes,
            "meta": meta,
        ])
    }

    func onTransferStateChanged(transferId: String, isReceiver: Bool, state: TransferState, peer: Neighbor) {
        guard !isReceiver else { return }
        // Sender side: feed the per-peer outcome for bulkFinished.
        switch state {
        case .finished:
            recordOutcome(transferId: transferId, peerName: peer.displayName, status: "SUCCESS", reason: nil)
        case .failed, .cancelled:
            recordOutcome(transferId: transferId, peerName: peer.displayName, status: "FAILED", reason: "PAYLOADFAILURE")
        default:
            break
        }
    }

    func onTransferEvent(_ event: TransferEvent) {
        emitTransfer(toMap(event))

        // Also feed the outcome on failures (precise reason) sender-side.
        if case let .transferFailed(transferId, isReceiver, reason, peer) = event, !isReceiver {
            recordOutcome(transferId: transferId, peerName: peer.displayName,
                          status: "FAILED", reason: reasonName(reason))
        }
    }

    // EXACT mirror of HopcastBridge.kt#toMap (same keys, same types).
    private func toMap(_ event: TransferEvent) -> [String: Any?] {
        switch event {
        case let .transferProgress(transferId, isReceiver, bytes, total, peer):
            return [
                "type": "transferProgress", "transferId": transferId, "isReceiver": isReceiver,
                "bytesTransferred": bytes, "totalBytes": total, "peerName": peer.displayName,
            ]
        case let .fileProgress(transferId, isReceiver, file, bytes, total, peer):
            return [
                "type": "fileProgress", "transferId": transferId, "isReceiver": isReceiver,
                "fileName": file.name, "bytesTransferred": bytes, "totalBytes": total,
                "peerName": peer.displayName,
            ]
        case let .fileCompleted(transferId, isReceiver, file, localPath, fileIndex, fileTotal, peer):
            return [
                "type": "fileCompleted", "transferId": transferId, "isReceiver": isReceiver,
                "fileName": file.name, "localPath": localPath,
                "fileIndex": fileIndex, "fileTotal": fileTotal, "peerName": peer.displayName,
            ]
        case let .fileFailed(transferId, isReceiver, file, reason, peer):
            return [
                "type": "fileFailed", "transferId": transferId, "isReceiver": isReceiver,
                "fileName": file.name, "reason": reasonName(reason), "peerName": peer.displayName,
            ]
        case let .transferFailed(transferId, isReceiver, reason, peer):
            return [
                "type": "transferFailed", "transferId": transferId, "isReceiver": isReceiver,
                "reason": reasonName(reason), "peerName": peer.displayName,
            ]
        @unknown default:
            return ["type": "unknown", "transferId": event.transferId, "isReceiver": event.isReceiver]
        }
    }
}

// MARK: - OnlineEventListener

extension HopcastBridge: OnlineEventListener {
    func onFilesToBeDownloaded(fileIds: [String]) {
        emitOnline(["type": "filesToBeDownloaded", "fileIds": fileIds])
    }

    func onCloudReady(deviceUuid: String) {
        emitOnline(["type": "cloudReady", "deviceUuid": deviceUuid])
    }

    func onCloudDisconnected() {
        emitOnline(["type": "cloudDisconnected"])
    }

    func onCloudError(reason: String) {
        emitOnline(["type": "cloudError", "reason": reason])
    }
}

// MARK: - TransferHandoffListener (orchestrated transfers only)

extension HopcastBridge: TransferHandoffListener {
    func onTransferHandoff(_ handoff: TransferHandoff) {
        // Same map as HopcastBridge.kt#handoffToMap.
        let files: [[String: Any]]? = handoff.files?.map {
            ["fileId": $0.fileId, "bytes": $0.bytes, "direction": $0.direction.rawValue]
        }
        emitHandoff([
            "instructionId": handoff.instructionId,
            "status": handoff.status.rawValue,
            "reason": handoff.reason,
            "bytesTotal": handoff.bytesTotal,
            "files": files,
        ])
    }
}
