package com.example.chantipoint.location

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import androidx.core.location.LocationManagerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

/** Opt-in, foreground-only one-shot plugin. No service, stream or auth/RPC code.
 * Cached geolocator's Dart timeout does not await cancellation and auto-binds a
 * service. This narrow bridge uses AndroidX's cancellable single-fix operation.
 */
class ForegroundLocationChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "chantipoint/foreground_location")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executor { task -> main.post(task) }
    private val manager = activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    private var foreground = false
    private var detached = false
    private var deniedObserved = false
    private var permissionReply: MethodChannel.Result? = null
    private var active: FixAttempt? = null

    companion object { private const val PERMISSION_REQUEST = 47124 }
    private class FixAttempt(val reply: MethodChannel.Result) {
        val signal = CancellationSignal()
        var finished = false
        var cancelFailed = false
        lateinit var timeout: Runnable
    }

    init { channel.setMethodCallHandler(this) }
    fun resume() { foreground = true }
    fun pause() {
        foreground = false
        active?.let { finish(it, "unavailable") }
    }
    fun detach() {
        pause()
        detached = true
        permissionReply?.error("location_unavailable", "Location unavailable.", null)
        permissionReply = null
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("servicesV1", "permissionV1", "requestPermissionV1", "fixV1")) {
            result.notImplemented(); return
        }
        try {
            val args = call.arguments as? Map<*, *> ?: error("invalid")
            val fields = if (call.method == "fixV1") setOf("api_version", "limit_ms") else setOf("api_version")
            if (args.keys != fields || args["api_version"] != 1) error("invalid")
            when (call.method) {
                "servicesV1" -> if (manager == null) {
                    result.error("location_unavailable", "Location unavailable.", null)
                } else result.success(LocationManagerCompat.isLocationEnabled(manager))
                "permissionV1" -> result.success(permission())
                "requestPermissionV1" -> requestPermission(result)
                else -> {
                    val value = args["limit_ms"]
                    val limit = when (value) { is Int -> value.toLong(); is Long -> value; else -> error("invalid") }
                    if (limit !in 1..15000) error("invalid")
                    fix(result, limit)
                }
            }
        } catch (_: Exception) {
            result.error("location_provider_error", "Location unavailable.", null)
        }
    }

    private fun granted(name: String) = activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED
    private fun permission(): String = when {
        granted(Manifest.permission.ACCESS_FINE_LOCATION) -> "precise"
        granted(Manifest.permission.ACCESS_COARSE_LOCATION) -> "approximate"
        deniedObserved && !activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION) &&
            !activity.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION) -> "denied_forever"
        else -> "denied"
    }
    private fun requestPermission(result: MethodChannel.Result) {
        if (!foreground || detached || permissionReply != null || active != null) {
            result.error("location_unavailable", "Location unavailable.", null); return
        }
        val observed = permission()
        if (observed != "denied") { result.success(observed); return }
        permissionReply = result
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION), PERMISSION_REQUEST)
        } catch (_: Exception) {
            permissionReply = null
            result.error("location_provider_error", "Location unavailable.", null)
        }
    }
    fun permissionResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val reply = permissionReply ?: return true
        permissionReply = null
        deniedObserved = !granted(Manifest.permission.ACCESS_FINE_LOCATION) && !granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        reply.success(permission())
        return true
    }

    private fun fix(reply: MethodChannel.Result, limit: Long) {
        if (!foreground || detached || active != null || permissionReply != null) {
            reply.success(mapOf("result" to "unavailable")); return
        }
        val permission = permission()
        if (permission == "denied" || permission == "denied_forever") {
            reply.success(mapOf("result" to "permission_denied")); return
        }
        val service = manager
        if (service == null) { reply.success(mapOf("result" to "unavailable")); return }
        if (!LocationManagerCompat.isLocationEnabled(service)) {
            reply.success(mapOf("result" to "location_services_disabled")); return
        }
        val enabled = service.getProviders(true)
        // Provider selection is not an employee mode or a precision claim.
        val candidates = if (permission == "precise") listOf("fused", "gps", "network") else listOf("fused", "network")
        val provider = candidates.firstOrNull { enabled.contains(it) }
        if (provider == null) { reply.success(mapOf("result" to "unavailable")); return }
        val attempt = FixAttempt(reply)
        active = attempt
        attempt.timeout = Runnable { finish(attempt, "timeout") }
        main.postDelayed(attempt.timeout, limit)
        try {
            LocationManagerCompat.getCurrentLocation(service, provider, attempt.signal, executor) { location ->
                // AndroidX's one-shot callback is settlement; cancellation is
                // not required once the OS has completed the request.
                finish(attempt, if (location == null) "unavailable" else "fix", location, settled = true)
            }
        } catch (_: SecurityException) {
            finish(attempt, "permission_denied")
        } catch (_: Exception) {
            finish(attempt, "provider_error")
        }
    }

    private fun finish(attempt: FixAttempt, status: String, location: Location? = null, settled: Boolean = false) {
        if (attempt.finished || active !== attempt) return
        if (!settled) {
            try { attempt.signal.cancel() }
            catch (_: Exception) {
                // Do NOT report a settled timeout while native work is unknown.
                // Retain the attempt/busy ownership until the one-shot callback
                // settles or lifecycle cancellation succeeds. No polling/retry.
                attempt.cancelFailed = true
                return
            }
        }
        attempt.finished = true
        active = null
        main.removeCallbacks(attempt.timeout)
        val effective = if (attempt.cancelFailed) "provider_error" else status
        val response = if (effective == "fix" && location != null) mapOf(
            "result" to "fix", "latitude" to location.latitude, "longitude" to location.longitude,
            "accuracy_meters" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
            "observed_at_millis" to location.time,
            // Only the provider on the returned fix, never requested accuracy,
            // selected fallback or isMock: a mocked fix is not proof of emulator.
            "provider" to (location.provider?.takeIf { it in setOf("gps", "network", "fused") } ?: "unknown"),
        ) else mapOf("result" to effective)
        attempt.reply.success(response)
    }
}
