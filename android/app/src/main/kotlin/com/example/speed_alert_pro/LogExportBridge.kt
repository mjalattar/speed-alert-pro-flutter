package com.example.speed_alert_pro

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Export unified CSV / HERE span CSV / TomTom–Mapbox–Remote HTTP CSV to [MediaStore.Downloads] (API 29+). */
class LogExportBridge(
    private val context: Context,
    engine: FlutterEngine,
) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "speed_alert_pro/log_export")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "copyUnifiedCsvToDownloads" -> {
                    val path = call.argument<String>("sourcePath")
                    val session = call.argument<String>("session")
                    if (path == null || session == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val name = when (session) {
                        "SIMULATION" -> "SpeedAlertPro_speed_limit_log_simulation_${stamp()}.csv"
                        "DRIVING" -> "SpeedAlertPro_speed_limit_log_driving_${stamp()}.csv"
                        else -> {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                    }
                    val uri = copyFileToDownloads(File(path), name, "text/csv")
                    result.success(if (uri != null) name else null)
                }
                "copySpanSessionCsvToDownloads" -> {
                    val content = call.argument<String>("content")
                    val session = call.argument<String>("session")
                    if (content == null || session == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val name =
                        "SpeedAlertPro_here_spans_${session.lowercase(Locale.US)}_${stamp()}.csv"
                    val uri = copyBytesToDownloads(content.toByteArray(Charsets.UTF_8), name, "text/csv")
                    result.success(if (uri != null) name else null)
                }
                "copyProviderHttpSessionCsvToDownloads" -> {
                    val content = call.argument<String>("content")
                    val session = call.argument<String>("session")
                    val provider = call.argument<String>("provider")
                    if (content == null || session == null || provider == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val tag = when (provider) {
                        "TOMTOM" -> "tomtom_http"
                        "MAPBOX" -> "mapbox_http"
                        "REMOTE" -> "remote_http"
                        else -> {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                    }
                    val name = "SpeedAlertPro_${tag}_${session.lowercase(Locale.US)}_${stamp()}.csv"
                    val uri = copyBytesToDownloads(content.toByteArray(Charsets.UTF_8), name, "text/csv")
                    result.success(if (uri != null) name else null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun stamp(): String =
        SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())

    private fun copyFileToDownloads(source: File, displayName: String, mime: String): Uri? {
        if (!source.isFile) return null
        val app = context.applicationContext
        val resolver = app.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: return null
        return try {
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(source).use { it.copyTo(out) }
            } ?: run {
                resolver.delete(uri, null, null)
                return null
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri
        } catch (_: Exception) {
            resolver.delete(uri, null, null)
            null
        }
    }

    private fun copyBytesToDownloads(bytes: ByteArray, displayName: String, mime: String): Uri? {
        val app = context.applicationContext
        val resolver = app.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, displayName)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: return null
        return try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: run {
                resolver.delete(uri, null, null)
                return null
            }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            uri
        } catch (_: Exception) {
            resolver.delete(uri, null, null)
            null
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
