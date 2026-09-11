package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainContentRenderPolicyTest {
    @Test
    fun searchKeepsItsTreeAcrossSnapshotOnlyRefreshes() {
        assertFalse(shouldRebuildMainContent(TAB_SEARCH, snapshotChanged = true, renderStateChanged = false))
    }

    @Test
    fun searchStillRebuildsWhenRouteStateChanges() {
        assertTrue(shouldRebuildMainContent(TAB_SEARCH, snapshotChanged = false, renderStateChanged = true))
    }

    @Test
    fun duplicateSearchCallbacksAreSuppressedOnlyForTheSameSnapshot() {
        val snapshot = Any()
        val newerSnapshot = Any()
        assertTrue(isDuplicateSearchRequest("plan", snapshot, "plan", snapshot))
        assertFalse(isDuplicateSearchRequest("plan", snapshot, "plan", newerSnapshot))
        assertFalse(isDuplicateSearchRequest("plan", snapshot, "plans", snapshot))
    }

    @Test
    fun routeScopedRenderStateOnlyActivatesRouteSpecificInputs() {
        assertTrue(contentRenderRouteScope(TAB_SETTINGS).settings)
        assertFalse(contentRenderRouteScope(TAB_SETTINGS).daily)
        assertFalse(contentRenderRouteScope(TAB_SETTINGS).schemes)

        assertTrue(contentRenderRouteScope(TAB_DAILY).daily)
        assertFalse(contentRenderRouteScope(TAB_DAILY).settings)
        assertFalse(contentRenderRouteScope(TAB_DAILY).schemes)

        assertTrue(contentRenderRouteScope(TAB_SCHEMES).schemes)
        assertFalse(contentRenderRouteScope(TAB_SCHEMES).settings)
        assertFalse(contentRenderRouteScope(TAB_SCHEMES).daily)
    }

    @Test
    fun unknownRoutesDoNotAccidentallySubscribeToRouteSpecificState() {
        val scope = contentRenderRouteScope(Int.MIN_VALUE)
        assertFalse(scope.settings)
        assertFalse(scope.daily)
        assertFalse(scope.schemes)
    }

    @Test
    fun queuedTransitionIsConsumedOnlyByARealContentRebuild() {
        assertEquals(
            ContentTransitionDirection.FORWARD,
            contentTransitionForRebuild(true, ContentTransitionDirection.FORWARD),
        )
        assertEquals(
            null,
            contentTransitionForRebuild(false, ContentTransitionDirection.BACKWARD),
        )
        assertEquals(null, contentTransitionForRebuild(false, null))
    }

    @Test
    fun snapshotBackedRoutesRebuildWhenSnapshotChanges() {
        listOf(TAB_HOME, TAB_CALENDAR, TAB_SCHEMES, TAB_DAILY, TAB_SETTINGS).forEach { tab ->
            assertTrue("tab=$tab", shouldRebuildMainContent(tab, snapshotChanged = true, renderStateChanged = false))
        }
    }

    @Test
    fun initialPublicationDoesNotScheduleASecondTimeDerivedSnapshot() {
        assertFalse(shouldRefreshTimeDerivedSnapshot(true, false, false))
        assertFalse(shouldRefreshTimeDerivedSnapshot(true, true, false))
    }

    @Test
    fun foregroundReturnRefreshesOnlyWhenNoOtherRefreshOrEditorIsActive() {
        assertTrue(shouldRefreshTimeDerivedSnapshot(false, false, false))
        assertFalse(shouldRefreshTimeDerivedSnapshot(false, true, false))
        assertFalse(shouldRefreshTimeDerivedSnapshot(false, false, true))
    }

    @Test
    fun notificationPermissionOnlyAppearsOverSettledHome() {
        assertTrue(
            shouldPresentNotificationPermission(
                uiActive = true,
                onboardingActive = false,
                workspaceUiPublished = true,
                selectedTab = TAB_HOME,
                selectedSchemeId = null,
                contentTransitionActive = false,
                editableFieldFocused = false,
            )
        )
        val blockedStates = listOf(
            { shouldPresentNotificationPermission(false, false, true, TAB_HOME, null, false, false) },
            { shouldPresentNotificationPermission(true, true, true, TAB_HOME, null, false, false) },
            { shouldPresentNotificationPermission(true, false, false, TAB_HOME, null, false, false) },
            { shouldPresentNotificationPermission(true, false, true, TAB_SETTINGS, null, false, false) },
            { shouldPresentNotificationPermission(true, false, true, TAB_HOME, "scheme", false, false) },
            { shouldPresentNotificationPermission(true, false, true, TAB_HOME, null, true, false) },
            { shouldPresentNotificationPermission(true, false, true, TAB_HOME, null, false, true) },
        )
        blockedStates.forEachIndexed { index, state -> assertFalse("blocked state $index", state()) }
    }
}
