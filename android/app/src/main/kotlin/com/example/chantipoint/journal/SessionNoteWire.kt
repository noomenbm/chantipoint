package com.example.chantipoint.journal

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/** Mechanical storage metadata only; no conversion into attendance commands. */
internal data class StorageHeader(val revision: Long, val key: String?, val phase: String,
    val command: Map<*, *>?, val confirmation: Any?, val envelope: Map<*, *>) {
    companion object {
        fun attendance(bytes: ByteArray, binding: SlotBinding): StorageHeader {
            val h = JournalHeader.inspect(bytes, binding)
            return StorageHeader(h.revision, h.key, h.phase, h.command, h.confirmation, h.envelope)
        }
        fun note(bytes: ByteArray, binding: SlotBinding): StorageHeader {
            if (bytes.size > RECORD_LIMIT) problem("journal_corrupt")
            val root = try {
                val decoded = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
                StrictEnvelopeJson(decoded).read() as? Map<*, *> ?: problem("journal_corrupt")
            } catch (e: JournalProblem) { throw e }
            catch (_: Exception) { problem("journal_corrupt") }
            exactFields(root, setOf("note_format", "revision", "binding", "phase", "command", "receipt_json", "checkout"))
            if (number(root["note_format"]) != 1L) problem("journal_unsupported_format")
            if (SlotBinding.parse(root["binding"]) != binding) problem("journal_identity_mismatch")
            val revision = number(root["revision"])
            if (revision < 1) problem("journal_corrupt")
            val phase = text(root["phase"])
            if (phase !in setOf("empty", "pending", "terminal", "checkout")) problem("journal_corrupt")
            val command = root["command"]?.let { it as? Map<*, *> ?: problem("journal_corrupt") }
            val key = command?.let {
                val fields = setOf("captured_generation", "parameters_json")
                exactFields(it, if (it.containsKey("note_protocol")) fields + "note_protocol" else fields)
                if (it.containsKey("note_protocol") && number(it["note_protocol"]) != 2L) problem("journal_unsupported_format")
                if (number(it["captured_generation"]) < 1) problem("journal_corrupt")
                val payload = text(it["parameters_json"], 16 * 1024)
                if (payload.toByteArray(Charsets.UTF_8).size > 16 * 1024) problem("journal_corrupt")
                val p = StrictEnvelopeJson(payload).read() as? Map<*, *> ?: problem("journal_corrupt")
                exactFields(p, setOf("p_work_session_id", "p_operation_key", "p_note_action", "p_employee_note", "p_replay_only"))
                text(p["p_work_session_id"], 36)
                val operationKey = text(p["p_operation_key"], 160)
                if (operationKey.codePointCount(0, operationKey.length) < 8 ||
                    operationKey.startsWith(" ") || operationKey.endsWith(" ") || p["p_replay_only"] != false) problem("journal_corrupt")
                if (p["p_note_action"] == "replace") {
                    val note = p["p_employee_note"] as? String ?: problem("journal_corrupt")
                    if (note.isNotEmpty()) text(note, 1000)
                } else if (p["p_note_action"] != "clear" || p["p_employee_note"] != null) problem("journal_corrupt")
                operationKey
            }
            val receipt = root["receipt_json"]?.let { text(it, 16 * 1024) }
            val checkout = root["checkout"]?.let {
                val map = it as? Map<*, *> ?: problem("journal_corrupt")
                exactFields(map, setOf("session_id", "idempotency_key", "captured_generation", "command_sha256"))
                text(map["session_id"], 36); text(map["idempotency_key"], 160)
                if (!Regex("^[0-9a-f]{64}$").matches(text(map["command_sha256"], 64))) problem("journal_corrupt")
                if (number(map["captured_generation"]) < 1) problem("journal_corrupt")
                map
            }
            if ((phase == "checkout") != (checkout != null) ||
                (phase == "empty" && (command != null || receipt != null)) ||
                (phase == "pending" && (command == null || receipt != null)) ||
                (phase == "terminal" && (command == null || receipt == null)) ||
                (phase == "checkout" && (command == null) != (receipt == null))) problem("journal_corrupt")
            return StorageHeader(revision, key, phase, command, receipt, root)
        }
        private fun number(value: Any?): Long {
            val token = (value as? NumberToken)?.raw ?: problem("journal_corrupt")
            if (!Regex("^(0|[1-9][0-9]{0,15})$").matches(token)) problem("journal_corrupt")
            return channelInteger(token.toLong())
        }
    }
}

internal fun protectNoteTransition(current: StorageHeader?, next: StorageHeader) {
    if (current == null) {
        if (next.phase !in setOf("pending", "checkout")) problem("journal_illegal_transition")
        return
    }
    if (current.phase == "pending") {
        if (next.phase != "terminal" || current.command != next.command) problem("journal_command_conflict")
    } else if (current.phase == "checkout") {
        if (next.phase != (if (current.command == null) "empty" else "terminal") ||
            current.command != next.command || current.confirmation != next.confirmation) problem("journal_command_conflict")
    } else if (next.phase == "checkout") {
        if (current.command != next.command || current.confirmation != next.confirmation) problem("journal_command_conflict")
    } else if (next.phase != "pending" || (current.key != null && current.key == next.key)) {
        problem("journal_illegal_transition")
    }
}
