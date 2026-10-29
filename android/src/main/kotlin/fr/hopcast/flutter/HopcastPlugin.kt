package fr.hopcast.flutter

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import fr.hopcast.sdk.HopcastIdentityException
import fr.hopcast.sdk.enums.Mode
import fr.hopcast.sdk.model.OnlineConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

/**
 * Flutter plugin exposing the Hopcast bridge through one MethodChannel and two
 * EventChannels (discovered neighbours + transfer events). Auto-registered by the
 * Flutter plugin loader — no manual wiring in the host `MainActivity` is required.
 */
class HopcastPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private companion object {
        const val METHODS = "hopcast/methods"
        const val NEIGHBORS = "hopcast/neighbors"
        const val TRANSFERS = "hopcast/transfers"
        const val ONLINE = "hopcast/online"
        const val HANDOFFS = "hopcast/handoffs"
        const val PERMISSION_REQUEST_CODE = 4731
        const val DEFAULT_DEVICE_ID = "HopcastDevice"
    }

    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var neighborsChannel: EventChannel
    private lateinit var transfersChannel: EventChannel
    private lateinit var onlineChannel: EventChannel
    private lateinit var handoffsChannel: EventChannel

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val permissionListener =
        PluginRegistry.RequestPermissionsResultListener { requestCode, _, grantResults ->
            if (requestCode != PERMISSION_REQUEST_CODE) return@RequestPermissionsResultListener false
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
            true
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHODS).also { it.setMethodCallHandler(this) }

        neighborsChannel = EventChannel(binding.binaryMessenger, NEIGHBORS)
        neighborsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                HopcastBridge.setNeighborsSink(events)
            }

            override fun onCancel(arguments: Any?) {
                HopcastBridge.setNeighborsSink(null)
            }
        })

        transfersChannel = EventChannel(binding.binaryMessenger, TRANSFERS)
        transfersChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                HopcastBridge.setTransfersSink(events)
            }

            override fun onCancel(arguments: Any?) {
                HopcastBridge.setTransfersSink(null)
            }
        })

        onlineChannel = EventChannel(binding.binaryMessenger, ONLINE)
        onlineChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                HopcastBridge.setOnlineSink(events)
            }

            override fun onCancel(arguments: Any?) {
                HopcastBridge.setOnlineSink(null)
            }
        })

        handoffsChannel = EventChannel(binding.binaryMessenger, HANDOFFS)
        handoffsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                HopcastBridge.setHandoffsSink(events)
            }

            override fun onCancel(arguments: Any?) {
                HopcastBridge.setHandoffsSink(null)
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        neighborsChannel.setStreamHandler(null)
        transfersChannel.setStreamHandler(null)
        onlineChannel.setStreamHandler(null)
        handoffsChannel.setStreamHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(permissionListener)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionListener)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "build" -> {
                val act = activity
                if (act == null) {
                    result.error("NO_ACTIVITY", "No activity available to build the SDK", null)
                    return
                }
                val deviceId = call.argument<String>("deviceId") ?: DEFAULT_DEVICE_ID
                // serviceId is optional: null / blank keeps the SDK default (the host
                // app's package name). Two devices only discover each other when they
                // share the same serviceId.
                val serviceId = call.argument<String>("serviceId")
                val mode = when (call.argument<String>("mode")) {
                    "onlineOnly" -> Mode.ONLINE_ONLY
                    "hybrid" -> Mode.HYBRID
                    else -> Mode.OFFLINE_ONLY
                }
                val onlineConfig = call.argument<Map<String, Any?>>("onlineConfig")?.let { m ->
                    val broker = (m["brokerUrl"] as? String)?.takeIf { it.isNotBlank() }
                    OnlineConfig(
                        brokerUrl = broker ?: OnlineConfig.DEFAULT_BROKER_URL,
                        isSecondaryFcm = m["isSecondaryFcm"] as? Boolean ?: true,
                        runAsService = m["runAsService"] as? Boolean ?: false,
                    )
                }
                // Default true: unchanged behaviour (link dropped after every send).
                val autoDisconnect = call.argument<Boolean>("autoDisconnectAfterTransfer") ?: true
                HopcastBridge.build(
                    deviceId,
                    serviceId,
                    mode,
                    onlineConfig,
                    autoDisconnect,
                    appContext,
                    act as? LifecycleOwner,
                    File(appContext.filesDir, "hopcast_inbox"),
                )
                result.success(true)
            }
            "provision" -> {
                val sdkKey = call.argument<String>("sdkKey")
                val userId = call.argument<String>("userId")
                if (sdkKey.isNullOrBlank() || userId.isNullOrBlank()) {
                    result.error("BAD_ARGS", "provision requires sdkKey and userId", null)
                    return
                }
                if (!HopcastBridge.isBuilt()) {
                    result.error("NOT_BUILT", "Call build() before provision()", null)
                    return
                }
                HopcastBridge.provision(sdkKey, userId) { r ->
                    // Delivered on the main thread by the SDK.
                    r.fold(
                        onSuccess = { result.success(true) },
                        onFailure = { e -> result.error("PROVISION_FAILED", e.message, identityErrorDetails(e)) },
                    )
                }
            }
            "isProvisioned" -> result.success(HopcastBridge.isProvisioned())
            "clearIdentity" -> { HopcastBridge.clearIdentity(); result.success(null) }
            "deviceUuid" -> result.success(HopcastBridge.deviceUuid())
            "getMode" -> result.success(HopcastBridge.modeName())
            "enableOnlineMode" -> { HopcastBridge.enableOnlineMode(); result.success(null) }
            "disableOnlineMode" -> { HopcastBridge.disableOnlineMode(); result.success(null) }
            "reportDownloadedFile" -> {
                val infra = call.argument<String>("infraType") ?: ""
                val ids = call.argument<List<String>>("contentIds") ?: emptyList()
                HopcastBridge.reportDownloadedFile(infra, ids)
                result.success(null)
            }
            "reportRemovedFile" -> {
                HopcastBridge.reportRemovedFile(call.argument<List<String>>("contentIds") ?: emptyList())
                result.success(null)
            }
            "declareNeed" -> {
                val contentId = call.argument<String>("contentId")
                val ttl = call.argument<Int>("ttlSeconds")
                if (contentId.isNullOrBlank() || ttl == null) {
                    result.error("BAD_ARGS", "declareNeed requires contentId and ttlSeconds", null)
                    return
                }
                result.success(HopcastBridge.declareNeed(contentId, ttl))
            }
            "cancelNeed" -> {
                call.argument<String>("needId")?.let { HopcastBridge.cancelNeed(it) }
                result.success(null)
            }
            "handleFcmMessage" -> {
                val data = call.argument<Map<String, Any?>>("data")
                    ?.mapValues { it.value?.toString() ?: "" } ?: emptyMap()
                HopcastBridge.handleFcmMessage(data)
                result.success(null)
            }
            "handleFcmToken" -> {
                call.argument<String>("token")?.let { HopcastBridge.handleFcmToken(it) }
                result.success(null)
            }
            "getRequiredPermissions" -> result.success(HopcastBridge.getRequiredPermissions())
            "requestPermissions" -> requestPermissions(result)
            "startSharing" -> { HopcastBridge.startSharing(); result.success(null) }
            "stopSharing" -> { HopcastBridge.stopSharing(); result.success(null) }
            "isWifiEnabled" -> result.success(HopcastBridge.isWifiEnabled())
            "sendFiles" -> {
                val endpointIds = call.argument<List<String>>("endpointIds") ?: emptyList()
                val filePaths = call.argument<List<String>>("filePaths") ?: emptyList()
                val metadata = call.argument<String>("metadata")?.toByteArray(Charsets.UTF_8)
                result.success(HopcastBridge.sendFiles(endpointIds, filePaths, metadata))
            }
            "acceptTransfer" -> {
                val id = call.argument<String>("transferId")
                if (id != null) HopcastBridge.acceptTransfer(id)
                result.success(null)
            }
            "rejectTransfer" -> {
                val id = call.argument<String>("transferId")
                if (id != null) HopcastBridge.rejectTransfer(id)
                result.success(null)
            }
            "release" -> { HopcastBridge.release(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    /** Typed cause for the Dart HopcastIdentityException (`details.kind` / `statusCode`). */
    private fun identityErrorDetails(e: Throwable): Map<String, Any?> = when (e) {
        is HopcastIdentityException.Server -> mapOf("kind" to "server", "statusCode" to e.statusCode)
        is HopcastIdentityException.InvalidResponse -> mapOf("kind" to "invalidResponse")
        is HopcastIdentityException.NotProvisioned -> mapOf("kind" to "notProvisioned")
        is java.io.IOException -> mapOf("kind" to "transport")
        is IllegalStateException -> mapOf("kind" to "notBuilt")
        else -> mapOf("kind" to "unknown")
    }

    private fun requestPermissions(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No activity available to request permissions", null)
            return
        }
        val missing = HopcastBridge.getRequiredPermissions().filter {
            ContextCompat.checkSelfPermission(act, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("PENDING", "A permission request is already in progress", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }
}
