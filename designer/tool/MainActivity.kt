package com.example.mirror_designer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException

/// The bare Flutter activity, plus the native halves of "Open"/"Save As" and
/// of LAN discovery.
///
/// `file_selector` has no save support on Android, so the Dart side routes
/// saves through this channel and the Storage Access Framework
/// (`ACTION_CREATE_DOCUMENT`) provides the dialog that `getSaveLocation` cannot.
/// Open goes through `ACTION_OPEN_DOCUMENT` for the same reason: it keeps the
/// document URI so a later Save can write back to the file that was opened.
///
/// Android also drops IPv4 multicast while no app holds a
/// `WifiManager.MulticastLock`, which is why mDNS discovery found nothing while
/// plain HTTP to the mirror worked. `mirror_discovery.dart` holds the lock for
/// exactly one browse; this activity grants it and releases a stray one on
/// teardown.
///
/// This file is the source of truth; designer/setup.sh installs it over the
/// stub that `flutter create` generates for the (gitignored) android/ tree.
class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    private companion object {
        const val CHANNEL = "com.example.mirror_designer/file_io"
        const val MULTICAST_CHANNEL = "com.example.mirror_designer/multicast"
        const val MULTICAST_LOCK_TAG = "mirror_discovery"
        const val SAVE_REQUEST_CODE = 0x5A9
        const val OPEN_REQUEST_CODE = 0x5A8
    }
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveContents: String? = null
    private var pendingOpenResult: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MULTICAST_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        acquireMulticastLock()
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Lets mDNS answers through the Wi-Fi stack for one discovery browse.
    ///
    /// Repeated acquires while the lock is already held are ignored, and a
    /// missing grant is not an error: discovery then simply sees whatever
    /// multicast the stack delivers, and manual IP entry still works.
    private fun acquireMulticastLock() {
        val lock = multicastLock ?: newMulticastLock() ?: return
        multicastLock = lock
        if (lock.isHeld) return
        try {
            lock.acquire()
        } catch (_: SecurityException) {
            // CHANGE_WIFI_MULTICAST_STATE is declared in the manifest, so this
            // only happens on a build that dropped it.
        }
    }

    private fun releaseMulticastLock() {
        val lock = multicastLock ?: return
        multicastLock = null
        try {
            lock.release()
        } catch (_: RuntimeException) {
            // Already released (or never acquired); nothing left to undo.
        }
    }

    private fun newMulticastLock(): WifiManager.MulticastLock? {
        val wifi =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return null
        return try {
            wifi.createMulticastLock(MULTICAST_LOCK_TAG)
        } catch (_: SecurityException) {
            null
        }
    }

    override fun onDestroy() {
        // A browse that was still running when the activity went away cannot
        // call back any more; make sure its lock does not outlive it.
        releaseMulticastLock()
        super.onDestroy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveAs" -> {
                val suggestedName = call.argument<String>("suggestedName") ?: "layout.json"
                val contents = call.argument<String>("contents") ?: ""
                val mimeType = call.argument<String>("mimeType") ?: "application/json"
                launchSaveAs(suggestedName, contents, mimeType, result)
            }

            "openFile" -> launchOpen(result)

            "saveTo" -> {
                val uriString = call.argument<String>("uri")
                if (uriString == null) {
                    result.error("bad_arguments", "Missing 'uri'.", null)
                    return
                }
                val contents = call.argument<String>("contents") ?: ""
                result.success(writeToUri(Uri.parse(uriString), contents))
            }

            else -> result.notImplemented()
        }
    }

    private fun launchSaveAs(
        suggestedName: String,
        contents: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        pendingSaveResult = result
        pendingSaveContents = contents

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, suggestedName)
        }

        try {
            startActivityForResult(intent, SAVE_REQUEST_CODE)
        } catch (e: Exception) {
            pendingSaveResult = null
            pendingSaveContents = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun launchOpen(result: MethodChannel.Result) {
        pendingOpenResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
        }

        try {
            startActivityForResult(intent, OPEN_REQUEST_CODE)
        } catch (e: Exception) {
            pendingOpenResult = null
            result.error("launch_failed", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == SAVE_REQUEST_CODE) {
            handleSaveResult(resultCode, data)
            return
        }
        if (requestCode == OPEN_REQUEST_CODE) {
            handleOpenResult(resultCode, data)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun handleSaveResult(resultCode: Int, data: Intent?) {
        val result = pendingSaveResult ?: return
        val contents = pendingSaveContents ?: ""
        pendingSaveResult = null
        pendingSaveContents = null

        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return
        }

        try {
            persistPermission(uri)
            if (!writeToUri(uri, contents)) {
                result.error(
                    "write_failed",
                    "Could not open the chosen document for writing.",
                    null,
                )
                return
            }
            result.success(mapOf("uri" to uri.toString(), "name" to queryDisplayName(uri)))
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    private fun handleOpenResult(resultCode: Int, data: Intent?) {
        val result = pendingOpenResult ?: return
        pendingOpenResult = null

        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            result.success(null)
            return
        }

        try {
            persistPermission(uri)
            val contents = readUriContents(uri)
            if (contents == null) {
                result.error("read_failed", "Could not read the chosen document.", null)
                return
            }
            result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "name" to queryDisplayName(uri),
                    "contents" to contents,
                ),
            )
        } catch (e: Exception) {
            result.error("read_failed", e.message, null)
        }
    }

    private fun readUriContents(uri: Uri): String? {
        return try {
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { String(it.readBytes(), Charsets.UTF_8) }
        } catch (e: IOException) {
            null
        } catch (e: SecurityException) {
            null
        }
    }

    private fun writeToUri(uri: Uri, contents: String): Boolean {
        return try {
            val output = contentResolver.openOutputStream(uri, "wt") ?: return false
            output.use { it.write(contents.toByteArray(Charsets.UTF_8)) }
            true
        } catch (e: IOException) {
            false
        } catch (e: SecurityException) {
            false
        }
    }

    private fun persistPermission(uri: Uri) {
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        } catch (_: SecurityException) {
            // Not every provider supports persisted grants; the in-process grant
            // is enough for the session.
        }
    }

    private fun queryDisplayName(uri: Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    cursor.getString(index)?.let { return it }
                }
            }
        }
        return uri.lastPathSegment ?: "layout.json"
    }
}
