package com.example.chantipoint.journal

import android.content.Context
import android.util.AtomicFile
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference

/** Controls exist ONLY in the isolated test APK; never in the production channel. */
internal class SessionNoteRuntimeFixtures(private val context: Context) {
    private val fault = AtomicReference<String?>(null)
    val io = JournalVerificationIo { stage ->
        val expected = fault.get()
        if (expected == stage && fault.compareAndSet(expected, null)) problem("journal_sync_failure")
    }
    private fun root() = File(context.noBackupFilesDir.canonicalFile, "session_note_operations").also {
        check(context.packageName == "com.example.chantipoint.journalvalidation")
        check(it.canonicalFile == it.absoluteFile)
    }
    private fun keys() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun alias(binding: SlotBinding) = "${context.packageName}.session_note_operations.${binding.slotId}.aes.v1"
    fun clear() {
        for (file in root().listFiles().orEmpty()) {
            check(file.isFile && file.canonicalFile == file.absoluteFile)
            check(file.name == "journal.lock" || Regex("^slot_[0-9a-f]{64}\\.bin(?:\\.new|\\.bak)?$").matches(file.name))
            check(file.delete())
        }
        val store = keys()
        val prefix = "${context.packageName}.session_note_operations."
        val names = store.aliases().toList().filter { it.startsWith(prefix) && it.endsWith(".aes.v1") }
        for (name in names) store.deleteEntry(name)
    }
    fun handle(call: MethodCall): Any? {
        val args = call.arguments as Map<*, *>
        val binding = SlotBinding.parse(args["binding"])
        val base = File(root(), "slot_${binding.slotId}.bin")
        return when (call.method) {
            "noteFault" -> { fault.set(args["stage"] as String); null }
            "noteTamper" -> {
                val bytes = base.readBytes(); bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
                FileOutputStream(base).use { it.write(bytes); it.fd.sync() }; null
            }
            "noteInterruptedWrite" -> {
                AtomicFile(base).startWrite().use { it.write(byteArrayOf(1,2,3)); it.flush(); it.fd.sync() }; null
            }
            "noteDeleteKey" -> { keys().deleteEntry(alias(binding)); null }
            "noteRemoveBase" -> { check(base.delete()); null }
            "noteSnapshot" -> {
                val digest = MessageDigest.getInstance("SHA-256")
                for (file in root().listFiles().orEmpty().filter { it.name.startsWith(base.name) }.sortedBy { it.name }) {
                    digest.update(file.name.toByteArray(Charsets.UTF_8)); digest.update(file.readBytes())
                }
                digest.digest().joinToString("") { (it.toInt() and 255).toString(16).padStart(2,'0') }
            }
            "noteAtRest" -> {
                val note = (args["note"] as String).toByteArray(Charsets.UTF_8)
                val bytes = base.readBytes()
                val contains = (0..(bytes.size - note.size)).any { start -> note.indices.all { bytes[start+it] == note[it] } }
                mapOf("no_backup" to (root().parentFile == context.noBackupFilesDir.canonicalFile),
                    "plaintext_found" to contains,
                    "separate_directory" to (root().name != "attendance_journal"))
            }
            else -> error("Unknown fictional note fixture control")
        }
    }
}
