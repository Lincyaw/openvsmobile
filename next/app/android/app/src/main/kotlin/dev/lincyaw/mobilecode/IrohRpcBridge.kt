package dev.lincyaw.mobilecode

import android.content.Context
import android.util.Log
import computer.iroh.BiStream
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointOptions
import computer.iroh.EndpointTicket
import computer.iroh.IrohAndroid
import computer.iroh.presetN0
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

private const val DEFAULT_ALPN = "openvsmobile.rpc.v1"
private const val MAX_FRAME_BYTES = 1024 * 1024
private const val TAG = "IrohRpcBridge"

class IrohRpcBridge(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val nextId = AtomicInteger(1)
    private val sessions = ConcurrentHashMap<Int, IrohRpcSession>()
    private val nativeLoadError: String?
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    init {
        nativeLoadError = try {
            IrohAndroid.installAndroidContext(appContext)
            null
        } catch (t: Throwable) {
            val message = t.message ?: t.toString()
            Log.w(TAG, "Iroh native transport unavailable: $message", t)
            message
        }
        MethodChannel(messenger, "dev.lincyaw.mobilecode/iroh_rpc")
            .setMethodCallHandler(this)
        EventChannel(messenger, "dev.lincyaw.mobilecode/iroh_rpc_events")
            .setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connect" -> connect(call, result)
            "send" -> send(call, result)
            "close" -> close(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun shutdown() {
        sessions.values.forEach { it.close(1001L, "activity destroyed") }
        sessions.clear()
        scope.cancel()
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val unavailable = nativeLoadError
        if (unavailable != null) {
            result.error(
                "IROH_UNAVAILABLE",
                "Iroh native transport is unavailable on this device: $unavailable",
                null,
            )
            return
        }

        val ticket = call.argument<String>("ticket")?.trim()
        val alpn = call.argument<String>("alpn")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: DEFAULT_ALPN
        if (ticket.isNullOrEmpty()) {
            result.error("INVALID_ARG", "Missing Iroh ticket", null)
            return
        }

        scope.launch {
            var endpoint: Endpoint? = null
            try {
                endpoint = Endpoint.bind(EndpointOptions(preset = presetN0()))
                val addr = EndpointTicket.fromString(ticket).endpointAddr()
                val conn = endpoint.connect(addr, alpn.toByteArray(Charsets.UTF_8))
                val bi = conn.openBi()
                val id = nextId.getAndIncrement()
                val session = IrohRpcSession(
                    id = id,
                    endpoint = endpoint,
                    connection = conn,
                    bi = bi,
                    emit = ::emit,
                    onClosed = { sessions.remove(id) },
                )
                sessions[id] = session
                session.start(scope)
                Log.i(TAG, "Iroh RPC session $id connected to ${conn.remoteId()}")
                withContext(Dispatchers.Main) {
                    result.success(id)
                }
            } catch (t: Throwable) {
                try {
                    endpoint?.shutdown()
                } catch (_: Throwable) {
                    // Connect failed before the session owned the endpoint.
                }
                withContext(Dispatchers.Main) {
                    result.error("IROH_CONNECT", t.message ?: t.toString(), null)
                }
            }
        }
    }

    private fun send(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("id")
        val text = call.argument<String>("text")
        val session = if (id == null) null else sessions[id]
        if (id == null || text == null || session == null) {
            result.error("INVALID_ARG", "Unknown Iroh connection", null)
            return
        }
        session.send(text, result)
    }

    private fun close(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<Int>("id")
        val session = if (id == null) null else sessions.remove(id)
        if (session == null) {
            result.success(null)
            return
        }
        val code = (call.argument<Int>("code") ?: 0).toLong()
        val reason = call.argument<String>("reason") ?: ""
        session.close(code, reason)
        result.success(null)
    }

    private fun emit(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        scope.launch(Dispatchers.Main) {
            sink.success(event)
        }
    }
}

private class IrohRpcSession(
    private val id: Int,
    private val endpoint: Endpoint,
    private val connection: Connection,
    private val bi: BiStream,
    private val emit: (Map<String, Any?>) -> Unit,
    private val onClosed: () -> Unit,
) {
    private val writeMutex = Mutex()
    private val closedNotified = AtomicBoolean(false)
    private var readJob: Job? = null
    @Volatile
    private var closed = false
    private var pending = StringBuilder()

    fun start(scope: CoroutineScope) {
        readJob = scope.launch { readLoop() }
        scope.launch {
            try {
                val reason = connection.closed()
                finishClosed("connection closed: $reason")
            } catch (t: Throwable) {
                // The read loop also reports errors; this path just guarantees
                // that a remote close wakes Dart even if recv is idle.
                finishClosed("connection closed: ${t.message ?: t.toString()}")
            }
        }
    }

    fun send(text: String, result: MethodChannel.Result) {
        readJob?.let { job ->
            CoroutineScope(job + Dispatchers.IO).launch {
                try {
                    writeMutex.withLock {
                        bi.send().writeAll("$text\n".toByteArray(Charsets.UTF_8))
                    }
                    withContext(Dispatchers.Main) { result.success(null) }
                } catch (t: Throwable) {
                    emitError(t.message ?: t.toString())
                    withContext(Dispatchers.Main) {
                        result.error("IROH_SEND", t.message ?: t.toString(), null)
                    }
                    close(1L, "send failed")
                }
            }
        } ?: result.error("IROH_CLOSED", "Iroh connection is closed", null)
    }

    fun close(code: Long, reason: String) {
        if (closed) return
        closed = true
        readJob?.cancel()
        try {
            connection.close(code, reason.toByteArray(Charsets.UTF_8))
        } catch (_: Throwable) {
            // Already closed.
        }
        CoroutineScope(Dispatchers.IO).launch {
            try {
                bi.send().finish()
            } catch (_: Throwable) {
                // Already closed.
            }
            try {
                endpoint.shutdown()
            } catch (_: Throwable) {
                // Already closed.
            }
            finishClosed(if (reason.isBlank()) "local close" else "local close: $reason")
        }
    }

    private suspend fun readLoop() {
        val recv = bi.recv()
        var closeReason = "recv closed"
        try {
            while (!closed) {
                val chunk = recv.read(16_384u)
                if (chunk.isEmpty()) {
                    closeReason = "recv EOF"
                    break
                }
                acceptText(chunk.toString(Charsets.UTF_8))
            }
        } catch (e: CancellationException) {
            closeReason = "read cancelled"
            throw e
        } catch (t: Throwable) {
            closeReason = "read error: ${t.message ?: t.toString()}"
            emitError(t.message ?: t.toString())
        } finally {
            finishClosed(closeReason)
        }
    }

    private fun acceptText(text: String) {
        pending.append(text)
        if (pending.length > MAX_FRAME_BYTES) {
            emitError("Iroh JSON-RPC frame too large")
            close(1L, "frame too large")
            return
        }
        while (true) {
            val idx = pending.indexOf("\n")
            if (idx < 0) return
            val frame = pending.substring(0, idx).trimEnd()
            pending.delete(0, idx + 1)
            if (frame.isNotEmpty()) {
                emit(mapOf("id" to id, "type" to "message", "text" to frame))
            }
        }
    }

    private fun emitError(message: String) {
        Log.w(TAG, "Iroh RPC session $id error: $message")
        emit(mapOf("id" to id, "type" to "error", "message" to message))
    }

    private fun finishClosed(reason: String? = null) {
        if (!closedNotified.compareAndSet(false, true)) return
        if (!closed) closed = true
        onClosed()
        val detail = reason?.takeIf { it.isNotBlank() }
        if (detail == null) {
            Log.i(TAG, "Iroh RPC session $id closed")
            emit(mapOf("id" to id, "type" to "closed"))
        } else {
            Log.i(TAG, "Iroh RPC session $id closed: $detail")
            emit(mapOf("id" to id, "type" to "closed", "reason" to detail))
        }
    }
}
