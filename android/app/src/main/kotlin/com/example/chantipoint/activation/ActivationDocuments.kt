package com.example.chantipoint.activation

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** User-selected documents only; no enrollment/key/journal operation occurs here. */
class ActivationDocuments(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "chantipoint/development_activation_documents")
    private val alive = AtomicBoolean(true)
    private val busy = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private data class Selection(val result: MethodChannel.Result, val bytes: ByteArray?)
    private var pending: Selection? = null

    companion object { private const val SAVE = 43801; private const val OPEN = 43802 }
    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val allowed = activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0 &&
            activity.packageName in setOf("com.example.chantipoint", "com.example.chantipoint.enrollmentvalidation")
        if (!allowed) { result.error("activation_documents_unavailable", null, null); return }
        if (call.method !in setOf("saveRequest", "chooseSignature")) { result.notImplemented(); return }
        val args = call.arguments as? Map<*, *>
        val fields = if (call.method == "saveRequest") setOf("api_version", "payload") else setOf("api_version")
        if (args == null || args.keys != fields || args["api_version"] != 1) {
            result.error("activation_document_invalid", null, null); return
        }
        val bytes = if (call.method == "saveRequest") args["payload"] as? ByteArray else null
        if (call.method == "saveRequest" && (bytes == null || bytes.isEmpty() || bytes.size > 4096)) {
            result.error("activation_document_invalid", null, null); return
        }
        if (!busy.compareAndSet(false, true)) { result.error("activation_document_busy", null, null); return }
        pending = Selection(result, bytes?.copyOf())
        val intent = if (bytes != null) Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE); type = "application/json"
            putExtra(Intent.EXTRA_TITLE, "chantipoint-activation-request.json")
        } else Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
        }
        try { activity.startActivityForResult(intent, if (bytes != null) SAVE else OPEN) }
        catch (_: Exception) {
            pending = null; busy.set(false); result.error("activation_document_unavailable", null, null)
        }
    }

    fun activityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in setOf(SAVE, OPEN)) return false
        val selection = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            busy.set(false); selection.result.success(mapOf("status" to "cancelled")); return true
        }
        val uri = data.data!!
        worker.execute {
            var response: Map<String, Any>? = null
            var failed = false
            try {
                if (requestCode == SAVE) {
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { stream ->
                        stream.write(selection.bytes ?: error("missing payload")); stream.flush()
                    } ?: error("missing stream")
                    response = mapOf("status" to "saved")
                } else {
                    val signature = activity.contentResolver.openInputStream(uri)?.use { stream ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(129)
                        while (output.size() <= 128) {
                            val count = stream.read(buffer, 0, minOf(buffer.size, 129 - output.size()))
                            if (count < 0) break
                            if (count == 0) error("invalid stream")
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray().also { if (it.isEmpty() || it.size > 128) error("invalid size") }
                    } ?: error("missing stream")
                    response = mapOf("status" to "selected", "signature" to signature)
                }
            } catch (_: Exception) { failed = true }
            main.post {
                busy.set(false)
                if (alive.get()) {
                    if (failed) selection.result.error("activation_document_unavailable", null, null)
                    else selection.result.success(response)
                }
            }
        }
        return true
    }

    fun detach() {
        alive.set(false); channel.setMethodCallHandler(null)
        pending?.result?.error("activation_documents_unavailable", null, null)
        pending = null; worker.shutdownNow()
    }
}
