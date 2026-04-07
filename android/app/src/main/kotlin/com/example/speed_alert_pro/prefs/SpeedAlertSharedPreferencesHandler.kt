package com.example.speed_alert_pro.prefs

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import io.flutter.plugins.sharedpreferences.Messages
import io.flutter.plugins.sharedpreferences.SharedPreferencesListEncoder
import io.flutter.plugins.sharedpreferences.StringListObjectInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.ObjectOutputStream
import java.math.BigInteger
import java.util.ArrayList
import java.util.HashMap
import java.util.HashSet

/**
 * [Context.getSharedPreferences]("SpeedAlertPrefs", …) implementation for Pigeon [Messages.SharedPreferencesApi]
 * (after [MainActivity] overrides the plugin default handler).
 *
 * Encoding matches [io.flutter.plugins.sharedpreferences.LegacySharedPreferencesPlugin].
 */
class SpeedAlertSharedPreferencesHandler(context: Context) : Messages.SharedPreferencesApi {

    private val preferences: SharedPreferences =
        context.applicationContext.getSharedPreferences(SPEED_ALERT_PREFS_NAME, Context.MODE_PRIVATE)

    /** Same encoding as [io.flutter.plugins.sharedpreferences.LegacySharedPreferencesPlugin.ListEncoder] (package-private). */
    private val listEncoder: SharedPreferencesListEncoder = ListEncoder()

    private class ListEncoder : SharedPreferencesListEncoder {
        override fun encode(list: List<String>): String {
            try {
                val byteStream = ByteArrayOutputStream()
                val stream = ObjectOutputStream(byteStream)
                stream.writeObject(list)
                stream.flush()
                return Base64.encodeToString(byteStream.toByteArray(), 0)
            } catch (e: IOException) {
                throw RuntimeException(e)
            }
        }

        override fun decode(listString: String): List<String> {
            try {
                val stream = StringListObjectInputStream(
                    ByteArrayInputStream(Base64.decode(listString, 0)),
                )
                @Suppress("UNCHECKED_CAST")
                return stream.readObject() as List<String>
            } catch (e: IOException) {
                throw RuntimeException(e)
            } catch (e: ClassNotFoundException) {
                throw RuntimeException(e)
            }
        }
    }

    companion object {
        const val SPEED_ALERT_PREFS_NAME = "SpeedAlertPrefs"

        private const val LIST_IDENTIFIER =
            "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
        private const val JSON_LIST_IDENTIFIER = LIST_IDENTIFIER + "!"
        private const val BIG_INTEGER_PREFIX =
            "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy"
        private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
    }

    override fun remove(key: String): Boolean = preferences.edit().remove(key).commit()

    override fun setBool(key: String, value: Boolean): Boolean =
        preferences.edit().putBoolean(key, value).commit()

    override fun setString(key: String, value: String): Boolean {
        if (value.startsWith(LIST_IDENTIFIER) ||
            value.startsWith(BIG_INTEGER_PREFIX) ||
            value.startsWith(DOUBLE_PREFIX)
        ) {
            throw RuntimeException(
                "StorageError: This string cannot be stored as it clashes with special identifier prefixes",
            )
        }
        return preferences.edit().putString(key, value).commit()
    }

    override fun setInt(key: String, value: Long): Boolean =
        preferences.edit().putLong(key, value).commit()

    override fun setDouble(key: String, value: Double): Boolean {
        val doubleValueStr = value.toString()
        return preferences.edit().putString(key, DOUBLE_PREFIX + doubleValueStr).commit()
    }

    override fun setEncodedStringList(key: String, value: String): Boolean =
        preferences.edit().putString(key, value).commit()

    override fun setDeprecatedStringList(key: String, value: MutableList<String>): Boolean =
        preferences.edit().putString(key, LIST_IDENTIFIER + listEncoder.encode(value)).commit()

    override fun clear(prefix: String, allowList: MutableList<String>?): Boolean {
        val clearEditor = preferences.edit()
        val allPrefs = preferences.all
        val filtered = ArrayList<String>()
        val allowSet = allowList?.toHashSet()
        for (k in allPrefs.keys) {
            if (k.startsWith(prefix) && (allowSet == null || allowSet.contains(k))) {
                filtered.add(k)
            }
        }
        for (k in filtered) {
            clearEditor.remove(k)
        }
        return clearEditor.commit()
    }

    override fun getAll(prefix: String, allowList: MutableList<String>?): MutableMap<String, Any> {
        val allowSet = allowList?.toHashSet()
        return getAllPrefs(prefix, allowSet)
    }

    private fun getAllPrefs(prefix: String, allowList: HashSet<String>?): HashMap<String, Any> {
        val allPrefs = preferences.all
        val filtered = HashMap<String, Any>()
        for (key in allPrefs.keys) {
            if (key.startsWith(prefix) && (allowList == null || allowList.contains(key))) {
                val raw = allPrefs[key] ?: continue
                filtered[key] = transformPref(key, raw)
            }
        }
        return filtered
    }

    private fun transformPref(key: String, value: Any): Any {
        if (value is String) {
            if (value.startsWith(LIST_IDENTIFIER)) {
                return if (value.startsWith(JSON_LIST_IDENTIFIER)) {
                    value
                } else {
                    listEncoder.decode(value.substring(LIST_IDENTIFIER.length))
                }
            } else if (value.startsWith(BIG_INTEGER_PREFIX)) {
                val encoded = value.substring(BIG_INTEGER_PREFIX.length)
                return BigInteger(encoded, Character.MAX_RADIX)
            } else if (value.startsWith(DOUBLE_PREFIX)) {
                val doubleStr = value.substring(DOUBLE_PREFIX.length)
                return doubleStr.toDouble()
            }
        } else if (value is Set<*>) {
            @Suppress("UNCHECKED_CAST")
            val listValue = ArrayList((value as Set<String>))
            preferences.edit()
                .remove(key)
                .putString(key, LIST_IDENTIFIER + listEncoder.encode(listValue))
                .apply()
            return listValue
        }
        return value
    }
}
