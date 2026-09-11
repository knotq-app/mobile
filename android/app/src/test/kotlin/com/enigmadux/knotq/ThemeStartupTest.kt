package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Test

class ThemeStartupTest {
    @Test
    fun coldShellUsesStoredThemeUntilWorkspaceSettingsArrive() {
        assertEquals("dark", resolveStartupThemeMode(false, null, "dark"))
        assertEquals("parchment", resolveStartupThemeMode(false, null, "parchment"))
        assertEquals("system", resolveStartupThemeMode(false, null, null))
        assertEquals("dark", resolveStartupThemeMode(false, "", "dark"))
    }

    @Test
    fun loadedWorkspaceAlwaysWinsOverStaleStartupCache() {
        assertEquals("light", resolveStartupThemeMode(true, "light", "dark"))
        assertEquals("system", resolveStartupThemeMode(true, null, "dark"))
        assertEquals("system", resolveStartupThemeMode(true, "", "dark"))
    }
}
