package com.enigmadux.knotq

import org.junit.Assert.assertEquals
import org.junit.Test

class OnboardingStepTest {
    @Test
    fun negativeRestoredStepClampsToFirstStep() {
        assertEquals(0, clampedOnboardingStep(-1, ONBOARDING_STEPS.size))
        assertEquals(0, clampedOnboardingStep(Int.MIN_VALUE, ONBOARDING_STEPS.size))
    }

    @Test
    fun oversizedRestoredStepClampsToLastStep() {
        val last = ONBOARDING_STEPS.lastIndex
        assertEquals(last, clampedOnboardingStep(last + 1, ONBOARDING_STEPS.size))
        assertEquals(last, clampedOnboardingStep(Int.MAX_VALUE, ONBOARDING_STEPS.size))
    }

    @Test
    fun validStepIsPreservedAndEmptyDefinitionsHaveSafeFallback() {
        assertEquals(2, clampedOnboardingStep(2, 4))
        assertEquals(0, clampedOnboardingStep(42, 0))
        assertEquals(0, clampedOnboardingStep(-42, 0))
    }
}
