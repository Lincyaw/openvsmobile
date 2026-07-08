package dev.lincyaw.mobilecode

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private val updaterChannel = "dev.lincyaw.mobilecode/updater"
    private val backendBackupChannel = "dev.lincyaw.mobilecode/backend_backup"
    private val accessibilityVoiceChannel = "dev.lincyaw.mobilecode/accessibility_voice"
    private val requestExportBackendBackup = 6201
    private val requestImportBackendBackup = 6202
    private val requestRecordAudio = 6203
    private var pendingDocumentResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingSpeechPrompt: String? = null
    private var activeSpeechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false
    private var textToSpeechInitError: String? = null
    private var pendingTtsResult: MethodChannel.Result? = null
    private var pendingTtsText: String? = null
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, accessibilityVoiceChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "recognizeOnce" -> {
                        recognizeOnce(call.argument<String>("prompt"), result)
                    }
                    "isSpeechRecognitionAvailable" -> {
                        result.success(SpeechRecognizer.isRecognitionAvailable(this))
                    }
                    "speak" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("INVALID_ARG", "Missing 'text' argument", null)
                            return@setMethodCallHandler
                        }
                        speakText(text, result)
                    }
                    "stopSpeaking" -> {
                        textToSpeech?.stop()
                        result.success(null)
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
        finishPendingSpeechWithError("ACTIVITY_DESTROYED", "Activity was destroyed")
        activeSpeechRecognizer?.destroy()
        activeSpeechRecognizer = null
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != requestRecordAudio) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            finishPendingSpeechWithError(
                "PERMISSION_DENIED",
                "Microphone permission is required for voice input"
            )
            return
        }
        startSpeechRecognition()
    }

    private fun recognizeOnce(prompt: String?, result: MethodChannel.Result) {
        if (pendingSpeechResult != null || activeSpeechRecognizer != null) {
            result.error("BUSY", "Speech recognition is already active", null)
            return
        }
        pendingSpeechResult = result
        pendingSpeechPrompt = prompt
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), requestRecordAudio)
            return
        }
        startSpeechRecognition()
    }

    private fun startSpeechRecognition() {
        val result = pendingSpeechResult ?: return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            finishPendingSpeechWithError(
                "UNAVAILABLE",
                "Speech recognition is not available on this device"
            )
            return
        }
        val recognizer = SpeechRecognizer.createSpeechRecognizer(this)
        activeSpeechRecognizer = recognizer
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onError(error: Int) {
                finishPendingSpeechWithError(
                    speechErrorCode(error),
                    speechErrorMessage(error)
                )
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(
                    SpeechRecognizer.RESULTS_RECOGNITION
                )
                val text = matches?.firstOrNull { it.isNotBlank() } ?: ""
                val pending = pendingSpeechResult
                clearPendingSpeech()
                pending?.success(text)
            }
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            pendingSpeechPrompt?.let {
                putExtra(RecognizerIntent.EXTRA_PROMPT, it)
            }
        }
        try {
            recognizer.startListening(intent)
        } catch (e: Exception) {
            result.error("START_FAILED", e.message, null)
            clearPendingSpeech()
        }
    }

    private fun finishPendingSpeechWithError(code: String, message: String) {
        val result = pendingSpeechResult
        clearPendingSpeech()
        result?.error(code, message, null)
    }

    private fun clearPendingSpeech() {
        activeSpeechRecognizer?.destroy()
        activeSpeechRecognizer = null
        pendingSpeechResult = null
        pendingSpeechPrompt = null
    }

    private fun speechErrorCode(error: Int): String =
        when (error) {
            SpeechRecognizer.ERROR_AUDIO -> "AUDIO_ERROR"
            SpeechRecognizer.ERROR_CLIENT -> "CLIENT_ERROR"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "PERMISSION_DENIED"
            SpeechRecognizer.ERROR_NETWORK -> "NETWORK_ERROR"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "NETWORK_TIMEOUT"
            SpeechRecognizer.ERROR_NO_MATCH -> "NO_MATCH"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "BUSY"
            SpeechRecognizer.ERROR_SERVER -> "SERVER_ERROR"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "SPEECH_TIMEOUT"
            else -> "RECOGNITION_ERROR"
        }

    private fun speechErrorMessage(error: Int): String =
        when (error) {
            SpeechRecognizer.ERROR_NO_MATCH -> "No speech was recognized"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech was heard"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                "Microphone permission is required for voice input"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Speech recognition is busy"
            SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                "Speech recognition network error"
            else -> "Speech recognition failed"
        }

    private fun speakText(text: String, result: MethodChannel.Result) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) {
            result.success(false)
            return
        }
        textToSpeechInitError?.let {
            result.error("TTS_INIT_FAILED", it, null)
            return
        }
        if (textToSpeechReady) {
            queueSpeech(trimmed, result)
            return
        }
        if (pendingTtsResult != null) {
            result.error("BUSY", "Text to speech is still initializing", null)
            return
        }
        pendingTtsResult = result
        pendingTtsText = trimmed
        if (textToSpeech == null) {
            textToSpeech = TextToSpeech(applicationContext) { status ->
                runOnUiThread {
                    if (status == TextToSpeech.SUCCESS) {
                        textToSpeechReady = true
                        textToSpeech?.language = Locale.getDefault()
                        val pendingResult = pendingTtsResult
                        val pendingText = pendingTtsText
                        pendingTtsResult = null
                        pendingTtsText = null
                        if (pendingResult != null && pendingText != null) {
                            queueSpeech(pendingText, pendingResult)
                        }
                    } else {
                        textToSpeechInitError = "Text to speech initialization failed"
                        val pendingResult = pendingTtsResult
                        pendingTtsResult = null
                        pendingTtsText = null
                        pendingResult?.error(
                            "TTS_INIT_FAILED",
                            textToSpeechInitError,
                            null
                        )
                    }
                }
            }
        }
    }

    private fun queueSpeech(text: String, result: MethodChannel.Result) {
        val tts = textToSpeech
        if (tts == null || !textToSpeechReady) {
            result.error("TTS_NOT_READY", "Text to speech is not ready", null)
            return
        }
        val status = tts.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "openvsmobile-${System.currentTimeMillis()}"
        )
        if (status == TextToSpeech.SUCCESS) {
            result.success(true)
        } else {
            result.error("TTS_ERROR", "Text to speech failed", null)
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
