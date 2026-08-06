package dev.lincyaw.mobilecode

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private val updaterChannel = "dev.lincyaw.mobilecode/updater"
    private val backendBackupChannel = "dev.lincyaw.mobilecode/backend_backup"
    private val requestExportBackendBackup = 6201
    private val requestImportBackendBackup = 6202
    private var pendingDocumentResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null
    private var irohRpcBridge: IrohRpcBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        irohRpcBridge = IrohRpcBridge(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceAbi" -> {
                        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "universal"
                        result.success(abi)
                    }
                    "getCacheDir" -> {
                        result.success(cacheDir.absolutePath)
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("INVALID_ARG", "Missing 'path' argument", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            val uri: Uri = FileProvider.getUriForFile(
                                this,
                                "${applicationInfo.packageName}.fileprovider",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backendBackupChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportText" -> {
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType")
                        val content = call.argument<String>("content")
                        if (fileName == null || mimeType == null || content == null) {
                            result.error("INVALID_ARG", "Missing export arguments", null)
                            return@setMethodCallHandler
                        }
                        exportText(fileName, mimeType, content, result)
                    }
                    "importText" -> {
                        val mimeType = call.argument<String>("mimeType") ?: "application/json"
                        importText(mimeType, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("mobilecode-mdns").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        irohRpcBridge?.shutdown()
        irohRpcBridge = null
        multicastLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        multicastLock = null
        super.onDestroy()
    }

    private fun exportText(
        fileName: String,
        mimeType: String,
        content: String,
        result: MethodChannel.Result
    ) {
        if (!beginDocumentOperation(result)) return
        pendingExportContent = content
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, requestExportBackendBackup)
        } catch (e: ActivityNotFoundException) {
            finishPendingWithError("NO_DOCUMENT_PROVIDER", e.message)
        } catch (e: Exception) {
            finishPendingWithError("EXPORT_LAUNCH_FAILED", e.message)
        }
    }

    private fun importText(mimeType: String, result: MethodChannel.Result) {
        if (!beginDocumentOperation(result)) return
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/json", "text/plain")
            )
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, requestImportBackendBackup)
        } catch (e: ActivityNotFoundException) {
            finishPendingWithError("NO_DOCUMENT_PROVIDER", e.message)
        } catch (e: Exception) {
            finishPendingWithError("IMPORT_LAUNCH_FAILED", e.message)
        }
    }

    private fun beginDocumentOperation(result: MethodChannel.Result): Boolean {
        if (pendingDocumentResult != null) {
            result.error("BUSY", "Another document operation is still active", null)
            return false
        }
        pendingDocumentResult = result
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            requestExportBackendBackup -> finishExport(resultCode, data)
            requestImportBackendBackup -> finishImport(resultCode, data)
        }
    }

    private fun finishExport(resultCode: Int, data: Intent?) {
        val result = pendingDocumentResult ?: return
        val content = pendingExportContent
        clearPendingDocumentOperation()
        if (resultCode != Activity.RESULT_OK) {
            result.success(false)
            return
        }
        val uri = data?.data
        if (uri == null || content == null) {
            result.error("EXPORT_ERROR", "No destination document selected", null)
            return
        }
        try {
            val output = contentResolver.openOutputStream(uri)
                ?: throw IllegalStateException("Unable to open destination document")
            output.use { stream ->
                stream.write(content.toByteArray(Charsets.UTF_8))
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("EXPORT_ERROR", e.message, null)
        }
    }

    private fun finishImport(resultCode: Int, data: Intent?) {
        val result = pendingDocumentResult ?: return
        clearPendingDocumentOperation()
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.error("IMPORT_ERROR", "No source document selected", null)
            return
        }
        try {
            val input = contentResolver.openInputStream(uri)
                ?: throw IllegalStateException("Unable to open source document")
            val content = input.use { stream ->
                stream.readBytes().toString(Charsets.UTF_8)
            }
            result.success(content)
        } catch (e: Exception) {
            result.error("IMPORT_ERROR", e.message, null)
        }
    }

    private fun finishPendingWithError(code: String, message: String?) {
        val result = pendingDocumentResult ?: return
        clearPendingDocumentOperation()
        result.error(code, message, null)
    }

    private fun clearPendingDocumentOperation() {
        pendingDocumentResult = null
        pendingExportContent = null
    }
}
