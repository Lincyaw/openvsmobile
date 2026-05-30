package dev.lincyaw.mobilecode

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceAbi" -> {
                        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "universal"
                        result.success(abi)
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
        multicastLock?.let {
            if (it.isHeld) {
                it.release()
            }
        }
        multicastLock = null
        super.onDestroy()
    }
}
