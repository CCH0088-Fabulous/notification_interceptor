package dev.poc.notifinterceptor.data

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/** JSON ↔ 普通 Map/List 的转换，隔离 org.json 依赖，domain 层不感知。 */
object Json {

    fun stringify(value: Any?): String = when (value) {
        null -> "null"
        is Map<*, *> -> JSONObject(value).toString()
        is Collection<*> -> JSONArray(value).toString()
        else -> JSONObject.wrap(value)?.toString() ?: "null"
    }

    fun parse(text: String): Any? = try {
        toPlain(JSONTokener(text).nextValue())
    } catch (_: Exception) {
        null
    }

    fun parseObject(text: String): Map<String, Any?>? = parse(text) as? Map<String, Any?>

    private fun toPlain(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence()
            .associateWith { key -> toPlain(value.opt(key)) }
        is JSONArray -> (0 until value.length()).map { index -> toPlain(value.opt(index)) }
        else -> value
    }
}
