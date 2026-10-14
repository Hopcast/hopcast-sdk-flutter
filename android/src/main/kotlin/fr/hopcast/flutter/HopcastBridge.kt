package fr.hopcast.flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import fr.hopcast.sdk.HopcastSDK
import fr.hopcast.sdk.enums.IncomingTransferPolicy
import fr.hopcast.sdk.enums.InfraType
import fr.hopcast.sdk.enums.Mode
import fr.hopcast.sdk.enums.TransferEvent
import fr.hopcast.sdk.listeners.DeviceDiscoveryListener
import fr.hopcast.sdk.listeners.OnlineEventListener
import fr.hopcast.sdk.listeners.TransferHandoffListener
import fr.hopcast.sdk.listeners.TransferListener
import fr.hopcast.sdk.model.Neighbor
import fr.hopcast.sdk.model.OnlineConfig
import fr.hopcast.sdk.model.TransferHandoff
import io.flutter.plugin.common.EventChannel
import java.io.File

/**
 * Singleton that wraps the Hopcast SDK (binary AAR) and relays its events
 * (neighbours + transfers) to the Flutter EventChannels. Built once per process.
 *
 * Acceptance policy is MANUAL: every incoming transfer surfaces as an `invitation`
 * event and Flutter decides via [acceptTransfer] / [rejectTransfer].
 */
object HopcastBridge {

    private const val TAG = "HopcastBridge"
    private const val TRANSFER_TAG = "hopcast_global"
    private const val DEFAULT_DEVICE_ID = "HopcastDevice"

    @Volatile private var built = false

    private val main = Handler(Looper.getMainLooper())

    private var neighborsSink: EventChannel.EventSink? = null
    private var transfersSink: EventChannel.EventSink? = null
    private var onlineSink: EventChannel.EventSink? = null
    private var handoffsSink: EventChannel.EventSink? = null

    @Volatile private var builtMode: Mode = Mode.OFFLINE_ONLY
    // Online mode requested by Dart: keeps the radios on across background transitions.
    @Volatile private var onlineEnabled = false

    @Volatile private var myDeviceId: String = ""
    // Last filtered snapshot, replayed to every new subscriber (the SDK only emits on change).
    @Volatile private var lastNeighbors: List<Map<String, String>> = emptyList()

    private val discoveryListener = object : DeviceDiscoveryListener {
        override fun onNeighborsChanged(neighbors: List<Neighbor>) {
            Log.i(TAG, "onNeighborsChanged: count=${neighbors.size}")
            // Exclude self and de-duplicate by endpointId.
            val payload = neighbors
                .filter { it.displayName != myDeviceId }
                .distinctBy { it.endpointId }
                .map { mapOf("endpointId" to it.endpointId, "displayName" to it.displayName) }
            lastNeighbors = payload
            main.post { neighborsSink?.success(payload) }
        }
    }

    private val transferListener = object : TransferListener {
        override fun onTransferInvitation(invitation: fr.hopcast.sdk.model.TransferInvitation) {
            // MANUAL policy: surface the invitation to Flutter, which decides accept/reject.
            Log.i(TAG, "onTransferInvitation from='${invitation.sender.displayName}' id=${invitation.transferId} files=${invitation.files.size}")
            val meta = invitation.customMetadata?.let { String(it, Charsets.UTF_8) } ?: ""
            val map = mapOf<String, Any?>(
                "type" to "invitation",
                "isReceiver" to true,
                "transferId" to invitation.transferId,
                "senderName" to invitation.sender.displayName,
                "fileCount" to invitation.files.size,
                "totalBytes" to invitation.totalBytes,
                "meta" to meta,
            )
            emitTransfer(map)
        }

        override fun onTransferStateChanged(
            transferId: String,
            isReceiver: Boolean,
            state: fr.hopcast.sdk.enums.TransferState,
            peer: Neighbor,
        ) {
            // The fine-grained TransferEvents below carry everything Flutter needs.
        }

        override fun onTransferEvent(event: TransferEvent) {
            emitTransfer(toMap(event))
        }
    }

    private val onlineListener = object : OnlineEventListener {
        override fun onFilesToBeDownloaded(fileIds: List<String>) =
            emitOnline(mapOf("type" to "filesToBeDownloaded", "fileIds" to fileIds))

        override fun onCloudReady(deviceUuid: String) =
            emitOnline(mapOf("type" to "cloudReady", "deviceUuid" to deviceUuid))

        override fun onCloudDisconnected() = emitOnline(mapOf("type" to "cloudDisconnected"))

        override fun onCloudError(reason: String) =
            emitOnline(mapOf("type" to "cloudError", "reason" to reason))
    }

