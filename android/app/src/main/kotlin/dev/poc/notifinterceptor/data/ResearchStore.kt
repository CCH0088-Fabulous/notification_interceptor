package dev.poc.notifinterceptor.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import dev.poc.notifinterceptor.domain.ResearchPolicy
import dev.poc.notifinterceptor.domain.ResearchUploadProtocol
import java.io.File
import java.util.UUID

/** Bounded, private research ledger. It never reads history.jsonl. */
class ResearchStore(context: Context) : SQLiteOpenHelper(
    context, File(context.noBackupFilesDir, "research.sqlite").absolutePath, null, 1,
) {
    data class Observation(val bucket: Long, val offset: Int, val cohort: String, val existing: Boolean)

    override fun onConfigure(db: SQLiteDatabase) {
        val pageSize = db.rawQuery("PRAGMA page_size", null).use { it.moveToFirst(); it.getLong(0) }
        db.rawQuery("PRAGMA max_page_count=${ResearchPolicy.DATABASE_MAX_BYTES / pageSize}", null).use { it.moveToFirst() }
        db.rawQuery("PRAGMA secure_delete=ON", null).use { it.moveToFirst() }
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE events(id TEXT PRIMARY KEY, at_ms INTEGER NOT NULL, bucket INTEGER NOT NULL, offset_minutes INTEGER NOT NULL, cohort TEXT NOT NULL, existing_flag INTEGER NOT NULL, metrics TEXT NOT NULL)")
        db.execSQL("CREATE INDEX events_at ON events(at_ms)")
        db.execSQL("CREATE TABLE hours(bucket INTEGER NOT NULL, offset_minutes INTEGER NOT NULL, cohort TEXT NOT NULL, revision INTEGER NOT NULL, acked_revision INTEGER NOT NULL DEFAULT 0, metrics TEXT NOT NULL, PRIMARY KEY(bucket, offset_minutes, cohort))")
        db.execSQL("CREATE TABLE outbox(id TEXT PRIMARY KEY, created_ms INTEGER NOT NULL, generation INTEGER NOT NULL, payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)")
        db.execSQL("CREATE TABLE profiles(id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL, bucket INTEGER NOT NULL, data TEXT NOT NULL)")
        db.execSQL("CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        error("不支持的研究数据库版本")
    }

    @Synchronized
    fun record(id: String, at: Long, bucket: Long, offset: Int, cohort: String,
               metrics: Map<String, Long>, existing: Boolean = false): Boolean = transaction { db ->
        val safe = ResearchPolicy.validateMetrics(metrics)
        if (safe.isEmpty()) return@transaction false
        val inserted = db.insertWithOnConflict("events", null, ContentValues().apply {
            put("id", id); put("at_ms", at); put("bucket", bucket); put("offset_minutes", offset)
            put("cohort", cohort); put("existing_flag", if (existing) 1 else 0); put("metrics", Json.stringify(safe))
        }, SQLiteDatabase.CONFLICT_IGNORE)
        if (inserted == -1L) return@transaction false
        val args = arrayOf(bucket.toString(), offset.toString(), cohort)
        var revision = 0L
        var acked = 0L
        val totals = mutableMapOf<String, Long>()
        db.rawQuery("SELECT revision,acked_revision,metrics FROM hours WHERE bucket=? AND offset_minutes=? AND cohort=?", args).use { c ->
            if (c.moveToFirst()) {
                revision = c.getLong(0); acked = c.getLong(1)
                Json.parseObject(c.getString(2))?.forEach { (k, v) -> totals[k] = (v as Number).toLong() }
            }
        }
        safe.forEach { (key, value) -> totals[key] = (totals[key] ?: 0) + value }
        db.insertWithOnConflict("hours", null, ContentValues().apply {
            put("bucket", bucket); put("offset_minutes", offset); put("cohort", cohort)
            put("revision", revision + 1); put("acked_revision", acked); put("metrics", Json.stringify(totals))
        }, SQLiteDatabase.CONFLICT_REPLACE)
        prune(db, at)
        true
    }

    @Synchronized
    fun observation(id: String): Observation? = readableDatabase.rawQuery(
        "SELECT bucket,offset_minutes,cohort,existing_flag FROM events WHERE id=?", arrayOf(id),
    ).use { c -> if (c.moveToFirst()) Observation(c.getLong(0), c.getInt(1), c.getString(2), c.getInt(3) == 1) else null }

    @Synchronized
    fun setProfiles(structures: List<Map<String, Any>>, now: Long) = transaction { db ->
        val data = Json.stringify(structures)
        val old = db.rawQuery("SELECT data FROM profiles WHERE id=1", null).use { c -> if (c.moveToFirst()) c.getString(0) else null }
        if (old == data) return@transaction
        val revision = meta(db, "profileRevision").toLongOrNull()?.plus(1) ?: 1L
        putMeta(db, "profileRevision", revision.toString())
        db.insertWithOnConflict("profiles", null, ContentValues().apply {
            put("id", 1); put("revision", revision)
            put("bucket", Math.floorDiv(now, ResearchPolicy.HOUR_MS) * ResearchPolicy.HOUR_MS)
            put("data", data)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    @Synchronized
    fun invalidateQueue(removeProfiles: Boolean) = transaction { db ->
        db.delete("outbox", null, null)
        if (removeProfiles) db.delete("profiles", null, null)
    }

    @Synchronized
    fun clear() = transaction { db ->
        listOf("events", "hours", "outbox", "profiles", "metadata").forEach { db.delete(it, null, null) }
    }

    @Synchronized
    fun prepare(settings: ResearchSettings, appVersion: String, sdk: Int, now: Long): Map<String, Any?>? = transaction { db ->
        prune(db, now)
        db.rawQuery("SELECT payload,generation FROM outbox ORDER BY created_ms LIMIT 1", null).use { c ->
            if (c.moveToFirst() && c.getLong(1) == settings.revision) {
                return@transaction Json.parseObject(c.getString(0)) ?: error("待发批次损坏")
            }
        }
        db.delete("outbox", null, null)
        val hours = mutableListOf<Map<String, Any?>>()
        db.rawQuery("SELECT bucket,offset_minutes,cohort,revision,metrics FROM hours WHERE revision>acked_revision ORDER BY bucket LIMIT 96", null).use { c ->
            while (c.moveToNext()) hours.add(mapOf(
                "bucketStart" to c.getLong(0), "utcOffsetMinutes" to c.getInt(1),
                "cohort" to c.getString(2), "revision" to c.getLong(3),
                "metrics" to (Json.parseObject(c.getString(4)) ?: error("小时汇总损坏")),
            ))
        }
        var profile: Map<String, Any?>? = null
        if (settings.ruleStructures) {
            val acked = meta(db, "profileAcked").toLongOrNull() ?: 0L
            db.rawQuery("SELECT revision,bucket,data FROM profiles WHERE id=1 AND revision>?", arrayOf(acked.toString())).use { c ->
                if (c.moveToFirst()) profile = mapOf("revision" to c.getLong(0), "capturedAtBucket" to c.getLong(1), "structures" to Json.parse(c.getString(2)))
            }
        }
        if (hours.isEmpty() && profile == null) return@transaction null
        val id = UUID.randomUUID().toString()
        val payload = mapOf(
            "schemaVersion" to 1, "kind" to ResearchUploadProtocol.KIND, "batchId" to id,
            "participantId" to settings.participantId, "createdAt" to now,
            "consent" to mapOf("version" to ResearchPolicy.DISCLOSURE_VERSION, "acceptedAt" to settings.consentAt,
                "ruleStructures" to settings.ruleStructures, "configurationRevision" to settings.revision),
            "app" to mapOf("version" to appVersion, "androidApi" to sdk),
            "scope" to mapOf("unit" to "processing_event", "historyIndependent" to true,
                "foregroundAndCoverage" to "observed_only", "retentionDays" to 30),
            "hours" to hours, "ruleSnapshot" to profile,
            "coverage" to mapOf("retentionDroppedEvents" to (meta(db, "droppedEvents").toLongOrNull() ?: 0),
                "retentionDroppedHours" to (meta(db, "droppedHours").toLongOrNull() ?: 0),
                "retentionDroppedBatches" to (meta(db, "droppedBatches").toLongOrNull() ?: 0)),
        )
        val encoded = Json.stringify(payload)
        require(encoded.toByteArray(Charsets.UTF_8).size <= ResearchUploadProtocol.MAX_BYTES) { "批次超过 512 KiB" }
        db.insertOrThrow("outbox", null, ContentValues().apply {
            put("id", id); put("created_ms", now); put("generation", settings.revision); put("payload", encoded)
        })
        payload
    }

    @Synchronized
    fun acknowledge(payload: Map<String, Any?>, now: Long) = transaction { db ->
        @Suppress("UNCHECKED_CAST")
        (payload["hours"] as List<Map<String, Any?>>).forEach { hour ->
            db.execSQL("UPDATE hours SET acked_revision=MAX(acked_revision,?) WHERE bucket=? AND offset_minutes=? AND cohort=?",
                arrayOf(hour["revision"], hour["bucketStart"], hour["utcOffsetMinutes"], hour["cohort"]))
        }
        (payload["ruleSnapshot"] as? Map<*, *>)?.let {
            val previous = meta(db, "profileAcked").toLongOrNull() ?: 0L
            putMeta(db, "profileAcked", maxOf(previous, (it["revision"] as Number).toLong()).toString())
        }
        db.delete("outbox", "id=?", arrayOf(payload["batchId"] as String))
        putMeta(db, "lastSuccessAt", now.toString()); putMeta(db, "lastMessage", "接收端已确认保存批次")
    }

    @Synchronized
    fun failure(batchId: String?, message: String) = transaction { db ->
        if (batchId != null) db.execSQL("UPDATE outbox SET attempts=attempts+1 WHERE id=?", arrayOf(batchId))
        putMeta(db, "lastMessage", message)
    }

    @Synchronized
    fun status(now: Long, eventDays: Int = ResearchPolicy.EVENT_RETENTION_DAYS): Map<String, Any?> = transaction { db ->
        prune(db, now, eventDays)
        val hours = mutableListOf<Map<String, Any?>>()
        val totals = mutableMapOf<String, Long>()
        val cohorts = mutableMapOf<String, MutableMap<String, Long>>()
        db.rawQuery("SELECT bucket,offset_minutes,cohort,metrics FROM hours ORDER BY bucket DESC", null).use { c ->
            while (c.moveToNext()) {
                val values = Json.parseObject(c.getString(3)) ?: error("小时汇总损坏")
                values.forEach { (key, value) ->
                    val n = (value as Number).toLong()
                    totals[key] = (totals[key] ?: 0) + n
                    val group = cohorts.getOrPut(c.getString(2)) { mutableMapOf() }
                    group[key] = (group[key] ?: 0) + n
                }
                if (hours.size < 24) hours.add(mapOf("bucketStart" to c.getLong(0), "utcOffsetMinutes" to c.getInt(1), "cohort" to c.getString(2), "metrics" to values))
            }
        }
        mapOf(
            "totals" to totals, "cohorts" to cohorts, "recentHours" to hours,
            "eventCount" to count(db, "events"), "hourCount" to count(db, "hours"),
            "pendingHours" to count(db, "hours", "revision>acked_revision"), "pendingBatches" to count(db, "outbox"),
            "lastSuccessAt" to (meta(db, "lastSuccessAt").toLongOrNull() ?: 0L),
            "lastMessage" to meta(db, "lastMessage"),
            "retentionDroppedEvents" to (meta(db, "droppedEvents").toLongOrNull() ?: 0L),
            "retentionDroppedHours" to (meta(db, "droppedHours").toLongOrNull() ?: 0L),
            "retentionDroppedBatches" to (meta(db, "droppedBatches").toLongOrNull() ?: 0L),
            "firstHourBucket" to db.rawQuery("SELECT COALESCE(MIN(bucket),0) FROM hours", null).use { it.moveToFirst(); it.getLong(0) },
            "firstEventAt" to db.rawQuery("SELECT COALESCE(MIN(at_ms),0) FROM events", null).use { it.moveToFirst(); it.getLong(0) },
            "lastPreparedAt" to (meta(db, "lastPreparedAt").toLongOrNull() ?: 0L),
        )
    }

    @Synchronized
    fun markArchivePrepared(now: Long) = transaction { db -> putMeta(db, "lastPreparedAt", now.toString()) }

    /** A complete, consistent snapshot; independent of outbox and ACK watermarks. */
    @Synchronized
    fun writeArchive(output: java.io.Writer, metadata: Map<String, Any?>, now: Long) = transaction { db ->
        prune(db, now, (metadata["retention"] as Map<*, *>)["eventDays"] as Int)
        output.write("{")
        var first = true
        metadata.forEach { (key, value) ->
            if (!first) output.write(",")
            first = false
            output.write(Json.stringify(key) + ":" + Json.stringify(value))
        }
        output.write(",\"coverage\":" + Json.stringify(mapOf(
            "retentionDroppedEvents" to (meta(db, "droppedEvents").toLongOrNull() ?: 0L),
            "retentionDroppedHours" to (meta(db, "droppedHours").toLongOrNull() ?: 0L),
            "retentionDroppedBatches" to (meta(db, "droppedBatches").toLongOrNull() ?: 0L))))
        output.write(",\"hours\":[")
        var comma = false
        db.rawQuery("SELECT bucket,offset_minutes,cohort,revision,metrics FROM hours ORDER BY bucket,offset_minutes,cohort", null).use { cursor ->
            while (cursor.moveToNext()) {
                if (comma) output.write(",")
                comma = true
                output.write(Json.stringify(mapOf("bucketStart" to cursor.getLong(0), "utcOffsetMinutes" to cursor.getInt(1),
                    "cohort" to cursor.getString(2), "revision" to cursor.getLong(3), "metrics" to Json.parseObject(cursor.getString(4)))))
            }
        }
        output.write("],\"events\":[")
        comma = false
        db.rawQuery("SELECT id,at_ms,bucket,offset_minutes,cohort,metrics FROM events ORDER BY at_ms,id", null).use { cursor ->
            while (cursor.moveToNext()) {
                if (comma) output.write(",")
                comma = true
                val id = ResearchArchive.eventId(metadata["participantId"] as String, cursor.getString(0))
                output.write(Json.stringify(mapOf("eventId" to id, "at" to cursor.getLong(1), "bucketStart" to cursor.getLong(2),
                    "utcOffsetMinutes" to cursor.getInt(3), "cohort" to cursor.getString(4), "metrics" to Json.parseObject(cursor.getString(5)))))
            }
        }
        var profile: Map<String, Any?>? = null
        if ((metadata["consent"] as Map<*, *>)["ruleStructures"] == true) {
            db.rawQuery("SELECT revision,bucket,data FROM profiles WHERE id=1", null).use { c ->
                if (c.moveToFirst()) profile = mapOf("revision" to c.getLong(0), "capturedAtBucket" to c.getLong(1), "structures" to Json.parse(c.getString(2)))
            }
        }
        output.write("],\"ruleSnapshot\":" + Json.stringify(profile) + "}")
        output.flush()
    }

    private fun prune(db: SQLiteDatabase, now: Long, eventDays: Int = ResearchPolicy.EVENT_RETENTION_DAYS) {
        fun remove(table: String, condition: String, key: String) {
            val removed = db.delete(table, condition, null)
            if (removed > 0) putMeta(db, key, ((meta(db, key).toLongOrNull() ?: 0L) + removed).toString())
        }
        remove("events", "at_ms<${now - eventDays * ResearchPolicy.DAY_MS}", "droppedEvents")
        val excess = count(db, "events") - ResearchPolicy.EVENT_LIMIT
        if (excess > 0) remove("events", "id IN (SELECT id FROM events ORDER BY at_ms LIMIT $excess)", "droppedEvents")
        remove("hours", "bucket<${now - 30 * ResearchPolicy.DAY_MS}", "droppedHours")
        val hourExcess = count(db, "hours") - ResearchPolicy.HOUR_LIMIT
        if (hourExcess > 0) remove("hours", "rowid IN (SELECT rowid FROM hours ORDER BY bucket LIMIT $hourExcess)", "droppedHours")
        remove("outbox", "created_ms<${now - 30 * ResearchPolicy.DAY_MS}", "droppedBatches")
    }

    private fun meta(db: SQLiteDatabase, key: String): String = db.rawQuery("SELECT value FROM metadata WHERE key=?", arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else "" }
    private fun putMeta(db: SQLiteDatabase, key: String, value: String) {
        db.insertWithOnConflict("metadata", null, ContentValues().apply { put("key", key); put("value", value) }, SQLiteDatabase.CONFLICT_REPLACE)
    }
    private fun count(db: SQLiteDatabase, table: String, where: String = "1=1"): Int = db.rawQuery("SELECT COUNT(*) FROM $table WHERE $where", null).use { it.moveToFirst(); it.getInt(0) }
    private inline fun <T> transaction(block: (SQLiteDatabase) -> T): T {
        val db = writableDatabase
        db.beginTransaction()
        try { val value = block(db); db.setTransactionSuccessful(); return value } finally { db.endTransaction() }
    }
}
