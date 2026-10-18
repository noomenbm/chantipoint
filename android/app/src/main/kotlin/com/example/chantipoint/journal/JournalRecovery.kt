package com.example.chantipoint.journal

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.security.MessageDigest

internal data class RecoveryCandidate(val kind: String, val container: ByteArray, val record: ByteArray)

/** Content snapshot, not a freshness/commit claim. No filenames cross the channel. */
internal class RecoveryInspection(packageName: String, binding: SlotBinding, val candidates: List<RecoveryCandidate>) {
    val snapshot: String = run {
        val buffer = ByteArrayOutputStream()
        DataOutputStream(buffer).use { out ->
            out.write(framed("chantipoint-recovery-v1", listOf(packageName, binding.slotId)))
            for (kind in listOf("main", "new", "bak")) {
                val candidate = candidates.singleOrNull { it.kind == kind }
                out.writeBoolean(candidate != null)
                if (candidate != null) {
                    out.writeInt(candidate.container.size)
                    out.write(candidate.container)
                }
            }
        }
        MessageDigest.getInstance("SHA-256").digest(buffer.toByteArray())
            .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
    }

    fun toWire(): Map<String, Any> = mapOf(
        "recovery_version" to 1,
        "snapshot" to snapshot,
        "candidates" to candidates.map { mapOf("kind" to it.kind, "record" to it.record) },
    )
}
