package com.enigmadux.knotq

import android.content.Context
import android.widget.FrameLayout
import android.widget.LinearLayout

internal interface LayoutRequestTransactionHost {
    fun setKnotQLayoutSuppressed(suppressed: Boolean)
}

/**
 * Root container used while the Activity replaces its main content tree.
 *
 * Android only exposes ViewGroup.suppressLayout publicly from API 29, while
 * KnotQ still supports API 26+. On older devices, dropping layout requests at
 * this boundary gives the same single-publication behavior without hiding the
 * content (which would create a blank-frame flicker).
 */
internal class LayoutTransactionFrameLayout(context: Context) : FrameLayout(context), LayoutRequestTransactionHost {
    private var knotqLayoutSuppressed = false

    override fun setKnotQLayoutSuppressed(suppressed: Boolean) {
        knotqLayoutSuppressed = suppressed
    }

    override fun requestLayout() {
        if (!knotqLayoutSuppressed) super.requestLayout()
    }
}

/** LinearLayout counterpart for lists that rebuild their children in place. */
internal class LayoutTransactionLinearLayout(context: Context) : LinearLayout(context), LayoutRequestTransactionHost {
    private var knotqLayoutSuppressed = false

    override fun setKnotQLayoutSuppressed(suppressed: Boolean) {
        knotqLayoutSuppressed = suppressed
    }

    override fun requestLayout() {
        if (!knotqLayoutSuppressed) super.requestLayout()
    }
}
