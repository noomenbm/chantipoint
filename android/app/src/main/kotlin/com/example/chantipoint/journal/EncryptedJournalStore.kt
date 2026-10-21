package com.example.chantipoint.journal

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Injection is internal; fault controls are supplied only by androidTest. */
internal fun interface JournalVerificationIo {
    fun checkpoint(stage: String)
}

/** Isolated storage. Nothing instantiates it until an explicit channel call. */
internal class EncryptedJournalStore(context: Context, private val noteBinding: SlotBinding? = null,
    private val noteIo: JournalVerificationIo = JournalVerificationIo { }) {
    private val context = context.applicationContext
    private val packageName = context.packageName
    private val alias = if (noteBinding == null) "$packageName.attendance_journal.aes.v1"
        else "$packageName.session_note_operations.${noteBinding.slotId}.aes.v1"
    private val random = SecureRandom()

    companion object {
        private val processLock = Any()
        private val filePattern = Regex("^slot_[0-9a-f]{64}\\.bin(?:\\.new|\\.bak)?$")
        private const val CONTAINER_VERSION = 1
        private const val KEY_VERSION = 1
        private const val TAG_BYTES = 16
        private const val NONCE_BYTES = 12
        private const val HEADER_BYTES = 28
        private const val CONTAINER_LIMIT = RECORD_LIMIT + TAG_BYTES + HEADER_BYTES
        private const val MAX_SLOTS = 32
        private const val LOCK_NAME = "journal.lock"
        private const val MAGIC = 0x43504a52 // ASCII CPJR
    }

    fun read(binding: SlotBinding): ByteArray? = locked { root, files ->
        // Key absence must not conceal ciphertext in a different owner's slot.
        val key = existingKey(keyArtifacts(files).isNotEmpty())
        readStored(root, binding, files, key)
    }

    fun inspectRecovery(binding: SlotBinding): RecoveryInspection = locked { root, files ->
        requireAttendance()
        inspectRecovery(root, binding, files, existingKey(files.isNotEmpty()))
    }

    /** General verification-only barrier, separate from all migration APIs.
     * Dart validates the COMPLETE schema before calling. Native independently
     * checks envelope/binding and authenticates and compares ALL original bytes.
     * Never invokes AtomicFile.openRead or normalizes/deletes sidecars.
     */
    fun verifyRecord(binding: SlotBinding, expected: ByteArray,
                     io: JournalVerificationIo = JournalVerificationIo { }): ByteArray {
        inspectRecord(expected, binding)
        return locked { root, files ->
            val key = existingKey(keyArtifacts(files).isNotEmpty())
            val actual = readStored(root, binding, files, key) ?: problem("journal_command_conflict")
            if (!MessageDigest.isEqual(actual, expected)) problem("journal_revision_conflict")
            io.checkpoint("record_file_sync")
            try { FileInputStream(File(root, filename(binding))).use { it.fd.sync() } }
            catch (_: Exception) { problem("journal_sync_failure") }
            io.checkpoint("record_directory_sync")
            syncDirectory(root)
            io.checkpoint("record_readback")
            val verified = readStored(root, binding, inspectFiles(root), key) ?: problem("journal_storage_failure")
            if (!MessageDigest.isEqual(verified, expected)) problem("journal_revision_conflict")
            verified
        }
    }

    /** Fresh barrier and optional validation-only cleanup, all under the SAME locks. */
    fun verifyMigrationTarget(binding: SlotBinding, expected: ByteArray, sourceSnapshot: String? = null,
                              io: LegacyMigrationIo = RealLegacyMigrationIo): ByteArray {
        requireAttendance()
        // Gate BEFORE locks, directory creation, key access or source inspection.
        if (sourceSnapshot != null) requireMigrationValidationNamespace(packageName)
        return locked { root, files ->
            val target = PendingLegacyTarget.inspect(expected, binding)
            val key = existingKey(files.isNotEmpty())
            val actual = readStored(root, binding, files, key) ?: problem("journal_command_conflict")
            if (!MessageDigest.isEqual(actual, expected)) problem("journal_revision_conflict")
            io.checkpoint("target_sync")
            try { FileInputStream(File(root, filename(binding))).use { it.fd.sync() } }
            catch (_: Exception) { problem("journal_sync_failure") }
            syncDirectory(root)
            val verified = readStored(root, binding, inspectFiles(root), key) ?: problem("journal_storage_failure")
            if (!MessageDigest.isEqual(verified, expected)) problem("journal_revision_conflict")
            if (sourceSnapshot != null) LegacySourceFiles(context).cleanup(binding, target, sourceSnapshot, io)
            // Return only the mechanically verified original record; no journal transition.
            verified
        }
    }

    /** Separate, verification-only completed-record barrier. No source deletion. */
    fun verifyCompletedMigration(binding: SlotBinding, expected: ByteArray,
                                 io: LegacyMigrationIo = RealLegacyMigrationIo): ByteArray {
        requireAttendance()
        requireMigrationValidationNamespace(packageName)
        requireCompletedMigration(expected, binding)
        return locked { root, files ->
            val key = existingKey(files.isNotEmpty())
            val actual = readStored(root, binding, files, key) ?: problem("journal_command_conflict")
            if (!MessageDigest.isEqual(actual, expected)) problem("journal_revision_conflict")
            io.checkpoint("completed_sync")
            try { FileInputStream(File(root, filename(binding))).use { it.fd.sync() } }
            catch (_: Exception) { problem("journal_sync_failure") }
            syncDirectory(root)
            val verified = readStored(root, binding, inspectFiles(root), key) ?: problem("journal_storage_failure")
            if (!MessageDigest.isEqual(verified, expected)) problem("journal_revision_conflict")
            verified
        }
    }

    fun normalizeRecovery(binding: SlotBinding, snapshot: String, validatedRecord: ByteArray): ByteArray =
        locked { root, files ->
            requireAttendance()
            val key = existingKey(files.isNotEmpty())
            // Reopen and authenticate every candidate under the same locks as cleanup.
            val inspection = inspectRecovery(root, binding, files, key)
            if (inspection.snapshot != snapshot) problem("journal_revision_conflict")
            val candidates = inspection.candidates
            if (candidates.size != 2 || candidates.none { it.kind == "main" }) problem("journal_unreadable")
            JournalHeader.inspect(validatedRecord, binding)
            if (candidates.any { !MessageDigest.isEqual(it.record, validatedRecord) }) problem("journal_unreadable")
            val main = File(root, filename(binding))
            // Persist the retained bytes AND name before removing the only redundant copy.
            try { RandomAccessFile(main, "rw").use { it.fd.sync() } }
            catch (_: Exception) { problem("journal_sync_failure") }
            syncDirectory(root)
            val sidecar = candidates.single { it.kind != "main" }
            val suffix = if (sidecar.kind == "new") ".new" else ".bak"
            if (!File(root, filename(binding) + suffix).delete()) problem("journal_storage_failure")
            syncDirectory(root)
            val readback = readStored(root, binding, inspectFiles(root), key) ?: problem("journal_storage_failure")
            if (!MessageDigest.isEqual(readback, validatedRecord)) problem("journal_storage_failure")
            readback
        }

    private fun inspectRecovery(root: File, binding: SlotBinding, files: List<File>, key: SecretKey?): RecoveryInspection {
        val name = filename(binding)
        val candidates = listOf("main" to name, "new" to "$name.new", "bak" to "$name.bak").mapNotNull { (kind, path) ->
            val file = files.singleOrNull { it.name == path } ?: return@mapNotNull null
            if (key == null) problem("journal_missing_key")
            val container = readContainer(file)
            val record = decrypt(container, binding, key)
            JournalHeader.inspect(record, binding)
            RecoveryCandidate(kind, container, record)
        }
        return RecoveryInspection(packageName, binding, candidates)
    }

    fun compareAndSwap(binding: SlotBinding, expectedRevision: Long, expectedKey: String?, replacement: ByteArray): Long =
        locked { root, files ->
            val next = inspectRecord(replacement, binding)
            val key = existingKey(keyArtifacts(files).isNotEmpty())
            val currentBytes = readStored(root, binding, files, key)
            val current = currentBytes?.let { inspectRecord(it, binding) }
            if ((current?.revision ?: 0L) != expectedRevision || current?.key != expectedKey ||
                expectedRevision >= MAX_REVISION || next.revision != expectedRevision + 1) {
                problem("journal_revision_conflict")
            }
            protectImmutableContent(current, next)
            val name = filename(binding)
            if (current == null && files.map { it.name.removeSuffix(".new").removeSuffix(".bak") }.toSet().size >= MAX_SLOTS) {
                problem("journal_storage_failure")
            }
            // Inspection above is under the SAME process/file lock as key creation.
            // Never regenerate a missing key over any base, backup or new file.
            val writeKey = key ?: createKey(keyArtifacts(files))
            val encrypted = encrypt(replacement, binding, writeKey)
            if (noteBinding != null) noteIo.checkpoint("note_before_write")
            val atomic = AtomicFile(File(root, name))
            // use closes again even if finishWrite swallowed a close failure.
            // It preserves the original exception if closing also fails.
            atomic.startWrite().use { stream ->
                stream.write(encrypted)
                stream.flush()
                try { stream.fd.sync() } catch (_: Exception) { problem("journal_sync_failure") }
                // finishWrite can LOG failed sync/rename without throwing. It is
                // not our success boundary. Do not roll back after this call.
                atomic.finishWrite(stream)
                if (noteBinding != null) noteIo.checkpoint("note_after_finish")
                syncDirectory(root)
                if (noteBinding != null) noteIo.checkpoint("note_readback")
                val after = inspectFiles(root)
                val readback = readStored(root, binding, after, writeKey) ?: problem("journal_storage_failure")
                val header = inspectRecord(readback, binding)
                if (header.revision != next.revision || !MessageDigest.isEqual(readback, replacement)) {
                    problem("journal_storage_failure")
                }
                next.revision
            }
        }

    private fun protectImmutableContent(current: StorageHeader?, next: StorageHeader) {
        if (noteBinding != null) { protectNoteTransition(current, next); return }
        if (current == null || current.command == null) return
        if (next.command == null) {
            // Canonical-state/consumption attestations stay in the Dart core.
            if (current.phase != "confirmed" || next.phase != "empty") problem("journal_illegal_transition")
        } else {
            if (current.command != next.command) problem("journal_command_conflict")
            if (current.confirmation != null && current.confirmation != next.confirmation) {
                problem("journal_command_conflict")
            }
        }
        if (current.phase == "blocked") problem("journal_illegal_transition")
    }

    private fun filename(binding: SlotBinding) = "slot_${binding.slotId}.bin"

    private fun requireAttendance() { if (noteBinding != null) problem("journal_unsupported_format") }
    private fun inspectRecord(bytes: ByteArray, binding: SlotBinding): StorageHeader {
        if (noteBinding == null) return StorageHeader.attendance(bytes, binding)
        if (noteBinding != binding) problem("journal_identity_mismatch")
        return StorageHeader.note(bytes, binding)
    }
    private fun keyArtifacts(files: List<File>): List<File> = if (noteBinding == null) files else
        files.filter { it.name.removeSuffix(".new").removeSuffix(".bak") == filename(noteBinding) }

    private fun <T> locked(work: (File, List<File>) -> T): T = synchronized(processLock) {
        val parent = context.noBackupFilesDir.canonicalFile
        val directory = File(parent, if (noteBinding == null) "attendance_journal" else "session_note_operations")
        if (!directory.exists()) {
            if (!directory.mkdir() && !directory.isDirectory) problem("journal_storage_failure")
        }
        if (!directory.isDirectory || directory.canonicalFile != directory.absoluteFile) problem("journal_unreadable")
        val lock = File(directory, LOCK_NAME)
        if (lock.canonicalFile != lock.absoluteFile) problem("journal_unreadable")
        RandomAccessFile(lock, "rw").use { access ->
            access.channel.use { channel ->
                channel.lock().use {
                    // Repeat after any earlier failed initialization, not only
                    // mkdir: an existing directory may still need parent sync.
                    syncDirectory(parent.parentFile ?: problem("journal_sync_failure"))
                    syncDirectory(parent)
                    work(directory, inspectFiles(directory))
                }
            }
        }
    }

    private fun inspectFiles(directory: File): List<File> {
        val entries = directory.listFiles() ?: problem("journal_unreadable")
        if (entries.size > MAX_SLOTS * 3 + 1) problem("journal_unreadable")
        return entries.filter { it.name != LOCK_NAME }.onEach { file ->
            if (!filePattern.matches(file.name) || !file.isFile || file.canonicalFile != file.absoluteFile) {
                problem("journal_unreadable")
            }
        }
    }

    private fun readStored(root: File, binding: SlotBinding, files: List<File>, key: SecretKey?): ByteArray? {
        if (noteBinding != null && noteBinding != binding) problem("journal_identity_mismatch")
        val name = filename(binding)
        // AtomicFile.openRead may delete .new or overwrite base with .bak. Do
        // not allow implicit deletion/promotion of ambiguous recovery evidence.
        if (files.any { it.name == "$name.new" || it.name == "$name.bak" }) problem("journal_recovery_required")
        if (files.none { it.name == name }) return null
        if (key == null) problem("journal_missing_key")
        val plaintext = decrypt(readContainer(File(root, name)), binding, key)
        inspectRecord(plaintext, binding)
        return plaintext
    }

    private fun readContainer(file: File): ByteArray = FileInputStream(file).use { input ->
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (output.size() + read > CONTAINER_LIMIT) problem("journal_corrupt")
            output.write(buffer, 0, read)
        }
        output.toByteArray()
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun existingKey(hasArtifacts: Boolean): SecretKey? {
        val store = keyStore()
        if (!store.containsAlias(alias)) {
            if (hasArtifacts) problem("journal_missing_key")
            return null
        }
        // Per-binding note key is also a presence marker. Lost ciphertext or a
        // failed first initialization cannot silently become a fresh empty slot.
        if (noteBinding != null && !hasArtifacts) problem("journal_unreadable")
        // Invalid/unrecoverable keys are handled by typed channel errors; no reset.
        return store.getKey(alias, null) as? SecretKey ?: problem("journal_invalidated_key")
    }

    private fun createKey(files: List<File>): SecretKey {
        if (files.isNotEmpty()) problem("journal_missing_key")
        // No auth requirement, biometric invalidation policy or StrongBox demand.
        // Hardware backing is intentionally not assumed.
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(false)
            .build())
        return generator.generateKey()
    }

    private fun aad(binding: SlotBinding): ByteArray = framed(
        if (noteBinding == null) "chantipoint-journal-aad-v1" else "chantipoint-session-note-aad-v1",
        listOf(packageName, binding.slotId), listOf(CONTAINER_VERSION, KEY_VERSION),
    )

    private fun encrypt(plaintext: ByteArray, binding: SlotBinding, key: SecretKey): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // Keystore generates the fresh IV; its provider owns the entropy source
        // and may ignore the supplied JCA SecureRandom. Supplying our own IV
        // would require disabling randomized-encryption enforcement.
        cipher.init(Cipher.ENCRYPT_MODE, key, random)
        val nonce = cipher.iv ?: problem("journal_native_failure")
        val parameters = cipher.parameters.getParameterSpec(GCMParameterSpec::class.java)
        if (nonce.size != NONCE_BYTES || parameters.tLen != TAG_BYTES * 8) problem("journal_native_failure")
        cipher.updateAAD(aad(binding))
        val ciphertext = cipher.doFinal(plaintext)
        if (ciphertext.size != plaintext.size + TAG_BYTES) problem("journal_native_failure")
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).use { out ->
            out.writeInt(MAGIC)
            out.writeInt(CONTAINER_VERSION)
            out.writeInt(KEY_VERSION)
            out.writeInt(ciphertext.size)
            out.write(nonce)
            out.write(ciphertext)
        }
        return buffer.toByteArray()
    }

    private fun decrypt(container: ByteArray, binding: SlotBinding, key: SecretKey): ByteArray {
        if (container.size < HEADER_BYTES + TAG_BYTES || container.size > CONTAINER_LIMIT) problem("journal_corrupt")
        val input = DataInputStream(ByteArrayInputStream(container))
        if (input.readInt() != MAGIC) problem("journal_corrupt")
        if (input.readInt() != CONTAINER_VERSION || input.readInt() != KEY_VERSION) problem("journal_unsupported_container")
        val size = input.readInt()
        if (size < TAG_BYTES || size > RECORD_LIMIT + TAG_BYTES || container.size != HEADER_BYTES + size) {
            problem("journal_corrupt")
        }
        val nonce = ByteArray(NONCE_BYTES).also { input.readFully(it) }
        val ciphertext = ByteArray(size).also { input.readFully(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BYTES * 8, nonce))
        cipher.updateAAD(aad(binding))
        return cipher.doFinal(ciphertext)
    }

    private fun syncDirectory(directory: File) {
        try {
            // O_DIRECTORY is not public in this project's API-36 android.jar.
            // Open read-only, verify the descriptor is a directory, then fsync.
            val descriptor = Os.open(directory.path, OsConstants.O_RDONLY, 0)
            try {
                if (!OsConstants.S_ISDIR(Os.fstat(descriptor).st_mode)) problem("journal_sync_failure")
                Os.fsync(descriptor)
            } finally { Os.close(descriptor) }
        } catch (_: Exception) {
            // Unsupported directory fsync is a failure, never weakened success.
            problem("journal_sync_failure")
        }
    }
}
