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
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    private data class PendingTtsRequest(
        val text: String,
        val result: MethodChannel.Result,
        val waitForDone: Boolean
    )

    private var multicastLock: WifiManager.MulticastLock? = null
    private val updaterChannel = "dev.lincyaw.mobilecode/updater"
    private val backendBackupChannel = "dev.lincyaw.mobilecode/backend_backup"
    private val accessibilityVoiceChannel = "dev.lincyaw.mobilecode/accessibility_voice"
    private val voiceLogTag = "OpenVSMobileVoice"
    private val requestExportBackendBackup = 6201
    private val requestImportBackendBackup = 6202
    private val requestRecordAudio = 6203
    private val requestSpeechRecognition = 6204
    private var pendingDocumentResult: MethodChannel.Result? = null
    private var pendingExportContent: String? = null
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingSpeechPrompt: String? = null
    private var pendingSpeechFallbackReason: String? = null
    private var pendingSpeechPreferOffline = false
    private var activeSpeechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var textToSpeechReady = false
    private var textToSpeechInitError: String? = null
    private val pendingTtsRequests = mutableListOf<PendingTtsRequest>()
    private val pendingTtsCompletions = mutableMapOf<String, MethodChannel.Result>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var ttsInitTimeoutPosted = false
    private var nextTtsUtteranceId = 0L
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
                        Log.d(voiceLogTag, "recognizeOnce method call")
                        recognizeOnce(
                            call.argument<String>("prompt"),
                            call.argument<Boolean>("preferOffline") == true,
                            result
                        )
                    }
                    "isSpeechRecognitionAvailable" -> {
                        val available = SpeechRecognizer.isRecognitionAvailable(this)
                        Log.d(voiceLogTag, "isSpeechRecognitionAvailable=$available")
                        result.success(available)
                    }
                    "speak" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("INVALID_ARG", "Missing 'text' argument", null)
                            return@setMethodCallHandler
                        }
                        speakText(text, result, waitForDone = false)
                    }
                    "speakAndWait" -> {
                        val text = call.argument<String>("text")
                        if (text == null) {
                            result.error("INVALID_ARG", "Missing 'text' argument", null)
                            return@setMethodCallHandler
                        }
                        speakText(text, result, waitForDone = true)
                    }
                    "stopSpeaking" -> {
                        finishPendingTtsWithSuccess(false)
                        finishPendingTtsCompletionsWithSuccess(false)
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
        finishPendingTtsWithError("ACTIVITY_DESTROYED", "Activity was destroyed")
        finishPendingTtsCompletionsWithError("ACTIVITY_DESTROYED", "Activity was destroyed")
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
            requestSpeechRecognition -> finishSpeechActivity(resultCode, data)
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

    private fun recognizeOnce(
        prompt: String?,
        preferOffline: Boolean,
        result: MethodChannel.Result
    ) {
        if (pendingSpeechResult != null || activeSpeechRecognizer != null) {
            Log.d(voiceLogTag, "recognizeOnce rejected: busy")
            result.error("BUSY", "Speech recognition is already active", null)
            return
        }
        Log.d(
            voiceLogTag,
            "recognizeOnce accepted promptLength=${prompt?.length ?: 0} " +
                "preferOffline=$preferOffline"
        )
        pendingSpeechResult = result
        pendingSpeechPrompt = prompt
        pendingSpeechPreferOffline = preferOffline
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.d(voiceLogTag, "requesting RECORD_AUDIO permission")
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), requestRecordAudio)
            return
        }
        startSpeechRecognition()
    }

    private fun startSpeechRecognition() {
        val result = pendingSpeechResult ?: return
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            Log.d(voiceLogTag, "startSpeechRecognition unavailable")
            finishPendingSpeechWithError(
                "UNAVAILABLE",
                "Speech recognition is not available on this device"
            )
            return
        }
        Log.d(
            voiceLogTag,
            "startSpeechRecognition create recognizer preferOffline=$pendingSpeechPreferOffline"
        )
        val recognizer = SpeechRecognizer.createSpeechRecognizer(this)
        activeSpeechRecognizer = recognizer
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                Log.d(voiceLogTag, "onReadyForSpeech")
            }
            override fun onBeginningOfSpeech() {
                Log.d(voiceLogTag, "onBeginningOfSpeech")
            }
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {
                Log.d(voiceLogTag, "onEndOfSpeech")
            }
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}

            override fun onError(error: Int) {
                if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS) {
                    Log.d(
                        voiceLogTag,
                        "direct recognizer permission denied; falling back to activity"
                    )
                    pendingSpeechFallbackReason = "permission"
                    destroyActiveSpeechRecognizer()
                    startSpeechRecognitionActivity()
                    return
                }
                Log.d(
                    voiceLogTag,
                    "onError code=${speechErrorCode(error)} raw=$error"
                )
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
                Log.d(voiceLogTag, "onResults textLength=${text.length}")
                val pending = pendingSpeechResult
                clearPendingSpeech()
                pending?.success(text)
            }
        })
        val intent = buildSpeechRecognitionIntent()
        try {
            Log.d(voiceLogTag, "startListening")
            recognizer.startListening(intent)
        } catch (e: Exception) {
            Log.d(voiceLogTag, "startListening failed: ${e.message}")
            result.error("START_FAILED", e.message, null)
            clearPendingSpeech()
        }
    }

    private fun startSpeechRecognitionActivity() {
        if (pendingSpeechResult == null) return
        val intent = buildSpeechRecognitionIntent()
        try {
            Log.d(
                voiceLogTag,
                "startActivityForResult recognizer fallback " +
                    "preferOffline=$pendingSpeechPreferOffline"
            )
            @Suppress("DEPRECATION")
            startActivityForResult(intent, requestSpeechRecognition)
        } catch (e: ActivityNotFoundException) {
            Log.d(voiceLogTag, "recognizer fallback unavailable: ${e.message}")
            finishPendingSpeechWithError(
                "UNAVAILABLE",
                "Speech recognition is not available on this device"
            )
        } catch (e: Exception) {
            Log.d(voiceLogTag, "recognizer fallback failed: ${e.message}")
            finishPendingSpeechWithError("START_FAILED", e.message ?: "Speech recognition failed")
        }
    }

    private fun buildSpeechRecognitionIntent(): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, pendingSpeechPreferOffline)
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                1_500L
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                2_000L
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                1_200L
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
            pendingSpeechPrompt?.let {
                putExtra(RecognizerIntent.EXTRA_PROMPT, it)
            }
        }

    private fun finishSpeechActivity(resultCode: Int, data: Intent?) {
        val pending = pendingSpeechResult ?: return
        if (resultCode != Activity.RESULT_OK) {
            Log.d(voiceLogTag, "recognizer fallback canceled resultCode=$resultCode")
            val message = if (pendingSpeechFallbackReason == "permission") {
                "Speech recognition was canceled. Check microphone permission for the system speech service."
            } else {
                "Speech recognition was canceled"
            }
            clearPendingSpeech()
            pending.error("CANCELED", message, null)
            return
        }
        val matches = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
        val text = matches?.firstOrNull { it.isNotBlank() } ?: ""
        Log.d(voiceLogTag, "recognizer fallback result textLength=${text.length}")
        clearPendingSpeech()
        pending.success(text)
    }

    private fun finishPendingSpeechWithError(code: String, message: String) {
        Log.d(voiceLogTag, "finishPendingSpeechWithError code=$code message=$message")
        val result = pendingSpeechResult
        clearPendingSpeech()
        result?.error(code, message, null)
    }

    private fun clearPendingSpeech() {
        destroyActiveSpeechRecognizer()
        pendingSpeechResult = null
        pendingSpeechPrompt = null
        pendingSpeechFallbackReason = null
        pendingSpeechPreferOffline = false
    }

    private fun destroyActiveSpeechRecognizer() {
        activeSpeechRecognizer?.destroy()
        activeSpeechRecognizer = null
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

    private fun speakText(
        text: String,
        result: MethodChannel.Result,
        waitForDone: Boolean
    ) {
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
            queueSpeech(trimmed, result, TextToSpeech.QUEUE_FLUSH, waitForDone)
            return
        }
        pendingTtsRequests.add(PendingTtsRequest(trimmed, result, waitForDone))
        if (textToSpeech == null) {
            textToSpeech = TextToSpeech(applicationContext) { status ->
                runOnUiThread {
                    if (textToSpeechInitError != null) return@runOnUiThread
                    if (status == TextToSpeech.SUCCESS) {
                        val tts = textToSpeech
                        if (tts == null) {
                            finishPendingTtsWithError(
                                "TTS_INIT_FAILED",
                                "Text to speech initialization failed"
                            )
                            return@runOnUiThread
                        }
                        tts.setOnUtteranceProgressListener(
                            object : UtteranceProgressListener() {
                                override fun onStart(utteranceId: String?) {}

                                override fun onDone(utteranceId: String?) {
                                    if (utteranceId == null) return
                                    runOnUiThread {
                                        finishTtsCompletionWithSuccess(utteranceId, true)
                                    }
                                }

                                override fun onStop(utteranceId: String?, interrupted: Boolean) {
                                    if (utteranceId == null) return
                                    runOnUiThread {
                                        finishTtsCompletionWithSuccess(utteranceId, false)
                                    }
                                }

                                @Deprecated("Deprecated in Android")
                                override fun onError(utteranceId: String?) {
                                    if (utteranceId == null) return
                                    runOnUiThread {
                                        finishTtsCompletionWithError(
                                            utteranceId,
                                            "TTS_ERROR",
                                            "Text to speech failed"
                                        )
                                    }
                                }

                                override fun onError(utteranceId: String?, errorCode: Int) {
                                    if (utteranceId == null) return
                                    runOnUiThread {
                                        finishTtsCompletionWithError(
                                            utteranceId,
                                            "TTS_ERROR",
                                            "Text to speech failed"
                                        )
                                    }
                                }
                            }
                        )
                        textToSpeechReady = true
                        tts.language = Locale.getDefault()
                        ttsInitTimeoutPosted = false
                        drainPendingTts()
                    } else {
                        ttsInitTimeoutPosted = false
                        finishPendingTtsWithError(
                            "TTS_INIT_FAILED",
                            "Text to speech initialization failed"
                        )
                    }
                }
            }
            scheduleTtsInitTimeout()
        }
    }

    private fun scheduleTtsInitTimeout() {
        if (ttsInitTimeoutPosted) return
        ttsInitTimeoutPosted = true
        mainHandler.postDelayed({
            if (textToSpeechReady || textToSpeechInitError != null) return@postDelayed
            if (pendingTtsRequests.isEmpty()) {
                ttsInitTimeoutPosted = false
                return@postDelayed
            }
            ttsInitTimeoutPosted = false
            finishPendingTtsWithError(
                "TTS_INIT_TIMEOUT",
                "Text to speech initialization timed out"
            )
        }, 5_000)
    }

    private fun drainPendingTts() {
        val pending = pendingTtsRequests.toList()
        pendingTtsRequests.clear()
        pending.forEachIndexed { index, request ->
            val queueMode = if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
            queueSpeech(request.text, request.result, queueMode, request.waitForDone)
        }
    }

    private fun finishPendingTtsWithError(code: String, message: String) {
        textToSpeechInitError = message
        val pending = pendingTtsRequests.toList()
        pendingTtsRequests.clear()
        pending.forEach { it.result.error(code, message, null) }
    }

    private fun finishPendingTtsWithSuccess(value: Boolean) {
        val pending = pendingTtsRequests.toList()
        pendingTtsRequests.clear()
        pending.forEach { it.result.success(value) }
    }

    private fun finishTtsCompletionWithSuccess(utteranceId: String, value: Boolean) {
        pendingTtsCompletions.remove(utteranceId)?.success(value)
    }

    private fun finishTtsCompletionWithError(
        utteranceId: String,
        code: String,
        message: String
    ) {
        pendingTtsCompletions.remove(utteranceId)?.error(code, message, null)
    }

    private fun finishPendingTtsCompletionsWithSuccess(value: Boolean) {
        val pending = pendingTtsCompletions.values.toList()
        pendingTtsCompletions.clear()
        pending.forEach { it.success(value) }
    }

    private fun finishPendingTtsCompletionsWithError(code: String, message: String) {
        val pending = pendingTtsCompletions.values.toList()
        pendingTtsCompletions.clear()
        pending.forEach { it.error(code, message, null) }
    }

    private fun ttsWaitTimeoutMs(text: String): Long {
        return (4_000L + text.length * 120L).coerceAtMost(30_000L)
    }

    private fun nextTtsUtteranceId(): String {
        nextTtsUtteranceId += 1
        return "openvsmobile-$nextTtsUtteranceId"
    }

    private fun queueSpeech(
        text: String,
        result: MethodChannel.Result,
        queueMode: Int,
        waitForDone: Boolean
    ) {
        val tts = textToSpeech
        if (tts == null || !textToSpeechReady) {
            result.error("TTS_NOT_READY", "Text to speech is not ready", null)
            return
        }
        if (queueMode == TextToSpeech.QUEUE_FLUSH) {
            finishPendingTtsCompletionsWithSuccess(false)
        }
        val utteranceId = nextTtsUtteranceId()
        if (waitForDone) {
            pendingTtsCompletions[utteranceId] = result
        }
        val status = tts.speak(
            text,
            queueMode,
            null,
            utteranceId
        )
        if (status == TextToSpeech.SUCCESS) {
            if (waitForDone) {
                mainHandler.postDelayed({
                    finishTtsCompletionWithError(
                        utteranceId,
                        "TTS_TIMEOUT",
                        "Text to speech timed out"
                    )
                }, ttsWaitTimeoutMs(text))
            } else {
                result.success(true)
            }
        } else {
            if (waitForDone) {
                pendingTtsCompletions.remove(utteranceId)
            }
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
