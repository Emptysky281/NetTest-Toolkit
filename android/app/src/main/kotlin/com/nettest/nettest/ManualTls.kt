package com.nettest.nettest

import android.os.Build
import java.nio.ByteBuffer
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult
import javax.net.ssl.SSLException
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Client TLS driven step by step. The caller moves bytes over its own TCP socket:
 * step() feeds buffered server bytes, advances the handshake and returns our next flight
 * (ClientHello first). It stops as soon as more server data is needed, so each flight is
 * sent only when the user asks for it.
 */
class ManualTls(host: String, port: Int, private val sni: String, private val verify: Boolean, alpn: List<String>) {
    private val engine: SSLEngine
    private var netIn: ByteBuffer
    private var netOut: ByteBuffer
    private var appIn: ByteBuffer
    private var done = false
    private var started = false

    init {
        val ctx = SSLContext.getInstance("TLS")
        if (verify) {
            ctx.init(null, null, null)
        } else {
            val trustAll = object : X509TrustManager {
                override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
                override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
            }
            ctx.init(null, arrayOf<TrustManager>(trustAll), null)
        }
        val peer = sni.ifEmpty { host }
        engine = ctx.createSSLEngine(peer, port)
        engine.useClientMode = true
        val p = engine.sslParameters
        if (sni.isNotEmpty() && !isIp(sni)) p.serverNames = listOf(SNIHostName(sni)) else p.serverNames = emptyList()
        if (verify) p.endpointIdentificationAlgorithm = "HTTPS"
        if (alpn.isNotEmpty() && Build.VERSION.SDK_INT >= 29) p.applicationProtocols = alpn.toTypedArray()
        engine.sslParameters = p
        val s = engine.session
        netIn = ByteBuffer.allocate(s.packetBufferSize)
        netOut = ByteBuffer.allocate(s.packetBufferSize)
        appIn = ByteBuffer.allocate(s.applicationBufferSize)
    }

    private fun isIp(s: String) = s.matches(Regex("^[0-9.]+$")) || s.contains(':')

    private fun feed(data: ByteArray) {
        if (netIn.remaining() < data.size) {
            val nb = ByteBuffer.allocate(netIn.position() + data.size + 4096)
            netIn.flip()
            nb.put(netIn)
            netIn = nb
        }
        netIn.put(data)
    }

    private fun runTasks() {
        while (true) {
            val t = engine.delegatedTask ?: break
            t.run()
        }
    }

    private fun takeOut(): ByteArray {
        netOut.flip()
        val b = ByteArray(netOut.remaining())
        netOut.get(b)
        netOut.clear()
        return b
    }

    private fun takeApp(): ByteArray {
        appIn.flip()
        val b = ByteArray(appIn.remaining())
        appIn.get(b)
        appIn.clear()
        return b
    }

    private fun wrapOnce(src: ByteBuffer): SSLEngineResult {
        while (true) {
            val r = engine.wrap(src, netOut)
            if (r.status == SSLEngineResult.Status.BUFFER_OVERFLOW) {
                val nb = ByteBuffer.allocate(netOut.capacity() * 2)
                netOut.flip()
                nb.put(netOut)
                netOut = nb
                continue
            }
            return r
        }
    }

    /** Returns false when more network data is needed. */
    private fun unwrapOnce(): SSLEngineResult? {
        netIn.flip()
        try {
            while (true) {
                val r = engine.unwrap(netIn, appIn)
                when (r.status) {
                    SSLEngineResult.Status.BUFFER_OVERFLOW -> {
                        val nb = ByteBuffer.allocate(appIn.capacity() * 2)
                        appIn.flip()
                        nb.put(appIn)
                        appIn = nb
                    }
                    SSLEngineResult.Status.BUFFER_UNDERFLOW -> return null
                    else -> return r
                }
            }
        } finally {
            netIn.compact()
        }
    }

    fun step(incoming: ByteArray): Map<String, Any?> {
        feed(incoming)
        try {
            if (!started) {
                engine.beginHandshake()
                started = true
            }
            val empty = ByteBuffer.allocate(0)
            loop@ while (!done) {
                when (engine.handshakeStatus) {
                    SSLEngineResult.HandshakeStatus.NEED_WRAP -> {
                        val r = wrapOnce(empty)
                        if (r.handshakeStatus == SSLEngineResult.HandshakeStatus.FINISHED) done = true
                        // stop after producing a flight once the engine wants server data
                        if (netOut.position() > 0 && engine.handshakeStatus == SSLEngineResult.HandshakeStatus.NEED_UNWRAP) break@loop
                    }
                    SSLEngineResult.HandshakeStatus.NEED_UNWRAP -> {
                        if (netIn.position() == 0) break@loop
                        val r = unwrapOnce() ?: break@loop
                        if (r.handshakeStatus == SSLEngineResult.HandshakeStatus.FINISHED) done = true
                        if (r.status == SSLEngineResult.Status.CLOSED) break@loop
                    }
                    SSLEngineResult.HandshakeStatus.NEED_TASK -> runTasks()
                    SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING,
                    SSLEngineResult.HandshakeStatus.FINISHED -> done = true
                    else -> break@loop
                }
            }
            var plain = ByteArray(0)
            if (done) {
                if (verify && Build.VERSION.SDK_INT < 24 && sni.isNotEmpty() &&
                    !HttpsURLConnection.getDefaultHostnameVerifier().verify(sni, engine.session)
                ) {
                    throw SSLException("证书主机名不匹配: $sni")
                }
                plain = drainApp()
            }
            return result(takeOut(), plain)
        } catch (e: SSLException) {
            // flush any alert the engine generated
            try {
                wrapOnce(ByteBuffer.allocate(0))
            } catch (_: Exception) {
            }
            return mapOf("out" to takeOut(), "error" to (e.message ?: e.toString()), "done" to false)
        }
    }

    private fun drainApp(): ByteArray {
        var closed = false
        while (netIn.position() > 0) {
            val r = unwrapOnce() ?: break
            if (r.status == SSLEngineResult.Status.CLOSED) {
                closed = true
                break
            }
            if (r.handshakeStatus == SSLEngineResult.HandshakeStatus.NEED_TASK) runTasks()
            if (r.bytesConsumed() == 0 && r.bytesProduced() == 0) break
        }
        lastClosed = closed
        return takeApp()
    }

    private var lastClosed = false

    private fun result(out: ByteArray, plain: ByteArray): Map<String, Any?> {
        val m = mutableMapOf<String, Any?>("out" to out, "plain" to plain, "done" to done, "closed" to lastClosed)
        if (done) {
            m["protocol"] = engine.session.protocol
            m["cipher"] = engine.session.cipherSuite
            if (Build.VERSION.SDK_INT >= 29) m["alpn"] = engine.applicationProtocol?.ifEmpty { null }
        }
        return m
    }

    fun decrypt(data: ByteArray): Map<String, Any?> {
        feed(data)
        return try {
            result(ByteArray(0), drainApp())
        } catch (e: SSLException) {
            mapOf("error" to (e.message ?: e.toString()), "plain" to takeApp())
        }
    }

    fun encrypt(data: ByteArray): Map<String, Any?> {
        val src = ByteBuffer.wrap(data)
        return try {
            while (src.hasRemaining()) {
                val r = wrapOnce(src)
                if (r.status == SSLEngineResult.Status.CLOSED) throw SSLException("TLS 已关闭")
            }
            mapOf("out" to takeOut())
        } catch (e: SSLException) {
            mapOf("error" to (e.message ?: e.toString()), "out" to ByteArray(0))
        }
    }
}
