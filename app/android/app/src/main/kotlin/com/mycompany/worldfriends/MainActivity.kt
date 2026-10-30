package com.mycompany.worldfriends

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannels(listOf(
                NotificationChannel("messages", "Messages", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel("social", "Friends and activity", NotificationManager.IMPORTANCE_DEFAULT),
                NotificationChannel("calls", "Calls", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel("default", "Other notifications", NotificationManager.IMPORTANCE_DEFAULT)
            ))
        }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "worldfriends/downloads").setMethodCallHandler { call, result ->
            if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
            Thread {
              try {
                val source = File(call.argument<String>("path") ?: "").canonicalFile
                require(source.path.startsWith(cacheDir.canonicalPath + File.separator) && source.isFile)
                val name = (call.argument<String>("name") ?: "worldfriends-file")
                    .replace(Regex("[^A-Za-z0-9._ -]"), "_").take(180).ifEmpty { "worldfriends-file" }
                val mime = call.argument<String>("mime") ?: "application/octet-stream"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, name)
                        put(MediaStore.Downloads.MIME_TYPE, mime)
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("Unable to create download")
                    try {
                        contentResolver.openOutputStream(uri)?.use { output -> source.inputStream().use { it.copyTo(output) } }
                            ?: throw IllegalStateException("Unable to write download")
                        values.clear()
                        values.put(MediaStore.Downloads.IS_PENDING, 0)
                        contentResolver.update(uri, values, null, null)
                    } catch (e: Exception) {
                        contentResolver.delete(uri, null, null)
                        throw e
                    }
                    runOnUiThread { result.success(uri.toString()) }
                } else {
                    @Suppress("DEPRECATION")
                    val directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                    directory.mkdirs()
                    var destination = File(directory, name)
                    if (destination.exists()) destination = File(directory, "${System.currentTimeMillis()}-$name")
                    source.copyTo(destination)
                    MediaScannerConnection.scanFile(this, arrayOf(destination.absolutePath), arrayOf(mime), null)
                    runOnUiThread { result.success(destination.absolutePath) }
                }
              } catch (e: Exception) {
                runOnUiThread { result.error("save_failed", "Could not save to Downloads", null) }
              }
            }.start()
        }
    }
}
