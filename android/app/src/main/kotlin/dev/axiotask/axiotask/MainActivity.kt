package dev.axiotask.axiotask

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val main = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private var pendingCreate: MethodChannel.Result? = null
    private var pendingOpen: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOCUMENT_EXPORT_CHANNEL)
            .setMethodCallHandler(::onDocumentExportCall)
    }

    override fun onDestroy() {
        // A picker result can no longer reach the engine that asked for it.
        pendingCreate?.success(null)
        pendingCreate = null
        pendingOpen?.success(null)
        pendingOpen = null
        io.shutdown()
        super.onDestroy()
    }

    // Current-view export (Markdown/CSV) through the Storage Access Framework:
    // the user picks any document provider; no storage permission is needed.
    private fun onDocumentExportCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "createDocument" -> createDocument(call, result)
            "writeDocument" -> writeDocument(call, result)
            "discardDocument" -> discardDocument(call, result)
            "openDocument" -> openDocument(call, result)
            "readDocument" -> readDocument(call, result)
            "shareText" -> shareText(call, result)
            else -> result.notImplemented()
        }
    }

    private fun createDocument(call: MethodCall, result: MethodChannel.Result) {
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType")
        if (fileName.isNullOrEmpty() || mimeType.isNullOrEmpty()) {
            result.error("invalid_arguments", "fileName and mimeType are required", null)
            return
        }
        if (pendingCreate != null) {
            result.error("busy", "A document picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        pendingCreate = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST)
        } catch (error: Exception) {
            pendingCreate = null
            result.error("picker_unavailable", error.javaClass.simpleName, null)
        }
    }

    // Account backup restore: the user picks an existing document from any
    // provider; it is read through ContentResolver with no storage permission.
    private fun openDocument(call: MethodCall, result: MethodChannel.Result) {
        val mimeTypes = call.argument<List<String>>("mimeTypes")
        if (mimeTypes.isNullOrEmpty()) {
            result.error("invalid_arguments", "mimeTypes are required", null)
            return
        }
        if (pendingOpen != null) {
            result.error("busy", "A document picker is already open", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (mimeTypes.size == 1) mimeTypes[0] else "*/*"
            if (mimeTypes.size > 1) {
                putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            }
        }
        pendingOpen = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, OPEN_DOCUMENT_REQUEST)
        } catch (error: Exception) {
            pendingOpen = null
            result.error("picker_unavailable", error.javaClass.simpleName, null)
        }
    }

    // Reads at most maxBytes; a larger document is refused rather than
    // truncated, so a partial backup can never be imported.
    private fun readDocument(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val maxBytes = call.argument<Number>("maxBytes")?.toInt()
        if (uri == null || maxBytes == null || maxBytes <= 0) {
            result.error("invalid_arguments", "uri and maxBytes are required", null)
            return
        }
        io.execute {
            try {
                val stream = contentResolver.openInputStream(uri)
                    ?: throw IllegalStateException("The provider returned no stream")
                val output = java.io.ByteArrayOutputStream()
                var tooLarge = false
                stream.use {
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = it.read(buffer)
                        if (read < 0) break
                        if (output.size() + read > maxBytes) {
                            tooLarge = true
                            break
                        }
                        output.write(buffer, 0, read)
                    }
                }
                if (tooLarge) {
                    main.post { result.error("too_large", "The document exceeds the size limit", null) }
                } else {
                    val name = displayName(uri)
                    val payload = mapOf("name" to name, "bytes" to output.toByteArray())
                    main.post { result.success(payload) }
                }
            } catch (error: Exception) {
                main.post { result.error("read_failed", error.javaClass.simpleName, null) }
            }
        }
    }

    // Current-view export through the system share sheet, as plain text.
    private fun shareText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text")
        val subject = call.argument<String>("subject")
        if (text == null) {
            result.error("invalid_arguments", "text is required", null)
            return
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
            if (!subject.isNullOrEmpty()) {
                putExtra(Intent.EXTRA_SUBJECT, subject)
                putExtra(Intent.EXTRA_TITLE, subject)
            }
        }
        try {
            startActivity(Intent.createChooser(send, subject))
            result.success(true)
        } catch (error: Exception) {
            result.error("share_unavailable", error.javaClass.simpleName, null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != CREATE_DOCUMENT_REQUEST && requestCode != OPEN_DOCUMENT_REQUEST) {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = if (requestCode == CREATE_DOCUMENT_REQUEST) {
            pendingCreate.also { pendingCreate = null }
        } else {
            pendingOpen.also { pendingOpen = null }
        } ?: return
        val uri = data?.data
        result.success(if (resultCode == Activity.RESULT_OK && uri != null) uri.toString() else null)
    }

    private fun writeDocument(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        val bytes = call.argument<ByteArray>("bytes")
        if (uri == null || bytes == null) {
            result.error("invalid_arguments", "uri and bytes are required", null)
            return
        }
        io.execute {
            try {
                val stream = contentResolver.openOutputStream(uri, "wt")
                    ?: throw IllegalStateException("The provider returned no stream")
                stream.use {
                    it.write(bytes)
                    it.flush()
                }
                val name = displayName(uri)
                main.post { result.success(name) }
            } catch (error: Exception) {
                main.post { result.error("write_failed", error.javaClass.simpleName, null) }
            }
        }
    }

    private fun discardDocument(call: MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null) {
            result.error("invalid_arguments", "uri is required", null)
            return
        }
        io.execute {
            val deleted = try {
                when (uri.scheme) {
                    ContentResolver.SCHEME_FILE -> uri.path?.let { File(it).delete() } ?: false
                    else -> DocumentsContract.deleteDocument(contentResolver, uri)
                }
            } catch (error: Exception) {
                false
            }
            main.post { result.success(deleted) }
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == ContentResolver.SCHEME_FILE) return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                }
        } catch (error: Exception) {
            null
        }
    }

    private companion object {
        const val DOCUMENT_EXPORT_CHANNEL = "dev.axiotask.axiotask/document_export"
        const val CREATE_DOCUMENT_REQUEST = 0x4158
        const val OPEN_DOCUMENT_REQUEST = 0x4159
    }
}
