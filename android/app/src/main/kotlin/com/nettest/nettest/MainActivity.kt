package com.nettest.nettest

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Native side of "nettest/native": manual TLS (SSLEngine) and system proxy lookup. */
class MainActivity : FlutterActivity() {
    private val engines = ConcurrentHashMap<Int, ManualTls>()
    private val ids = AtomicInteger(1)
    // One thread keeps per-connection TLS calls ordered and off the UI thread.
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nettest/native").setMethodCallHandler { call, result ->
            if (call.method == "systemProxy") {
                val host = System.getProperty("http.proxyHost") ?: ""
                val port = System.getProperty("http.proxyPort")?.toIntOrNull() ?: 0
                result.success(mapOf("host" to host, "port" to port))
                return@setMethodCallHandler
            }
            worker.execute {
                val out: Any? = try {
                    when (call.method) {
                        "tlsBegin" -> {
                            val id = ids.getAndIncrement()
                            engines[id] = ManualTls(
                                call.argument<String>("host")!!,
                                call.argument<Int>("port")!!,
                                call.argument<String>("sni") ?: "",
                                call.argument<Boolean>("verify") ?: true,
                                call.argument<List<String>>("alpn") ?: emptyList(),
                            )
                            id
                        }
                        "tlsStep" -> engine(call.argument("id")).step(call.argument<ByteArray>("data") ?: ByteArray(0))
                        "tlsDecrypt" -> engine(call.argument("id")).decrypt(call.argument<ByteArray>("data")!!)
                        "tlsEncrypt" -> engine(call.argument("id")).encrypt(call.argument<ByteArray>("data")!!)
                        "tlsClose" -> {
                            engines.remove(call.argument<Int>("id"))
                            null
                        }
                        else -> NotImplemented
                    }
                } catch (e: Exception) {
                    mapOf("error" to "${e.javaClass.simpleName}: ${e.message}")
                }
                main.post {
                    if (out === NotImplemented) result.notImplemented() else result.success(out)
                }
            }
        }
    }

    private fun engine(id: Int?): ManualTls = engines[id] ?: throw IllegalStateException("TLS 会话不存在: $id")

    private object NotImplemented
}
