package com.example.chantipoint.journal

import android.app.Activity
import android.app.Instrumentation
import android.content.ContextWrapper
import android.system.ErrnoException
import android.os.Bundle
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Cipher
import javax.crypto.SecretKey

/** Dependency-free framework instrumentation. All destructive fixtures require a separate app ID. */
class JournalRuntimeInstrumentation : Instrumentation() {
    private var phase = "fresh"
    private val complete = CountDownLatch(1)
    private var report = Bundle()
    private var failed = true
    private lateinit var engine: FlutterEngine
    private lateinit var journal: JournalChannel
    private lateinit var control: MethodChannel
    private var stage = "namespace"
    private val migrationFault = AtomicReference<String?>(null)

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        phase = arguments?.getString("phase") ?: "fresh"
        start()
    }

    override fun onStart() {
        try {
            check(targetContext.packageName == "com.example.chantipoint.journalvalidation")
            check(phase in setOf("fresh", "restart"))
            stage = "fixture-reset"
            if (phase == "fresh") clearFictionalFixtures()
            stage = "engine-setup"
            runOnMainSync {
                engine = FlutterEngine(targetContext)
                journal = JournalChannel(targetContext, engine.dartExecutor.binaryMessenger, object : LegacyMigrationIo {
                    // Controls/state exist ONLY in this androidTest source set.
                    private fun consume(stage: String): Boolean {
                        val requested = migrationFault.get()
                        return requested == stage && migrationFault.compareAndSet(requested, null)
                    }
                    override fun checkpoint(stage: String) {
                        if (consume(stage)) problem("journal_sync_failure")
                    }
                    override fun deleteSource(file: File): Boolean = if (consume("delete")) false else file.delete()
                })
                control = MethodChannel(engine.dartExecutor.binaryMessenger, "chantipoint/journal_test_control")
                control.setMethodCallHandler { call, result ->
                    try {
                        if (call.method == "finish") {
                            val args = call.arguments as Map<*, *>
                            val failures = args["failures"] as List<*>
                            failed = failures.isNotEmpty()
                            report.putString("stream", "Journal $phase: ${args["passed"]} passed; ${failures.size} failed. ${failures.joinToString()}")
                            result.success(null)
                            complete.countDown()
                        } else result.success(fixture(call))
                    } catch (_: Exception) {
                        result.error("fixture_failure", "Fictional fixture operation failed.", null)
                    }
                }
                engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            }
            stage = "probe"
            if (!complete.await(120, TimeUnit.SECONDS)) report.putString("stream", "Journal probe timed out.")
        } catch (error: Exception) {
            // Static stage and source location only; no data/provider messages.
            val frame = error.stackTrace.firstOrNull { it.className == javaClass.name }
            report.putString("stream", "Journal harness failed: ${error.javaClass.simpleName} at $stage ${frame?.methodName}:${frame?.lineNumber}")
        } finally {
            if (::engine.isInitialized) runOnMainSync {
                control.setMethodCallHandler(null)
                journal.detach()
                engine.destroy()
            }
            finish(if (failed) Activity.RESULT_CANCELED else Activity.RESULT_OK, report)
        }
    }

    // Android may expose a valid platform alias for the app-data parent.
    // Match production's canonical parent while still rejecting a linked slot directory.
    private fun root(): File = File(targetContext.noBackupFilesDir.canonicalFile, "attendance_journal").also {
        check(it.canonicalFile == it.absoluteFile)
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun alias() = "${targetContext.packageName}.attendance_journal.aes.v1"

    private fun clearFictionalFixtures() {
        val directory = root()
        for (file in directory.listFiles().orEmpty()) {
            check(file.canonicalFile == file.absoluteFile && file.isFile)
            check(file.name == "journal.lock" || Regex("^slot_[0-9a-f]{64}\\.bin(?:\\.new|\\.bak)?$").matches(file.name))
            check(file.delete())
        }
        keyStore().deleteEntry(alias())
        val legacyRoot = targetContext.filesDir.canonicalFile
        for (file in legacyRoot.listFiles().orEmpty().filter {
            it.name.startsWith("attendance_") || it.name == "journal_unrelated_fixture"
        }) {
            // Fixed isolated namespace only. Never follow a symlink or recurse.
            check(file.parentFile == legacyRoot)
            check(file.delete())
        }
    }

    // Fixture-specific counts ignore unrelated VM/Flutter descriptors. The kernel
    // marks an unlinked open file with " (deleted)"; count those as leaks too.
    // These diagnostics and their positive controls exist only in androidTest.
    private fun sourceDescriptorCounts(binding: SlotBinding): Map<String, Int> {
        val source = File(targetContext.filesDir.canonicalFile, legacyBasename(binding)).path
        var finalized = 0
        var artifacts = 0
        val entries = File("/proc/self/fd").listFiles() ?: error("Descriptor inspection unavailable")
        for (entry in entries) {
            val target = try { Os.readlink(entry.path).removeSuffix(" (deleted)") }
            catch (error: ErrnoException) {
                // The directory enumeration's own descriptor may already be closed.
                if (error.errno == OsConstants.ENOENT) continue
                throw error
            }
            if (target == source) finalized++
            else if (target.startsWith("$source.")) artifacts++
        }
        return mapOf("source" to finalized, "artifacts" to artifacts)
    }

    private fun fixture(call: MethodCall): Any? {
        if (call.method == "phase") return phase
        if (call.method == "keyExists") return keyStore().containsAlias(alias())
        if (call.method == "loseKey") {
            keyStore().deleteEntry(alias())
            return null
        }
        val args = call.arguments as Map<*, *>
        val binding = SlotBinding.parse(args["binding"])
        if (call.method == "sourceDescriptorCounts") return sourceDescriptorCounts(binding)
        if (call.method == "sourceDescriptorProbe") {
            val suffix = args["suffix"] as String
            check(suffix in setOf("", ".tmp"))
            val unlink = args["unlink"] == true
            check(!unlink || suffix == ".tmp")
            val file = File(targetContext.filesDir.canonicalFile, legacyBasename(binding) + suffix)
            val before = sourceDescriptorCounts(binding)
            val kind = if (suffix.isEmpty()) "source" else "artifacts"
            val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
            try {
                // Reproduce the old borrowed-stream close: the counter must
                // still see our descriptor until the explicit Os.close below.
                FileInputStream(fd).use { check(it.read() >= 0) }
                check(sourceDescriptorCounts(binding)[kind] == before.getValue(kind) + 1)
                if (unlink) {
                    check(file.delete())
                    check(sourceDescriptorCounts(binding)[kind] == before.getValue(kind) + 1)
                }
            } finally { Os.close(fd) }
            check(sourceDescriptorCounts(binding) == before)
            return true
        }
        if (call.method == "migrationFault") {
            val value = args["stage"] as String
            check(value in setOf("target_sync", "delete", "source_sync", "completed_sync"))
            migrationFault.set(value)
            return null
        }
        if (call.method == "normalNamespaceRejected") {
            val normal = object : ContextWrapper(targetContext) {
                override fun getPackageName() = "com.example.chantipoint"
            }
            try {
                EncryptedJournalStore(normal).verifyMigrationTarget(binding, args["record"] as ByteArray, "0".repeat(64))
            } catch (error: JournalProblem) { return error.code == "journal_illegal_transition" }
            return false
        }
        if (call.method == "normalPreflightRejected") {
            val normal = object : ContextWrapper(targetContext) {
                override fun getPackageName() = "com.example.chantipoint"
            }
            try { requireMigrationValidationNamespace(normal.packageName) }
            catch (error: JournalProblem) { return error.code == "journal_illegal_transition" }
            return false
        }
        if (call.method == "legacyFixture") {
            val legacyRoot = targetContext.filesDir.canonicalFile
            val source = File(legacyRoot, legacyBasename(binding))
            val suffix = args["suffix"] as? String ?: ""
            check(suffix in setOf("", ".tmp", ".bak"))
            val target = File(legacyRoot, source.name + suffix)
            when (args["operation"] as String) {
                "write" -> FileOutputStream(target).use { it.write(args["bytes"] as ByteArray); it.fd.sync() }
                "delete" -> if (legacyRoot.list()?.contains(target.name) == true) check(target.delete())
                "directory" -> check(target.mkdir())
                "symlink" -> Os.symlink(File(targetContext.cacheDir, "fictional-migration-outside").path, target.path)
                "unreadable" -> Os.chmod(target.path, 0)
                "readable" -> Os.chmod(target.path, 384)
                "unrelated" -> File(legacyRoot, "journal_unrelated_fixture").writeText("fictional")
                else -> error("Unknown legacy fixture")
            }
            return null
        }
        val base = File(root(), "slot_${binding.slotId}.bin")
        val artifacts = listOf(base, File(base.path + ".new"), File(base.path + ".bak"))
        fun syncRoot() {
            val descriptor = Os.open(root().path, OsConstants.O_RDONLY, 0)
            try { Os.fsync(descriptor) } finally { Os.close(descriptor) }
        }
        when (call.method) {
            "fingerprint" -> {
                val digest = MessageDigest.getInstance("SHA-256")
                for (file in artifacts) {
                    digest.update(if (file.exists()) 1.toByte() else 0.toByte())
                    if (file.exists()) digest.update(file.readBytes())
                }
                return digest.digest().joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
            }
            "presence" -> return mapOf("main" to base.exists(), "new" to artifacts[1].exists(), "bak" to artifacts[2].exists())
            "removeFixtureSidecar" -> {
                val kind = args["kind"] as String
                check(kind in setOf("new", "bak"))
                check(File(base.path + ".$kind").delete())
            }
            "sidecar", "replaceMain" -> {
                val kind = if (call.method == "replaceMain") "main" else args["kind"] as String
                check(kind in setOf("main", "new", "bak"))
                val target = if (kind == "main") base else File(base.path + ".$kind")
                val record = args["record"] as ByteArray
                check(record.size <= RECORD_LIMIT)
                val key = keyStore().getKey(alias(), null) as SecretKey
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key)
                val aadSlot = if (args["wrong_aad"] == true) "0".repeat(64) else binding.slotId
                cipher.updateAAD(framed("chantipoint-journal-aad-v1", listOf(targetContext.packageName, aadSlot), listOf(1, 1)))
                val ciphertext = cipher.doFinal(record)
                val buffer = ByteArrayOutputStream()
                DataOutputStream(buffer).use {
                    it.writeInt(0x43504a52); it.writeInt(1); it.writeInt(1)
                    it.writeInt(ciphertext.size); it.write(cipher.iv); it.write(ciphertext)
                }
                val bytes = buffer.toByteArray()
                FileOutputStream(target).use { it.write(bytes); it.fd.sync() }
                syncRoot()
                return !base.readBytes().contentEquals(bytes)
            }
            "orphan" -> {
                val kind = args["kind"] as String
                check(kind in setOf("new", "bak"))
                check(base.renameTo(File(base.path + ".$kind")))
                syncRoot()
            }
            "partialWrite" -> {
                // Leave the actual platform AtomicFile transaction unfinished.
                AtomicFile(base).startWrite().use { it.write(byteArrayOf(0x43, 0x50, 0x4a)); it.fd.sync() }
                syncRoot()
            }
            "tamper" -> {
                val bytes = base.readBytes()
                bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
                FileOutputStream(base).use { it.write(bytes); it.fd.sync() }
                syncRoot()
            }
            else -> error("Unknown fixture operation")
        }
        return null
    }
}
