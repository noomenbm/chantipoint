package com.example.chantipoint.journal

import android.util.JsonReader
import android.util.JsonToken
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest

/** Stable codes only. Never attach input, paths, plaintext or provider exceptions. */
internal class JournalProblem(val code: String) : Exception()

internal fun problem(code: String): Nothing = throw JournalProblem(code)
internal const val RECORD_LIMIT = 64 * 1024
internal const val MAX_REVISION = 9007199254740991L

internal fun exactFields(map: Map<*, *>, fields: Set<String>) {
    if (map.size != fields.size || map.keys.toSet() != fields) problem("journal_corrupt")
}

internal fun text(value: Any?, max: Int = 256): String {
    val result = value as? String ?: problem("journal_corrupt")
    if (result.isEmpty() || result.codePointCount(0, result.length) > max || result.contains('\u0000')) {
        problem("journal_corrupt")
    }
    var i = 0
    while (i < result.length) {
        val c = result[i++]
        if (Character.isHighSurrogate(c)) {
            if (i == result.length || !Character.isLowSurrogate(result[i++])) problem("journal_corrupt")
        } else if (Character.isLowSurrogate(c)) problem("journal_corrupt")
    }
    return result
}

internal fun channelInteger(value: Any?): Long {
    val number = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> problem("journal_corrupt")
    }
    if (number !in 0..MAX_REVISION) problem("journal_corrupt")
    return number
}

private val bindingFields = linkedSetOf(
    "environment_id", "supabase_base_url", "auth_user_id", "company_id", "employee_profile_id",
)
private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

internal data class SlotBinding(val values: List<String>) {
    companion object {
        fun parse(value: Any?): SlotBinding {
            val map = value as? Map<*, *> ?: problem("journal_corrupt")
            exactFields(map, bindingFields)
            val fields = bindingFields.map { name ->
                text(map[name], when (name) { "environment_id" -> 128; "supabase_base_url" -> 512; else -> 36 })
            }
            for (id in fields.drop(2)) if (!uuid.matches(id)) problem("journal_corrupt")
            // URL/protocol rules belong to the Dart codec. Never normalize here:
            // exact UTF-8 field values define this slot, including Unicode URLs.
            return SlotBinding(fields)
        }
    }

    // Fixed field order, length-prefixed UTF-8; independent of JSON escaping.
    val slotId: String get() = MessageDigest.getInstance("SHA-256")
        .digest(framed("chantipoint-binding-v1", values))
        .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
}

internal fun framed(domain: String, values: List<String>, versions: List<Int> = emptyList()): ByteArray {
    val buffer = ByteArrayOutputStream()
    DataOutputStream(buffer).use { out ->
        for (value in listOf(domain) + values) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            out.writeInt(bytes.size)
            out.write(bytes)
        }
        for (version in versions) out.writeInt(version)
    }
    return buffer.toByteArray()
}

/** Routing/CAS metadata only. Dart retains full schema and transition authority. */
internal data class JournalHeader(
    val revision: Long,
    val key: String?,
    val phase: String,
    val command: Map<*, *>?,
    val confirmation: Any?,
) {
    companion object {
        fun inspect(bytes: ByteArray, binding: SlotBinding): JournalHeader {
            if (bytes.size > RECORD_LIMIT) problem("journal_corrupt")
            val decoded = try {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: Exception) { problem("journal_corrupt") }
            val root = try {
                StrictEnvelopeJson(decoded).read() as? Map<*, *> ?: problem("journal_corrupt")
            } catch (error: JournalProblem) { throw error }
            catch (_: Exception) { problem("journal_corrupt") }
            exactFields(root, setOf("journal_format", "revision", "binding", "phase", "command",
                "write_may_have_started", "confirmation", "block", "migration"))
            if (integer(root["journal_format"]) != 2L) problem("journal_unsupported_format")
            if (SlotBinding.parse(root["binding"]) != binding) problem("journal_identity_mismatch")
            val revision = integer(root["revision"])
            if (revision < 1) problem("journal_corrupt")
            val phase = text(root["phase"])
            if (phase !in setOf("empty", "prepared", "may_have_sent", "uncertain", "confirmed", "blocked")) {
                problem("journal_unsupported_format")
            }
            if (root["write_may_have_started"] !is Boolean) problem("journal_corrupt")
            val command = root["command"]?.let { it as? Map<*, *> ?: problem("journal_corrupt") }
            if ((phase == "empty") != (command == null)) problem("journal_corrupt")
            val key = command?.let {
                exactFields(it, setOf("protocol", "operation", "idempotency_key", "parameters_json"))
                text(it["protocol"])
                text(it["operation"])
                val parameters = it["parameters_json"] as? String ?: problem("journal_corrupt")
                if (parameters.toByteArray(Charsets.UTF_8).size > 16 * 1024) problem("journal_corrupt")
                text(it["idempotency_key"], 160)
            }
            return JournalHeader(revision, key, phase, command, root["confirmation"])
        }

        private fun integer(value: Any?): Long {
            val token = (value as? NumberToken)?.raw ?: problem("journal_corrupt")
            if (!Regex("^(0|[1-9][0-9]{0,15})$").matches(token)) problem("journal_corrupt")
            return channelInteger(token.toLong())
        }
    }
}

private data class NumberToken(val raw: String)

/** JsonReader handles lexical parsing; duplicate names and allocation are bounded.
 * Request/receipt JSON strings stay opaque: Kotlin does not recreate Dart codecs.
 */
private class StrictEnvelopeJson(text: String) {
    private val reader = JsonReader(StringReader(text)).apply { isLenient = false }
    private var nodes = 0
    fun read(): Any? = reader.use {
        val value = value(0)
        if (reader.peek() != JsonToken.END_DOCUMENT) problem("journal_corrupt")
        value
    }
    private fun value(depth: Int): Any? {
        if (depth > 12 || ++nodes > 2048) problem("journal_corrupt")
        return when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> {
                reader.beginObject()
                val map = linkedMapOf<String, Any?>()
                while (reader.hasNext()) {
                    val name = reader.nextName()
                    if (map.size >= 64 || map.containsKey(name)) problem("journal_corrupt")
                    map[name] = value(depth + 1)
                }
                reader.endObject()
                map
            }
            JsonToken.BEGIN_ARRAY -> {
                reader.beginArray()
                val list = mutableListOf<Any?>()
                while (reader.hasNext()) {
                    if (list.size >= 64) problem("journal_corrupt")
                    list.add(value(depth + 1))
                }
                reader.endArray()
                list
            }
            JsonToken.STRING -> reader.nextString()
            JsonToken.NUMBER -> NumberToken(reader.nextString())
            JsonToken.BOOLEAN -> reader.nextBoolean()
            JsonToken.NULL -> { reader.nextNull(); null }
            else -> problem("journal_corrupt")
        }
    }
}