    // Tagged listener: orchestrated transfers only (instructionId != null), like iOS.
    private val handoffListener = TransferHandoffListener { handoff ->
        val instructionId = handoff.instructionId ?: return@TransferHandoffListener
        emitHandoff(handoffToMap(handoff, instructionId))
    }

    /**
     * Builds the SDK once. [serviceId] scopes discovery: only devices sharing the same
     * value see each other. `null`/blank keeps the SDK default (the host package name).
     */
    fun build(
        deviceId: String,
        serviceId: String?,
        mode: Mode,
        onlineConfig: OnlineConfig?,
        context: Context,
        lifecycleOwner: LifecycleOwner?,
        cacheDir: File,
    ) {
        if (built) return
        synchronized(this) {
            if (built) return
            cacheDir.mkdirs()
            val name = deviceId.ifBlank { DEFAULT_DEVICE_ID }
            myDeviceId = name
            HopcastSDK.Builder(
                name,
                context.applicationContext,
                // null = the bridge drives startSharing()/stopSharing() itself from the
                // process lifecycle (see installForegroundAdvertising) so discovery runs
                // continuously while the app is foreground.
                null,
                cacheDir,
            )
                .apply {
                    // Discovery namespace, configurable per app. Blank => SDK default (package name).
                    if (!serviceId.isNullOrBlank()) setServiceId(serviceId)
                }
                .setAutoAcceptConnections(true)
                // MANUAL: every incoming transfer surfaces via onTransferInvitation; Flutter
                // decides acceptTransfer / rejectTransfer (allowed / blocked / prompt policy).
                .setIncomingTransferPolicy(IncomingTransferPolicy.MANUAL)
                .setTransferWatchdog(30_000L)
                // Release the connection as soon as a transfer finishes so the next
                // transfer (possibly to a different device) keeps full Wi-Fi speed. The
                // peer stays discoverable and is transparently re-invited on the next send.
                .setAutoDisconnectAfterTransfer(true)
                .setMode(mode)
                .apply {
                    if (mode != Mode.OFFLINE_ONLY) setOnlineConfig(onlineConfig ?: OnlineConfig())
                }
                .build()

            Log.i(TAG, "SDK built deviceId='$name' serviceId='${serviceId ?: "<default>"}' mode=$mode")
            builtMode = mode
            HopcastSDK.setDeviceDiscoveryListener(discoveryListener)
            HopcastSDK.setTransferListener(transferListener, TRANSFER_TAG)
            // No-op natively in OFFLINE_ONLY (no online subsystem).
            HopcastSDK.setOnlineEventListener(onlineListener, TRANSFER_TAG)
            HopcastSDK.setTransferHandoffListener(handoffListener, TRANSFER_TAG)
            built = true
            installForegroundAdvertising()
        }
    }

    private var lifecycleObserver: DefaultLifecycleObserver? = null

    /**
     * Continuous advertising + discovery while the app is foreground. We observe the
     * process lifecycle: on every foreground transition we (re)start sharing, and stop it
     * in the background to release the radios (Bluetooth / Wi-Fi). DefaultLifecycleObserver
     * fires onStart immediately if the process is already foreground at registration time
     * (the normal case, build() being called from a visible activity). Idempotent: called
     * once from build().
     */
    private fun installForegroundAdvertising() {
        if (lifecycleObserver != null) return
        val observer = object : DefaultLifecycleObserver {
            // ONLINE_ONLY has no offline subsystem: the radios are driven by enableOnlineMode().
            override fun onStart(owner: LifecycleOwner) {
                if (builtMode != Mode.ONLINE_ONLY) startSharing()
            }
            // Keep the radios on in the background while online mode is enabled: the
            // receiving side of an orchestrated transfer must stay reachable.
            override fun onStop(owner: LifecycleOwner) {
                if (builtMode != Mode.ONLINE_ONLY && !onlineEnabled) stopSharing()
            }
        }
        lifecycleObserver = observer
        main.post { ProcessLifecycleOwner.get().lifecycle.addObserver(observer) }
    }

    fun isBuilt(): Boolean = built

