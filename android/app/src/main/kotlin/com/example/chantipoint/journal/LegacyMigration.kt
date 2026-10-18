package com.example.chantipoint.journal

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.charset.CodingErrorAction
import java.nio.ByteBuffer
import java.security.MessageDigest

/** Ordinary IO seam; fault controls exist only in the instrumentation source set. */
internal interface LegacyMigrationIo {
    fun checkpoint(stage: String) {}
    fun deleteSource(file: File): Boolean = file.delete()
}
internal object RealLegacyMigrationIo : LegacyMigrationIo

internal fun requireMigrationValidationNamespace(packageName: String) {
    if (packageName != "com.example.chantipoint.journalvalidation") problem("journal_illegal_transition")
}

internal fun legacyOwner(binding: SlotBinding) = "${binding.values[3]}:${binding.values[4]}"
internal fun legacyBasename(binding: SlotBinding) = "attendance_" +
    Base64.encodeToString(legacyOwner(binding).toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) + ".json"
internal fun sha256Hex(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
    .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

internal fun migrationObject(bytes: ByteArray): Map<*, *> {
    if (bytes.size > RECORD_LIMIT) problem("journal_corrupt")
    return try {
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        StrictEnvelopeJson(text).read() as? Map<*, *> ?: problem("journal_corrupt")
    } catch (error: JournalProblem) { throw error }
    catch (_: Exception) { problem("journal_corrupt") }
}

/** Narrow mechanical checks; the Dart codec remains the full state-machine authority. */
internal class PendingLegacyTarget(val header: JournalHeader, val metadata: Map<*, *>) {
    companion object {
        fun inspect(record: ByteArray, binding: SlotBinding): PendingLegacyTarget {
            val header = JournalHeader.inspect(record, binding)
            if (header.phase !in setOf("uncertain", "confirmed") || header.envelope["block"] != null ||
                header.envelope["write_may_have_started"] != true) problem("journal_illegal_transition")
            val metadata = header.envelope["migration"] as? Map<*, *> ?: problem("journal_illegal_transition")
            exactFields(metadata, setOf("source_basename", "source_sha256", "legacy_owner", "binding_approval_ref", "plaintext_cleanup"))
            if (metadata["plaintext_cleanup"] != "pending") problem("journal_illegal_transition")
            if (metadata["source_basename"] != legacyBasename(binding) || metadata["legacy_owner"] != legacyOwner(binding)) {
                problem("journal_identity_mismatch")
            }
            if (!Regex("^[0-9a-f]{64}$").matches(text(metadata["source_sha256"], 64))) problem("journal_corrupt")
            text(metadata["binding_approval_ref"])
            val command = header.command ?: problem("journal_corrupt")
            if (command["protocol"] != "legacy-v1" || command["operation"] !in setOf("check_in", "check_out")) {
                problem("journal_illegal_transition")
            }
            if ((header.phase == "confirmed") != (header.confirmation != null)) problem("journal_corrupt")
            return PendingLegacyTarget(header, metadata)
        }
    }

    fun checkSource(binding: SlotBinding, bytes: ByteArray) {
        if (sha256Hex(bytes) != metadata["source_sha256"]) problem("journal_command_conflict")
        val source = migrationObject(bytes)
        exactFields(source, setOf("version", "kind", "payload", "owner"))
        if ((source["version"] as? NumberToken)?.raw != "1") problem("journal_unsupported_format")
        if (source["owner"] != legacyOwner(binding)) problem("journal_identity_mismatch")
        val command = header.command!!
        val kind = if (command["operation"] == "check_in") "checkIn" else "checkOut"
        val parameters = migrationObject((command["parameters_json"] as String).toByteArray(Charsets.UTF_8))
        if (source["kind"] != kind || source["payload"] != parameters || parameters["p_idempotency_key"] != header.key) {
            problem("journal_command_conflict")
        }
    }
}

internal data class LegacyArtifact(val suffix: String, val bytes: ByteArray)
internal class LegacyInspection(val basename: String, val source: ByteArray?, val artifacts: List<LegacyArtifact>,
                                packageName: String, binding: SlotBinding) {
    val snapshot: String = run {
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).use { out ->
            out.write(framed("chantipoint-legacy-source-v1", listOf(packageName, binding.slotId, basename)))
            out.writeBoolean(source != null)
            if (source != null) { out.writeInt(source.size); out.write(source) }
            out.writeInt(artifacts.size)
            for (artifact in artifacts) {
                out.write(framed("artifact", listOf(artifact.suffix)))
                out.writeInt(artifact.bytes.size); out.write(artifact.bytes)
            }
        }
        sha256Hex(buffer.toByteArray())
    }
    fun toWire(binding: SlotBinding): Map<String, Any?> = mapOf(
        "inspection_version" to 1, "binding" to binding.toWire(), "snapshot" to snapshot,
        "basename" to basename, "source" to source,
        "artifacts" to artifacts.map { mapOf("suffix" to it.suffix, "bytes" to it.bytes) },
    )
}

