package com.enigmadux.knotq

import org.json.JSONArray
import org.json.JSONObject

internal fun obj(vararg pairs: Pair<String, Any?>): JSONObject = JSONObject().apply {
    pairs.forEach { (key, value) -> put(key, value ?: JSONObject.NULL) }
}

internal fun JSONObject.optionalString(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf { it.isNotEmpty() && it != "null" }

internal fun JSONArray.forEachObject(callback: (JSONObject) -> Unit) {
    for (index in 0 until length()) {
        optJSONObject(index)?.let(callback)
    }
}

internal fun JSONArray.forEachIndexedObject(callback: (Int, JSONObject) -> Unit) {
    for (index in 0 until length()) {
        optJSONObject(index)?.let { callback(index, it) }
    }
}
