package com.enigmadux.knotq

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SubscriptionRenderGateTest {
    @Test
    fun subscriptionStateOnlyNeedsSettingsTreeWhenVisible() {
        assertTrue(subscriptionStateNeedsRender(TAB_SETTINGS))
        assertFalse(subscriptionStateNeedsRender(TAB_HOME))
        assertFalse(subscriptionStateNeedsRender(TAB_CALENDAR))
        assertFalse(subscriptionStateNeedsRender(TAB_SCHEMES))
        assertFalse(subscriptionStateNeedsRender(TAB_DAILY))
        assertFalse(subscriptionStateNeedsRender(TAB_SEARCH))
    }
}
