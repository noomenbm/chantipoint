package com.example.chantipoint.journal

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/** Fictional fixtures ONLY, dependency-free Android runtime runner. */
class DevelopmentEnrollmentInstrumentation : Instrumentation() {
    private var phase = "fresh"
    private var passed = 0
    private val failed = mutableListOf<String>()
    private val binding = SlotBinding(listOf("00000000-0000-4000-8000-000000000099", "https://fixture.invalid",
        "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003"))
    private val root get() = targetContext.noBackupFilesDir.canonicalFile
    private val enrollmentFile get() = File(root, "development_attendance/approval.bin")
    private val operatorFile get() = File(targetContext.filesDir, "fixture-operator.spki")
    private val store get() = DevelopmentEnrollment(targetContext)
    private fun empty() = JSONObject(linkedMapOf("journal_format" to 2, "revision" to 1,
        "binding" to JSONObject(binding.toWire()), "phase" to "empty", "command" to JSONObject.NULL,
        "write_may_have_started" to false, "confirmation" to JSONObject.NULL, "block" to JSONObject.NULL,
        "migration" to JSONObject.NULL)).toString().toByteArray()
    private fun pendingNote(v2: Boolean = true): ByteArray {
        val parameters = JSONObject(linkedMapOf("p_work_session_id" to "00000000-0000-4000-8000-000000000044",
            "p_operation_key" to "fictional-note-v2-key", "p_note_action" to "clear",
            "p_employee_note" to JSONObject.NULL, "p_replay_only" to false))
        val command = JSONObject(linkedMapOf("captured_generation" to 1, "parameters_json" to parameters.toString()))
        if (v2) command.put("note_protocol", 2)
        return JSONObject(linkedMapOf("note_format" to 1, "revision" to 1,
            "binding" to JSONObject(binding.toWire()), "phase" to "pending", "command" to command,
            "receipt_json" to JSONObject.NULL, "checkout" to JSONObject.NULL)).toString().toByteArray()
    }
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); phase = arguments?.getString("phase") ?: "fresh"; start() }
    private fun resetFixtures() {
        check(targetContext.packageName == "com.example.chantipoint.enrollmentvalidation")
        for (name in listOf("development_attendance", "attendance_journal", "session_note_operations")) {
            val fixture = File(root, name)
            // FileTreeWalk skips dangling symlinks. Unlink only the isolated
            // fixture entry, never follow it and never weaken production checks.
            if (java.nio.file.Files.isSymbolicLink(fixture.toPath())) check(fixture.delete())
            else check(fixture.deleteRecursively())
        }
        targetContext.filesDir.listFiles()?.filter { it.name.startsWith("attendance_") || it.name.startsWith("fixture-") }?.forEach { check(it.delete()) }
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        keys.aliases().toList().filter { it.startsWith("${targetContext.packageName}.") }.forEach(keys::deleteEntry)
    }
    private fun reject(action: () -> Unit) {
        try { action() } catch (_: Exception) { return }
        error("Expected denial")
    }
    private fun test(name: String, action: () -> Unit) {
        try { action(); passed++ } catch (_: Throwable) { failed.add(name) }
    }
    private data class Approval(val payload: ByteArray, val signature: ByteArray, val publicKey: String)
    private fun prepared(): Approval {
        val payload = store.prepare(binding, "fictional-clean-certificate", "fictional-maintenance-approval")
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val signature = Signature.getInstance("SHA256withECDSA").run { initSign(pair.private); update(payload); sign() }
        val publicKey = Base64.encodeToString(pair.public.encoded, Base64.NO_WRAP)
        operatorFile.writeText(publicKey)
        return Approval(payload, signature, publicKey)
    }
    private fun installed(): Approval = prepared().also { install(it) }
    private fun install(a: Approval, instance: DevelopmentEnrollment = store) = instance.install(binding, a.payload, a.signature, a.publicKey, empty())
    private fun verify(a: Approval) { check(store.verify(binding, a.publicKey)["status"] == "approved") }
    override fun onStart() {
        try {
            check(targetContext.packageName == "com.example.chantipoint.enrollmentvalidation")
            if (phase == "fresh") {
                fun fresh(name: String, action: () -> Unit) = test(name) { resetFixtures(); action() }
                fresh("default-denial") { reject { store.verify(binding, "missing") }; check(store.inspect()["absence_establishes_provenance"] == false) }
                fresh("valid-and-recreated-store") { val a = installed(); verify(a); check(DevelopmentEnrollment(targetContext).verify(binding, a.publicKey)["status"] == "approved") }
                fresh("preparation-retires-old-writer") { store.requireOldWriterAllowed(); prepared(); reject { store.requireOldWriterAllowed() }; reject { store.verify(binding, operatorFile.readText()) } }
                fresh("legacy-sidecar-blocks") { File(targetContext.filesDir, "attendance_unknown.json.tmp").writeText("fictional"); reject { prepared() }; check(File(targetContext.filesDir, "attendance_unknown.json.tmp").exists()); store.requireOldWriterAllowed(); check(store.inspect()["retirement_present"] == false) }
                fresh("other-owner-note-blocks") { File(root, "session_note_operations").mkdir(); File(root, "session_note_operations/unknown.bin").writeText("fictional"); reject { prepared() }; store.requireOldWriterAllowed() }
                fresh("existing-v2-blocks-enrollment") { EncryptedJournalStore(targetContext).compareAndSwap(binding, 0, null, empty()); reject { prepared() }; store.requireOldWriterAllowed() }
                fresh("invalid-approval-ref-does-not-retire") { reject { store.prepare(binding, "", "fictional") }; store.requireOldWriterAllowed(); check(store.inspect()["retirement_present"] == false) }
                fresh("invalid-epoch-does-not-retire") { reject { store.prepare(SlotBinding(binding.values.toMutableList().also { it[0] = "untrusted-label" }), "fictional", "fictional") }; store.requireOldWriterAllowed(); check(store.inspect()["retirement_present"] == false) }
                fresh("broken-marker-still-retires") { android.system.Os.symlink(File(root, "missing-marker-target").path, File(root, "development_attendance").path); reject { store.requireOldWriterAllowed() }; check(java.nio.file.Files.isSymbolicLink(File(root, "development_attendance").toPath())) }
                fresh("tampered-approval") { val a = installed(); val b = enrollmentFile.readBytes(); b[b.lastIndex] = (b.last().toInt() xor 1).toByte(); enrollmentFile.writeBytes(b); reject { verify(a) } }
                fresh("wrong-owner-epoch") { val a = installed(); for (index in listOf(0, 1, 2, 3, 4)) { val values = binding.values.toMutableList(); values[index] = if (index == 1) "https://other.invalid" else "00000000-0000-4000-8000-000000000088"; reject { store.verify(SlotBinding(values), a.publicKey) } } }
                fresh("replacement-key") { val a = installed(); val other = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair(); reject { store.verify(binding, Base64.encodeToString(other.public.encoded, Base64.NO_WRAP)) } }
                fresh("missing-install-key") { val a = installed(); KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("${targetContext.packageName}.development_attendance.install.v1") }; reject { verify(a) }; check(enrollmentFile.exists()) }
                fresh("missing-required-attendance-slot") { val a = installed(); check(File(root, "attendance_journal/slot_${binding.slotId}.bin").delete()); reject { verify(a) } }
                fresh("ambiguous-attendance-sidecar") { val a = installed(); val file = File(root, "attendance_journal/slot_${binding.slotId}.bin"); file.copyTo(File(file.path + ".new")); reject { verify(a) }; check(File(file.path + ".new").exists()) }
                fresh("changed-source-after-request") { val a = prepared(); File(targetContext.filesDir, "attendance_new.json").writeText("fictional"); reject { install(a) } }
                fresh("interrupted-after-target-retry") { val a = prepared(); reject { install(a, DevelopmentEnrollment(targetContext, JournalVerificationIo { if (it == "enrollment_after_target") error("fixture") })) }; reject { verify(a) }; install(a); verify(a) }
                fresh("interrupted-atomic-write-blocked") { val a = prepared(); reject { install(a, DevelopmentEnrollment(targetContext, JournalVerificationIo { if (it == "enrollment_before_finish") error("fixture") })) }; reject { verify(a) }; reject { install(a) }; check(File(enrollmentFile.path + ".new").exists()) }
                fresh("lost-install-response-retry") { val a = prepared(); reject { install(a, DevelopmentEnrollment(targetContext, JournalVerificationIo { if (it == "enrollment_after_sync") error("fixture") })) }; verify(a); install(a); verify(a) }
                fresh("approval-replacement-blocked") { val a = installed(); val b = a.copy(payload = a.payload + byteArrayOf(32)); reject { install(b) }; verify(a) }
                fresh("own-v2-note-admitted") { val a = installed(); EncryptedJournalStore(targetContext, binding).compareAndSwap(binding, 0, null, pendingNote()); verify(a); reject { install(a) } }
                fresh("legacy-note-still-blocked") { val a = installed(); EncryptedJournalStore(targetContext, binding).compareAndSwap(binding, 0, null, pendingNote(false)); reject { verify(a) } }
                fresh("unknown-note-still-blocked") { val a = installed(); File(root, "session_note_operations").mkdir(); File(root, "session_note_operations/unknown.bin").writeText("fictional"); reject { verify(a) } }
                fresh("note-sidecar-still-blocked") { val a = installed(); EncryptedJournalStore(targetContext, binding).compareAndSwap(binding, 0, null, pendingNote()); val f = File(root, "session_note_operations/slot_${binding.slotId}.bin"); f.copyTo(File(f.path + ".new")); reject { verify(a) }; check(File(f.path + ".new").exists()) }
                fresh("missing-note-record-still-blocked") { val a = installed(); EncryptedJournalStore(targetContext, binding).compareAndSwap(binding, 0, null, pendingNote()); check(File(root, "session_note_operations/slot_${binding.slotId}.bin").delete()); reject { verify(a) } }
                fresh("note-missing-key-still-blocked") { val a = installed(); EncryptedJournalStore(targetContext, binding).compareAndSwap(binding, 0, null, pendingNote()); KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry("${targetContext.packageName}.session_note_operations.${binding.slotId}.aes.v1") }; reject { verify(a) } }
                fresh("restart-fixture") { val a = installed(); EncryptedJournalStore(targetContext, binding).compareAndSwap(binding, 0, null, pendingNote()); verify(a); File(targetContext.filesDir, "fixture-original.bin").writeBytes(enrollmentFile.readBytes()) }
            } else if (phase == "restart") {
                val publicKey = operatorFile.readText()
                test("restart-authorized") { check(store.verify(binding, publicKey)["status"] == "approved") }
                test("restart-exact-original-approval") { check(enrollmentFile.readBytes().contentEquals(File(targetContext.filesDir, "fixture-original.bin").readBytes())) }
                test("restart-retirement") { reject { store.requireOldWriterAllowed() } }
                test("restart-no-rebinding") { reject { store.verify(SlotBinding(binding.values.toMutableList().also { it[0] = "00000000-0000-4000-8000-000000000088" }), publicKey) } }
            } else error("phase")
        } catch (_: Throwable) { failed.add("harness") }
        val report = Bundle().apply { putString("stream", "Enrollment $phase: $passed passed; ${failed.size} failed. ${failed.joinToString()}") }
        finish(if (failed.isEmpty()) Activity.RESULT_OK else Activity.RESULT_CANCELED, report)
    }
}
