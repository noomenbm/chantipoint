package com.example.chantipoint.journal

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyPermanentlyInvalidatedException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.security.UnrecoverableKeyException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.AEADBadTagException

/** Process-scoped worker; channel lifetime never owns keys or journal contents. */
class JournalChannel(context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val applicationContext = context.applicationContext
    private val active = AtomicBoolean(true)
    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "chantipoint/secure_command_journal")

    companion object {
        private val worker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
            ArrayBlockingQueue<Runnable>(32),
            { task -> Thread(task, "chantipoint-journal").apply { isDaemon = true } },
            ThreadPoolExecutor.AbortPolicy())
    }

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("read", "compareAndSwap", "inspectRecoveryV1", "normalizeRecoveryV1")) {
            result.notImplemented(); return
        }
        try { worker.execute {
            try {
                val args = call.arguments as? Map<*, *> ?: problem("journal_corrupt")
                exactFields(args, when (call.method) {
                    "compareAndSwap" -> setOf("api_version", "binding", "expected_revision", "expected_key", "replacement")
                    "normalizeRecoveryV1" -> setOf("api_version", "binding", "snapshot", "validated_record")
                    else -> setOf("api_version", "binding")
                })
                if (channelInteger(args["api_version"]) != 1L) problem("journal_unsupported_format")
                val binding = SlotBinding.parse(args["binding"])
                val store = EncryptedJournalStore(applicationContext)
                val response: Map<String, Any> = if (call.method == "read") {
                    try {
                        val record = store.read(binding)
                        if (record == null) mapOf("status" to "absent") else mapOf("status" to "stored", "record" to record)
                    } catch (error: JournalProblem) {
                        if (error.code != "journal_recovery_required") throw error
                        mapOf("status" to "recovery_required")
                    }
                } else if (call.method == "inspectRecoveryV1") {
                    store.inspectRecovery(binding).toWire()
                } else if (call.method == "normalizeRecoveryV1") {
                    val snapshot = text(args["snapshot"], 64)
                    if (!Regex("^[0-9a-f]{64}$").matches(snapshot)) problem("journal_corrupt")
                    val input = args["validated_record"] as? ByteArray ?: problem("journal_corrupt")
                    if (input.size > RECORD_LIMIT) problem("journal_corrupt")
                    mapOf("status" to "stored", "record" to store.normalizeRecovery(binding, snapshot, input.copyOf()))
                } else {
                    val revision = channelInteger(args["expected_revision"])
                    val key = args["expected_key"]?.let { text(it, 160) }
                    val input = args["replacement"] as? ByteArray ?: problem("journal_corrupt")
                    if (input.size > RECORD_LIMIT) problem("journal_corrupt")
                    val replacement = input.copyOf()
                    mapOf("status" to "written", "revision" to store.compareAndSwap(binding, revision, key, replacement))
                }
                main.post { if (active.get()) result.success(response) }
            } catch (error: Exception) {
                val code = errorCode(error)
                main.post { if (active.get()) result.error(code, "Journal storage unavailable.", null) }
            }
        } } catch (_: RejectedExecutionException) {
            if (active.get()) result.error("journal_native_failure", "Journal storage unavailable.", null)
        }
    }

    fun detach() {
        active.set(false)
        channel.setMethodCallHandler(null)
        // Already queued work finishes without publishing into a detached engine.
    }

    private fun errorCode(error: Exception): String {
        if (error is JournalProblem) return if (error.code == "journal_recovery_required") "journal_unreadable" else error.code
        // Some providers wrap these exceptions. Inspect types only, never text.
        val causes = generateSequence<Throwable>(error) { it.cause }.take(8).toList()
        return when {
            causes.any { it is KeyPermanentlyInvalidatedException || it is UnrecoverableKeyException } -> "journal_invalidated_key"
            causes.any { it is AEADBadTagException } -> "journal_authentication_failed"
            error is IOException -> "journal_storage_failure"
            else -> "journal_native_failure"
        }
    }
}
