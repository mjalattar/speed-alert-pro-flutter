package com.example.speed_alert_pro.prefs

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
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
 * Kotlin [PreferencesManager] uses [Context.getSharedPreferences]("SpeedAlertPrefs", …).
 * Re-binds Pigeon [Messages.SharedPreferencesApi] to that file (after [MainActivity] overwrites
 * the plugin default [FlutterSharedPreferences] handler).
 *
 * Logic mirrors [io.flutter.plugins.sharedpreferences.LegacySharedPreferencesPlugin] (same encodings).
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
        private const val TAG = "SpeedAlertPrefs"
        const val SPEED_ALERT_PREFS_NAME = "SpeedAlertPrefs"

        /** Keys matching Kotlin [PreferencesManager] (unprefixed — Dart uses [SharedPreferences.setPrefix] ''). */
        private val MIGRATION_KEYS = arrayOf(
            "alert_threshold_mph",
            "audible_alert_enabled",
            "background_alert_enabled",
            "alert_run_mode",
            "api_here_enabled",
            "api_tomtom_enabled",
            "api_mapbox_enabled",
            "sim_dest_preset",
            "sim_dest_preset_migrated_el_camino",
            "sim_dest_preset_migrated_el_camino_rev",
            "sim_custom_dest_query",
            "sim_custom_dest_latlng",
            "sim_routing_origin_latlng",
            "sim_routing_dest_latlng",
            "overlay_hud_minimized",
            "use_remote_speed_api",
            "use_local_speed_stabilizer",
            "log_speed_fetches",
            "ui_theme_mode",
            "suppress_alerts_under_15_mph",
        )

        private const val LIST_IDENTIFIER =
            "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
        private const val JSON_LIST_IDENTIFIER = LIST_IDENTIFIER + "!"
        private const val BIG_INTEGER_PREFIX =
            "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy"
        private const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"

        private const val FLUTTER_DEFAULT_PREFS = "FlutterSharedPreferences"
        private const val FLUTTER_KEY_PREFIX = "flutter."

        /**
         * One-time style migration: copy known keys from the Flutter plugin file into [SPEED_ALERT_PREFS_NAME]
         * when the legacy native store has no [alert_threshold_mph] but the Flutter file does.
         */
        @JvmStatic
        fun migrateFromFlutterPluginStoreIfNeeded(context: Context) {
            val dest = context.applicationContext.getSharedPreferences(
                SPEED_ALERT_PREFS_NAME,
                Context.MODE_PRIVATE,
            )
            if (dest.contains("alert_threshold_mph")) return

            val src = context.applicationContext.getSharedPreferences(
                FLUTTER_DEFAULT_PREFS,
                Context.MODE_PRIVATE,
            )
            if (!src.contains(FLUTTER_KEY_PREFIX + "alert_threshold_mph")) return

            val ed = dest.edit()
            var any = false
            for (key in MIGRATION_KEYS) {
                if (dest.contains(key)) continue
                val fk = FLUTTER_KEY_PREFIX + key
                if (!src.contains(fk)) continue
                @Suppress("UNCHECKED_CAST")
                when (val v = src.all[fk]) {
                    is Boolean -> {
                        ed.putBoolean(key, v)
                        any = true
                    }
                    is String -> {
                        ed.putString(key, v)
                        any = true
                    }
                    is Long -> {
                        ed.putLong(key, v)
                        any = true
                    }
                    is Int -> {
                        ed.putLong(key, v.toLong())
                        any = true
                    }
                    else -> Log.d(TAG, "migrate: skip $key (${v?.javaClass})")
                }
            }
            if (any) {
                ed.commit()
                Log.i(TAG, "Migrated preference keys from $FLUTTER_DEFAULT_PREFS to $SPEED_ALERT_PREFS_NAME")
            }
        }
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