/** Never creates keys, promotes sidecars, writes files, or opens a caller path. */
internal class LegacySourceFiles(private val context: Context) {
    private fun root(): File = context.filesDir.canonicalFile.also {
        if (!OsConstants.S_ISDIR(Os.lstat(it.path).st_mode)) problem("journal_unreadable")
    }

    fun inspect(binding: SlotBinding): LegacyInspection {
        try {
            val root = root()
            val basename = legacyBasename(binding)
            fun names() = (root.list() ?: problem("journal_unreadable"))
                .filter { it == basename || it.startsWith("$basename.") }.sorted().also {
                    if (it.size > 9) problem("journal_unreadable")
                }
            val before = names()
            var source: ByteArray? = null
            val artifacts = mutableListOf<LegacyArtifact>()
            var total = 0
            for (name in before) {
                val file = File(root, name)
                if (file.canonicalFile != file.absoluteFile) problem("journal_unreadable")
                val stat = Os.lstat(file.path)
                if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink != 1L) problem("journal_unreadable")
                val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
                // Android's FileInputStream(fd) borrows fd; use closes only the
                // stream. Own the Os.open result through construction/read/check
                // failures, and never let a close failure replace the primary one.
                var failure: Throwable? = null
                val bytes = try { FileInputStream(fd).use { input ->
                    val opened = Os.fstat(input.fd)
                    if (!OsConstants.S_ISREG(opened.st_mode) || opened.st_ino != stat.st_ino || opened.st_dev != stat.st_dev) {
                        problem("journal_revision_conflict")
                    }
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(4096)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > RECORD_LIMIT) problem("journal_corrupt")
                        output.write(buffer, 0, count)
                    }
                    val after = Os.lstat(file.path)
                    if (after.st_ino != stat.st_ino || after.st_dev != stat.st_dev || !OsConstants.S_ISREG(after.st_mode) ||
                        after.st_size != output.size().toLong()) problem("journal_revision_conflict")
                    output.toByteArray()
                } } catch (error: Throwable) {
                    failure = error
                    throw error
                } finally {
                    try { Os.close(fd) }
                    catch (_: Exception) {
                        val closeFailure = JournalProblem("journal_unreadable")
                        if (failure == null) throw closeFailure
                        failure.addSuppressed(closeFailure)
                    }
                }
                if (name == basename) source = bytes else {
                    val suffix = name.removePrefix(basename)
                    text(suffix, 64)
                    artifacts.add(LegacyArtifact(suffix, bytes))
                }
            }
            if (before != names()) problem("journal_revision_conflict")
            return LegacyInspection(basename, source, artifacts, context.packageName, binding)
        } catch (error: JournalProblem) { throw error }
        catch (_: Exception) { problem("journal_unreadable") }
    }

    /** Caller holds journal locks; this does NOT fence the legacy Dart writer. */
    fun cleanup(binding: SlotBinding, target: PendingLegacyTarget, expectedSnapshot: String, io: LegacyMigrationIo) {
        requireMigrationValidationNamespace(context.packageName)
        val before = inspect(binding)
        if (before.snapshot != expectedSnapshot) problem("journal_revision_conflict")
        if (before.artifacts.isNotEmpty()) problem("journal_unreadable")
        before.source?.let { target.checkSource(binding, it) }
        // Recheck immediately before unlink; future integration still needs writer retirement.
        if (inspect(binding).snapshot != expectedSnapshot) problem("journal_revision_conflict")
        if (before.source != null) {
            if (!io.deleteSource(File(root(), before.basename))) problem("journal_storage_failure")
        }
        io.checkpoint("source_sync")
        syncDirectory()
        val after = inspect(binding)
        if (after.source != null || after.artifacts.isNotEmpty()) problem("journal_revision_conflict")
    }

    private fun syncDirectory() {
        try {
            val sourceRoot = root()
            for (directory in listOf(sourceRoot.parentFile ?: problem("journal_sync_failure"), sourceRoot)) {
                val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
                try {
                    if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) problem("journal_sync_failure")
                    Os.fsync(fd)
                } finally { Os.close(fd) }
            }
        } catch (_: Exception) { problem("journal_sync_failure") }
    }
}
