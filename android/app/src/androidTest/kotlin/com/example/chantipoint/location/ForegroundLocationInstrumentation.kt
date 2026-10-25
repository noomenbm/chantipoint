package com.example.chantipoint.location

import android.app.Activity
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import com.example.chantipoint.MainActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Isolated location fixture. No production diagnostic controls or fix logging.
 * acquire is location-only and never automates the user's permission controls.
 */
class ForegroundLocationInstrumentation : Instrumentation() {
    private var scenario = "allow"
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        scenario = arguments?.getString("scenario") ?: "allow"
        start()
    }
    override fun onStart() {
        val report = Bundle()
        var success = false
        var activity: MainActivity? = null
        var engine: FlutterEngine? = null
        var activityStartRequested = false
        var stage = "namespace"
        val cacheId = "c4-isolated-test-engine"
        try {
            check(targetContext.packageName == "com.example.chantipoint.locationvalidation")
            check(scenario in setOf("allow", "deny", "approximate", "services_off", "acquire"))
            val ready = CountDownLatch(1)
            val finished = CountDownLatch(1)
            var passed = false
            var diagnostic = "no_reply"
            var clicked = false
            var systemUiWaits = 0
            var nativeIdle = false
            var observedSignal: CancellationSignal? = null
            // Test-only read of ownership/cancellation, never the returned Location.
            fun observeNative() {
                val field = MainActivity::class.java.getDeclaredField("foregroundLocation").apply { isAccessible = true }
                val bridge = field.get(activity) ?: error("bridge unavailable")
                val current = bridge.javaClass.getDeclaredField("active").apply { isAccessible = true }.get(bridge)
                nativeIdle = current == null
                if (current != null) {
                    observedSignal = current.javaClass.getDeclaredField("signal")
                        .apply { isAccessible = true }.get(current) as CancellationSignal
                }
            }
            stage = "engine"
            lateinit var probeEngine: FlutterEngine
            runOnMainSync {
                probeEngine = FlutterEngine(targetContext)
                engine = probeEngine
                FlutterEngineCache.getInstance().put(cacheId, probeEngine)
                probeEngine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            }
            stage = "activity"
            activityStartRequested = true
            activity = startActivitySync(FlutterActivity.CachedEngineIntentBuilder(MainActivity::class.java, cacheId)
                .destroyEngineWithActivity(true).build(targetContext)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            runOnMainSync {
                if (probeEngine.renderer.isDisplayingFlutterUi) ready.countDown()
                else probeEngine.renderer.addIsDisplayingFlutterUiListener(object : FlutterUiDisplayListener {
                    override fun onFlutterUiDisplayed() {
                        probeEngine.renderer.removeIsDisplayingFlutterUiListener(this)
                        ready.countDown()
                    }
                    override fun onFlutterUiNoLongerDisplayed() {}
                })
            }
            stage = "frame"
            check(ready.await(60, TimeUnit.SECONDS))
            stage = "probe"
            runOnMainSync {
                val control = MethodChannel(probeEngine.dartExecutor.binaryMessenger, "chantipoint/location_test_control")
                control.setMethodCallHandler { call, result ->
                    if (call.method == "finish") {
                        val args = call.arguments as Map<*, *>
                        passed = args["passed"] == true
                        diagnostic = args["diagnostic"] as String
                        result.success(null)
                        finished.countDown()
                    } else result.notImplemented()
                }
                control.invokeMethod("run", scenario)
            }
            val deadline = SystemClock.elapsedRealtime() + 60000
            while (finished.count != 0L && SystemClock.elapsedRealtime() < deadline) {
                runOnMainSync { observeNative() }
                if (scenario in setOf("allow", "deny") && !clicked) {
                    val root = uiAutomation.rootInActiveWindow
                    if (root != null) {
                        if (root.packageName?.toString() == "android" && systemUiWaits < 2) {
                            if (root.findAccessibilityNodeInfosByViewId("android:id/aerr_wait")
                                    .any { it.performAction(AccessibilityNodeInfo.ACTION_CLICK) }) systemUiWaits++
                        }
                        clicked = clickPermission(root)
                    }
                }
                finished.await(150, TimeUnit.MILLISECONDS)
            }
            runOnMainSync { observeNative() }
            val manager = targetContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val providers = manager.getProviders(true).filter { it in setOf("gps", "fused", "network", "passive") }.sorted().joinToString(",")
            success = finished.count == 0L && passed && nativeIdle && (scenario !in setOf("allow", "deny") || clicked)
            report.putString("stream", "C4 $scenario: ${if (success) "PASS" else "FAIL"}; permission_dialog_clicked=$clicked; system_ui_waits=$systemUiWaits; enabled_providers=$providers; native_idle=$nativeIdle; native_cancelled=${observedSignal?.isCanceled ?: "not_observed"}; $diagnostic")
        } catch (_: Exception) {
            report.putString("stream", "C4 $scenario: harness_unavailable:$stage")
        } finally {
            activity?.let { runOnMainSync { it.finish() } }
            runOnMainSync {
                FlutterEngineCache.getInstance().remove(cacheId)
                // After launch, Activity owns engine teardown. Destroying it
                // before FlutterView.onDestroy detaches causes a JNI failure.
                if (!activityStartRequested) engine?.destroy()
            }
            finish(if (success) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
        }
    }

    private fun clickPermission(root: AccessibilityNodeInfo): Boolean {
        val packageName = root.packageName?.toString() ?: return false
        if (packageName !in setOf("com.android.permissioncontroller", "com.google.android.permissioncontroller")) return false
        val id = if (scenario == "deny") "permission_deny_button" else "permission_allow_foreground_only_button"
        val byId = root.findAccessibilityNodeInfosByViewId("$packageName:id/$id")
        if (byId.any { it.performAction(AccessibilityNodeInfo.ACTION_CLICK) }) return true
        // Android 37's observed English fixture dialog. Match an exact system
        // label, never an application view or a coordinate-based blind tap.
        val labels = if (scenario == "deny") listOf("Don't allow", "Don’t allow")
            else listOf("While using the app", "Allow only while using the app")
        for (label in labels) for (node in root.findAccessibilityNodeInfosByText(label)) {
            if (node.text?.toString() != label) continue
            var target: AccessibilityNodeInfo? = node
            repeat(3) {
                if (target?.isClickable == true && target?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) return true
                target = target?.parent
            }
        }
        return false
    }
}
