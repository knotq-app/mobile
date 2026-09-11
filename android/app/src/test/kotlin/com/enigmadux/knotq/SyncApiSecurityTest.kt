package com.enigmadux.knotq

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncApiSecurityTest {
    @Test
    fun httpsEndpointsAndLocalLoopbackAreAllowed() {
        assertTrue(isSecureSyncApiBase("https://api.knotq.com/v1/auth/status"))
        assertTrue(isSecureSyncApiBase("https://sync.example.test/base"))
        assertTrue(isSecureSyncApiBase("http://127.0.0.1:8787"))
        assertTrue(isSecureSyncApiBase("http://[::1]:8787/v1"))
        assertTrue(isSecureSyncApiBase("http://localhost:8787"))
    }

    @Test
    fun plaintextNonLoopbackAndLookalikeHostsAreRejected() {
        assertFalse(isSecureSyncApiBase("http://sync.example.test"))
        assertFalse(isSecureSyncApiBase("http://127.0.0.1.evil.test"))
        assertFalse(isSecureSyncApiBase("http://localhost.evil.test"))
        assertFalse(isSecureSyncApiBase("ftp://api.knotq.com"))
    }

    @Test
    fun credentialsAndRoutingDecorationsAreRejected() {
        assertFalse(isSecureSyncApiBase("https://user:password@api.knotq.com"))
        assertFalse(isSecureSyncApiBase("https://api.knotq.com?redirect=evil"))
        assertFalse(isSecureSyncApiBase("https://api.knotq.com#fragment"))
        assertFalse(isSecureSyncApiBase(""))
    }
}