    /**
     * One-time device enrollment (see [HopcastSDK.provision]). Must run after [build].
     * On success, if the app is foreground (sharing requested), sharing is (re)started:
     * the lifecycle observer's earlier startSharing() was a native no-op while the SDK
     * was still unprovisioned (gating), so it must be replayed now.
     */
    fun provision(
        sdkKey: String,
        userId: String,
        callback: (Result<Unit>) -> Unit,
    ) {
        if (!built) {
            callback(Result.failure(IllegalStateException("SDK not built — call build() first")))
            return
        }
        // The SDK owns its endpoint (production .io) — the host app never supplies a URL.
        HopcastSDK.provision(sdkKey, userId) { result ->
            if (result.isSuccess && sharing) startSharing()
            if (result.isSuccess && onlineEnabled) HopcastSDK.enableOnlineMode()
            callback(result)
        }
    }

    /** Drops the persisted identity — the SDK is inert again until the next provision(). */
    fun clearIdentity() {
        if (built) HopcastSDK.clearIdentity()
    }

    fun deviceUuid(): String = if (built) HopcastSDK.deviceUuid else "unknown"

    fun modeName(): String = when (if (built) builtMode else Mode.OFFLINE_ONLY) {
        Mode.OFFLINE_ONLY -> "offlineOnly"
        Mode.ONLINE_ONLY -> "onlineOnly"
        Mode.HYBRID -> "hybrid"
    }

    // --- Online mode ---

    fun enableOnlineMode() {
        if (!built) return
        onlineEnabled = true
        HopcastSDK.enableOnlineMode()
    }

    fun disableOnlineMode() {
        onlineEnabled = false
        if (built) HopcastSDK.disableOnlineMode()
    }

    fun reportDownloadedFile(infraWire: String, contentIds: List<String>) {
        if (!built) return
        val infra = InfraType.values().firstOrNull { it.wire == infraWire } ?: run {
            Log.w(TAG, "reportDownloadedFile: unknown infraType '$infraWire'")
            return
        }
        HopcastSDK.reportDownloadedFile(infra, contentIds)
    }

    fun reportRemovedFile(contentIds: List<String>) {
        if (built) HopcastSDK.reportRemovedFile(contentIds)
    }

    fun declareNeed(contentId: String, ttlSeconds: Int): String? =
        if (built) HopcastSDK.declareNeed(contentId, ttlSeconds) else null

    fun cancelNeed(needId: String) {
        if (built) HopcastSDK.cancelNeed(needId)
    }

    fun handleFcmMessage(data: Map<String, String>) {
        if (built) HopcastSDK.handleFcmMessage(data)
    }

    fun handleFcmToken(token: String) {
        if (built) HopcastSDK.handleFcmToken(token)
    }

    /** True once a device identity is persisted (requires [build] on Android). */
    fun isProvisioned(): Boolean = built && HopcastSDK.isProvisioned

    fun getRequiredPermissions(): List<String> = HopcastSDK.getRequiredPermissions()

    @Volatile private var sharing = false

    fun startSharing() {
        Log.i(TAG, "startSharing called (built=$built, sharing=$sharing)")
        if (!built) return
        sharing = true
        // Always restart a fresh session (stop -> start): this recovers a discovery
        // session that stalled (neighbour list stuck at 0 after churn).
        try {
            HopcastSDK.stopSharing()
        } catch (_: Exception) {}
        main.postDelayed({
            if (built) {
                HopcastSDK.startSharing(null)
                Log.i(TAG, "startSharing (re)started after purge")
            }
        }, 500L)
    }

    fun stopSharing() {
        sharing = false
        if (built) HopcastSDK.stopSharing()
    }

    fun isWifiEnabled(): Boolean = if (built) HopcastSDK.isWifiEnabled() else false

    fun sendFiles(endpointIds: List<String>, filePaths: List<String>, metadata: ByteArray?): String? {
        if (!built) return null
        val files = filePaths.map { File(it) }.filter { it.exists() && it.canRead() && it.length() > 0 }
        if (endpointIds.isEmpty() || files.isEmpty()) return null
        return HopcastSDK.sendFiles(endpointIds, files, metadata)
    }

    fun acceptTransfer(transferId: String) {
        if (built) HopcastSDK.acceptTransfer(transferId)
    }

    fun rejectTransfer(transferId: String) {
        if (built) HopcastSDK.rejectTransfer(transferId)
    }

