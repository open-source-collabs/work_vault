package com.workvault.work_vault

import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.URLConnection
import java.net.URLStreamHandler
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Entity-tag, redirect, and timeout behavior of the resumable GET engine.
 *
 * Redirects run through `openHttps` against a scripted connection, so no socket is opened.
 */
internal class WorkVaultResumeAndRedirectTest {
    private val match = ContentRange(start = 100L, endInclusive = 199L, total = 400L)

    @Test
    fun aChangedEntityTagRestartsInsteadOfStitchingTwoFiles() {
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(206, 100L, true, match, "\"v1\"", "\"v2\""),
        )
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(200, 0L, false, null, "\"v1\"", "\"v2\""),
        )
        assertEquals(
            PartialBodyPlan.RESTART,
            planPartialBody(416, 100L, true, null, "\"v1\"", "\"v2\""),
        )
    }

    @Test
    fun anUnchangedOrUnknownEntityTagKeepsTheResumeDecisionToTheStatus() {
        assertEquals(PartialBodyPlan.APPEND, planPartialBody(206, 100L, true, match, "\"v1\"", "W/\"v1\""))
        assertEquals(PartialBodyPlan.APPEND, planPartialBody(206, 100L, true, match, null, "\"v2\""))
        assertEquals(PartialBodyPlan.APPEND, planPartialBody(206, 100L, true, match, "\"v1\"", null))
    }

    @Test
    fun aRedirectChainUpToTheLimitIsFollowed() {
        val server = ScriptedServer(redirects = WorkVaultContract.maxRedirects)

        val connection = openHttps("task", server.url("/0"), "GET", emptyMap())

        assertEquals(200, connection.responseCode)
        assertEquals("/${WorkVaultContract.maxRedirects}", connection.url.path)
    }

    @Test
    fun oneRedirectPastTheLimitFailsAsNonRetryable() {
        val server = ScriptedServer(redirects = WorkVaultContract.maxRedirects + 1)

        val failure = assertFailsWith<TransferException> {
            openHttps("task", server.url("/0"), "GET", emptyMap())
        }

        assertEquals("redirect", failure.code)
        assertFalse(failure.retryable)
    }

    @Test
    fun aRedirectToCleartextIsRefused() {
        val server = ScriptedServer(
            redirects = 1,
            location = { "http://cdn.example.com/archive.bin" },
        )

        val failure = assertFailsWith<TransferException> {
            openHttps("task", server.url("/0"), "GET", emptyMap())
        }

        assertEquals("http", failure.code)
        assertFalse(failure.retryable)
    }

    @Test
    fun aCleartextStartUrlIsRefusedBeforeAnyConnection() {
        val failure = assertFailsWith<TransferException> {
            openHttps("task", URL("http://cdn.example.com/archive.bin"), "GET", emptyMap())
        }

        assertEquals("http", failure.code)
        assertFalse(failure.retryable)
    }

    @Test
    fun aRedirectWithoutALocationFails() {
        val server = ScriptedServer(redirects = 1, location = { null })

        val failure = assertFailsWith<TransferException> {
            openHttps("task", server.url("/0"), "GET", emptyMap())
        }

        assertEquals("redirect", failure.code)
        assertFalse(failure.retryable)
    }

    @Test
    fun everyHopUsesTheConnectAndReadTimeouts() {
        val server = ScriptedServer(redirects = 2)

        openHttps("task", server.url("/0"), "GET", emptyMap())

        assertEquals(3, server.connections.size)
        for (connection in server.connections) {
            assertEquals(WorkVaultContract.connectTimeoutMs, connection.connectTimeout)
            assertEquals(WorkVaultContract.readTimeoutMs, connection.readTimeout)
            assertFalse(connection.instanceFollowRedirects)
        }
    }

    @Test
    fun aStallBeforeAnyByteIsARetryableFailure() {
        val outcome = recoverFromConnectionLoss(0L, null, SocketTimeoutException("Read timed out").message)

        val failed = outcome as DownloadOutcome.Failed
        assertEquals("io", failed.code)
        assertTrue(failed.retryable)
    }

    @Test
    fun serverErrorsThatAreTransientAreRetryableAndOthersAreNot() {
        assertTrue(httpFailure(408).retryable)
        assertTrue(httpFailure(429).retryable)
        assertTrue(httpFailure(503).retryable)
        assertFalse(httpFailure(404).retryable)
        assertFalse(httpFailure(403).retryable)
        assertEquals(404, httpFailure(404).httpStatus)
    }
}

/** Answers with [redirects] hops (`/0` to `/n`) and then a 200, without opening a socket. */
private class ScriptedServer(
    private val redirects: Int,
    private val location: (Int) -> String? = { hop -> "/${hop + 1}" },
) {
    val connections = mutableListOf<HttpURLConnection>()

    private val handler = object : URLStreamHandler() {
        override fun openConnection(url: URL): URLConnection {
            val hop = url.path.removePrefix("/").toIntOrNull() ?: 0
            val connection = object : HttpURLConnection(url) {
                override fun connect() = Unit

                override fun disconnect() = Unit

                override fun usingProxy(): Boolean = false

                override fun getResponseCode(): Int = if (hop < redirects) 302 else 200

                override fun getHeaderField(name: String?): String? {
                    if (name != "Location" || hop >= redirects) {
                        return null
                    }
                    return location(hop)
                }
            }
            connections += connection
            return connection
        }
    }

    fun url(path: String): URL = URL(null, "https://cdn.example.com$path", handler)
}
