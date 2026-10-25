package com.example.chantipoint.journal

import android.content.Context
import android.content.pm.ApplicationInfo
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.*
import java.security.*
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec

/** Development ONLY; not an enterprise enrollment or a server maintenance lease.
 * No secrets/notes/coordinates in the signed metadata. The private installation
 * key is non-exportable, metadata is in noBackupFilesDir, signatures authenticate
 * every byte. Never auto-enroll, delete, normalize or rebind anything.
 */
internal class DevelopmentEnrollment(private val context: Context,
    private val io: JournalVerificationIo = JournalVerificationIo { }) {
    private val alias = "${context.packageName}.development_attendance.install.v1"
    private val root get() = File(context.noBackupFilesDir.canonicalFile, "development_attendance")
    private val approval get() = File(root, "approval.bin")
    companion object { private val monitor = Any() }

    private fun supported() {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
            context.packageName !in setOf("com.example.chantipoint", "com.example.chantipoint.journalvalidation", "com.example.chantipoint.enrollmentvalidation")) {
            problem("journal_illegal_transition")
        }
    }
    private fun keys() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun entry(): KeyStore.PrivateKeyEntry =
        keys().getEntry(alias, null) as? KeyStore.PrivateKeyEntry ?: problem("journal_missing_key")
    private fun installId(): String {
        val key = entry()
        // Prove the retained private key is usable, not just a certificate alias.
        val challenge = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val signed = Signature.getInstance("SHA256withECDSA").run { initSign(key.privateKey); update(challenge); sign() }
        if (!Signature.getInstance("SHA256withECDSA").run {
                initVerify(key.certificate.publicKey); update(challenge); verify(signed)
            }) problem("journal_invalidated_key")
        return sha256Hex(key.certificate.publicKey.encoded)
    }
    private fun existingRoot(): List<File> {
        if (!root.exists()) problem("journal_unreadable")
        if (!root.isDirectory || root.canonicalFile != root.absoluteFile) problem("journal_unreadable")
        return (root.listFiles() ?: problem("journal_unreadable")).toList().onEach {
            if (it.name !in setOf("enrollment.lock", "approval.bin", "approval.bin.new", "approval.bin.bak") ||
                !it.isFile || it.canonicalFile != it.absoluteFile) problem("journal_unreadable")
        }
    }
    private fun sync(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) problem("journal_sync_failure")
            Os.fsync(fd)
        } finally { Os.close(fd) }
    }
    private fun <T> locked(create: Boolean = false, work: () -> T): T = synchronized(monitor) {
        supported()
        if (create && !root.exists()) {
            if (!root.mkdir()) problem("journal_storage_failure")
        }
        existingRoot()
        RandomAccessFile(File(root, "enrollment.lock"), "rw").use { file ->
            file.channel.use { channel -> channel.lock().use {
                sync(root.parentFile.parentFile ?: problem("journal_sync_failure"))
                sync(root.parentFile); sync(root)
                work()
            } }
        }
    }

    /** Bounded descriptor-owned read, no symlink following or pathname stream. */
    private fun read(file: File): ByteArray {
        val before = Os.lstat(file.path)
        if (!OsConstants.S_ISREG(before.st_mode) || before.st_nlink != 1L) problem("journal_unreadable")
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK, 0)
        var primary: Throwable? = null
        try {
            val opened = Os.fstat(fd)
            if (opened.st_ino != before.st_ino || opened.st_dev != before.st_dev ||
                !OsConstants.S_ISREG(opened.st_mode)) problem("journal_revision_conflict")
            val bytes = FileInputStream(fd).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > RECORD_LIMIT) problem("journal_corrupt")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            val after = Os.lstat(file.path)
            if (after.st_ino != before.st_ino || after.st_dev != before.st_dev ||
                after.st_size != bytes.size.toLong() || after.st_mtime != before.st_mtime ||
                !OsConstants.S_ISREG(after.st_mode)) problem("journal_revision_conflict")
            return bytes
        } catch (failure: Throwable) { primary = failure; throw failure }
        finally {
            try { Os.close(fd) } catch (_: Exception) {
                val failure = JournalProblem("journal_unreadable")
                if (primary == null) throw failure else primary.addSuppressed(failure)
            }
        }
    }

    private fun files(directory: File): List<File> {
        val stat = try { Os.lstat(directory.path) } catch (error: android.system.ErrnoException) {
            if (error.errno == OsConstants.ENOENT) return emptyList() // Observation, NEVER approval.
            throw error
        }
        if (!OsConstants.S_ISDIR(stat.st_mode) || directory.canonicalFile != directory.absoluteFile) problem("journal_unreadable")
        val list = directory.listFiles()?.toList() ?: problem("journal_unreadable")
        if (list.size > 100) problem("journal_unreadable")
        return list.onEach {
            if (!it.isFile || it.canonicalFile != it.absoluteFile) problem("journal_unreadable")
        }
    }
    private fun legacy() = files(context.filesDir.canonicalFile).filter { it.name.startsWith("attendance_") }
    private fun attendance() = files(File(context.noBackupFilesDir.canonicalFile, "attendance_journal"))
        .filter { it.name != "journal.lock" }
    private fun notes() = files(File(context.noBackupFilesDir.canonicalFile, "session_note_operations"))
        .filter { it.name != "journal.lock" }
    private fun hasNoteKey() = keys().aliases().toList().any { it.startsWith("${context.packageName}.session_note_operations.") }
    private fun ownName(binding: SlotBinding) = "slot_${binding.slotId}.bin"
    private fun inventory(binding: SlotBinding, allowOwn: Boolean): String {
        val old = legacy(); val note = notes(); val target = attendance()
        if (old.isNotEmpty() || note.isNotEmpty() || hasNoteKey() ||
            target.any { !allowOwn || it.name != ownName(binding) }) problem("journal_unreadable")
        // Digest certifies only this measured empty namespace, not past history.
        return sha256Hex(framed("development-clean-checkpoint-v1", listOf(context.packageName, binding.slotId)))
    }

    /** Practical read-only metadata inventory; no payloads, paths or identifiers. */
    fun inspect(): Map<String, Any> {
        supported()
        return mapOf("legacy_artifacts" to legacy().size, "attendance_artifacts" to attendance().size,
            "note_artifacts" to notes().size, "note_key_present" to hasNoteKey(),
            "retirement_present" to (keys().containsAlias(alias) || markerPresent()),
            "absence_establishes_provenance" to false)
    }
    private fun markerPresent(): Boolean = try { Os.lstat(root.path); true }
            catch (error: android.system.ErrnoException) {
                if (error.errno != OsConstants.ENOENT) problem("journal_unreadable")
                false
            }
    fun requireOldWriterAllowed() {
        // Applies also in release builds. Cannot fence already submitted work or
        // older APKs that do not execute this check; server retirement is separate.
        if (keys().containsAlias(alias) || markerPresent()) problem("journal_illegal_transition")
    }

    /** Explicit operator tooling only. Normal app calls neither prepare nor install.
     * Creating the installation key irreversibly retires old writers in this APK.
     */
    private fun preparationCheckpoint(binding: SlotBinding, approvalRef: String, maintenanceRef: String): String {
        supported()
        text(approvalRef, 128); text(maintenanceRef, 128)
        if (!Regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$").matches(binding.values[0])) problem("journal_identity_mismatch")
        if (root.exists() && existingRoot().any { it.name != "enrollment.lock" }) problem("journal_unreadable")
        if (keys().containsAlias("${context.packageName}.attendance_journal.aes.v1")) problem("journal_unreadable")
        return inventory(binding, false)
    }
    fun prepare(binding: SlotBinding, approvalRef: String, maintenanceRef: String): ByteArray = synchronized(monitor) {
        // Failed eligibility checks must not manufacture a retirement marker.
        // Existing markers are never removed, even after a later failure.
        preparationCheckpoint(binding, approvalRef, maintenanceRef)
        locked(true) {
        val checkpoint = preparationCheckpoint(binding, approvalRef, maintenanceRef)
        if (!keys().containsAlias(alias)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256).build())
            }.generateKeyPair()
        }
        JSONObject(linkedMapOf("enrollment_version" to 1, "install_id" to installId(),
            "package_id" to context.packageName, "binding" to JSONObject(binding.toWire()),
            "inventory_digest" to checkpoint, "approval_ref" to text(approvalRef, 128),
            "maintenance_ref" to text(maintenanceRef, 128), "policy" to "certified-clean-development-v1"))
            .toString().toByteArray(Charsets.UTF_8)
        }
    }
    private fun validate(payload: ByteArray, signature: ByteArray, publicKey: String, binding: SlotBinding): Map<*, *> {
        if (payload.size > 4096 || signature.size > 128 || publicKey.length > 512) problem("journal_corrupt")
        val trusted = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(Base64.decode(publicKey, Base64.NO_WRAP)))
        // Exactly P-256; arbitrary algorithms/curves cannot widen the contract.
        val ec = trusted as? java.security.interfaces.ECPublicKey ?: problem("journal_corrupt")
        val params = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
            .getParameterSpec(java.security.spec.ECParameterSpec::class.java)
        if (ec.params.order != params.order || ec.params.curve != params.curve || ec.params.generator != params.generator) problem("journal_corrupt")
        if (!Signature.getInstance("SHA256withECDSA").run { initVerify(trusted); update(payload); verify(signature) }) {
            problem("journal_authentication_failed")
        }
        val data = migrationObject(payload)
        exactFields(data, setOf("enrollment_version", "install_id", "package_id", "binding", "inventory_digest",
            "approval_ref", "maintenance_ref", "policy"))
        if ((data["enrollment_version"] as? NumberToken)?.raw != "1" ||
            data["install_id"] != installId() || data["package_id"] != context.packageName ||
            SlotBinding.parse(data["binding"]) != binding || data["policy"] != "certified-clean-development-v1" ||
            !Regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$").matches(binding.values[0])) problem("journal_identity_mismatch")
        text(data["approval_ref"], 128); text(data["maintenance_ref"], 128)
        if (data["inventory_digest"] != inventory(binding, true)) problem("journal_revision_conflict")
        return data
    }
    private fun unpack(bytes: ByteArray): Pair<ByteArray, ByteArray> = DataInputStream(ByteArrayInputStream(bytes)).use {
        val size = it.readInt()
        if (size !in 1..4096) problem("journal_corrupt")
        val payload = ByteArray(size).also(it::readFully)
        val count = it.readInt()
        if (count !in 1..128) problem("journal_corrupt")
        val signature = ByteArray(count).also(it::readFully)
        if (it.read() != -1) problem("journal_corrupt")
        payload to signature
    }
    fun verify(binding: SlotBinding, publicKey: String): Map<String, Any> = locked {
        if (existingRoot().map { it.name }.toSet() != setOf("enrollment.lock", "approval.bin")) problem("journal_unreadable")
        val (payload, signature) = unpack(read(approval))
        val data = validate(payload, signature, publicKey, binding)
        if (attendance().map { it.name } != listOf(ownName(binding))) problem("journal_unreadable")
        // Never normalize sidecars or treat a missing required slot as empty.
        if (EncryptedJournalStore(context).read(binding) == null) problem("journal_unreadable")
        mapOf("status" to "approved", "binding" to binding.toWire(), "approval_ref" to data["approval_ref"]!!)
    }

    fun install(binding: SlotBinding, payload: ByteArray, signature: ByteArray, publicKey: String, empty: ByteArray) = locked {
        validate(payload, signature, publicKey, binding)
        val header = JournalHeader.inspect(empty, binding)
        if (header.phase != "empty" || header.revision != 1L || header.envelope["migration"] != null ||
            header.envelope["write_may_have_started"] != false || header.confirmation != null || header.envelope["block"] != null) {
            problem("journal_illegal_transition")
        }
        val encoded = ByteArrayOutputStream().also { output -> DataOutputStream(output).use {
            it.writeInt(payload.size); it.write(payload); it.writeInt(signature.size); it.write(signature)
        } }.toByteArray()
        val artifacts = existingRoot().filter { it.name != "enrollment.lock" }
        if (artifacts.isNotEmpty()) {
            // Lost response retry only, exact original approval; never replacement.
            if (artifacts.map { it.name } != listOf("approval.bin") || !MessageDigest.isEqual(read(approval), encoded)) {
                problem("journal_revision_conflict")
            }
            if (attendance().map { it.name } != listOf(ownName(binding)) || storeRead(binding) == null) problem("journal_unreadable")
            FileInputStream(approval).use { it.fd.sync() }; sync(root)
            return@locked
        }
        val store = EncryptedJournalStore(context)
        if (attendance().isEmpty()) {
            // A key without its required record is not a fresh namespace. Even
            // failed initialization stays blocked; never hide lost evidence.
            if (keys().containsAlias("${context.packageName}.attendance_journal.aes.v1")) problem("journal_unreadable")
            store.compareAndSwap(binding, 0, null, empty)
        }
        // Interrupted after target initialization: only exact original empty bytes.
        store.verifyRecord(binding, empty)
        io.checkpoint("enrollment_after_target")
        AtomicFile(approval).let { atomic -> atomic.startWrite().use { stream ->
            stream.write(encoded); stream.flush(); stream.fd.sync()
            io.checkpoint("enrollment_before_finish")
            atomic.finishWrite(stream)
            io.checkpoint("enrollment_after_finish")
            sync(root)
            io.checkpoint("enrollment_after_sync")
            if (existingRoot().any { it.name.endsWith(".new") || it.name.endsWith(".bak") } ||
                !MessageDigest.isEqual(read(approval), encoded)) problem("journal_storage_failure")
        } }
        inventory(binding, true)
    }
    private fun storeRead(binding: SlotBinding) = EncryptedJournalStore(context).read(binding)
}