    fun release() {
        lifecycleObserver?.let { obs ->
            main.post { ProcessLifecycleOwner.get().lifecycle.removeObserver(obs) }
        }
        lifecycleObserver = null
        if (built) {
            HopcastSDK.removeTransferListener(TRANSFER_TAG)
            HopcastSDK.removeOnlineEventListener(TRANSFER_TAG)
            HopcastSDK.removeTransferHandoffListener(TRANSFER_TAG)
            HopcastSDK.setDeviceDiscoveryListener(null)
            HopcastSDK.release()
        }
        built = false
        sharing = false
        onlineEnabled = false
        builtMode = Mode.OFFLINE_ONLY
    }

    // --- EventSink wiring (called by HopcastPlugin) ---

    fun setNeighborsSink(sink: EventChannel.EventSink?) {
        neighborsSink = sink
        // Replay the last known snapshot immediately to the new subscriber.
        if (sink != null && lastNeighbors.isNotEmpty()) {
            val snapshot = lastNeighbors
            main.post { sink.success(snapshot) }
        }
    }

    fun setTransfersSink(sink: EventChannel.EventSink?) {
        transfersSink = sink
    }

    private fun emitTransfer(map: Map<String, Any?>) {
        main.post { transfersSink?.success(map) }
    }

    fun setOnlineSink(sink: EventChannel.EventSink?) {
        onlineSink = sink
    }

    fun setHandoffsSink(sink: EventChannel.EventSink?) {
        handoffsSink = sink
    }

    private fun emitOnline(map: Map<String, Any?>) {
        main.post { onlineSink?.success(map) }
    }

    private fun emitHandoff(map: Map<String, Any?>) {
        main.post { handoffsSink?.success(map) }
    }

    // Common denominator with the iOS TransferHandoff (lowercase status/direction).
    private fun handoffToMap(h: TransferHandoff, instructionId: String): Map<String, Any?> = mapOf(
        "instructionId" to instructionId,
        "status" to h.status.name.lowercase(),
        "reason" to h.reason,
        "bytesTotal" to h.bytesTotal,
        "files" to h.files.map {
            mapOf(
                "fileId" to it.fileId,
                "bytes" to it.bytes,
                "direction" to it.direction.name.lowercase(),
            )
        },
    )

    private fun toMap(event: TransferEvent): Map<String, Any?> {
        val base = mutableMapOf<String, Any?>(
            "transferId" to event.transferId,
            "isReceiver" to event.isReceiver,
        )
        when (event) {
            is TransferEvent.BulkSendStarted -> {
                base["type"] = "bulkStarted"
                base["totalPeers"] = event.totalPeers
                base["totalFiles"] = event.totalFiles
            }
            is TransferEvent.TransferProgress -> {
                base["type"] = "transferProgress"
                base["bytesTransferred"] = event.bytesTransferred
                base["totalBytes"] = event.totalBytes
                base["peerName"] = event.peer.displayName
            }
            is TransferEvent.FileProgress -> {
                base["type"] = "fileProgress"
                base["fileName"] = event.file.name
                base["bytesTransferred"] = event.bytesTransferred
                base["totalBytes"] = event.totalBytes
                base["peerName"] = event.peer.displayName
            }
            is TransferEvent.FileCompleted -> {
                base["type"] = "fileCompleted"
                base["fileName"] = event.file.name
                base["localPath"] = event.localPath
                base["fileIndex"] = event.fileIndex
                base["fileTotal"] = event.fileTotal
                base["peerName"] = event.peer.displayName
            }
            is TransferEvent.FileFailed -> {
                base["type"] = "fileFailed"
                base["fileName"] = event.file.name
                base["reason"] = event.reason.name
                base["peerName"] = event.peer.displayName
            }
            is TransferEvent.TransferFailed -> {
                base["type"] = "transferFailed"
                base["reason"] = event.reason.name
                base["peerName"] = event.peer.displayName
            }
            is TransferEvent.BulkSendFinished -> {
                base["type"] = "bulkFinished"
                base["outcomes"] = event.outcomes.map {
                    mapOf(
                        "peerName" to it.peer.displayName,
                        "status" to it.status.name,
                        "reason" to it.errorReason?.name,
                    )
                }
            }
            else -> {
                base["type"] = "unknown"
            }
        }
        return base
    }
}
