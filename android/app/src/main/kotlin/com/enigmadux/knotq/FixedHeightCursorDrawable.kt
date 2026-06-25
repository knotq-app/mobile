package com.enigmadux.knotq

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import kotlin.math.min

internal class FixedHeightCursorDrawable(
    color: Int,
    var maxHeightPx: Int,
    private val widthPx: Int
) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }

    override fun draw(canvas: Canvas) {
        val cursorHeight = min(maxHeightPx, bounds.height())
        val radius = widthPx / 2f
        canvas.drawRoundRect(
            bounds.left.toFloat(),
            bounds.top.toFloat(),
            (bounds.left + widthPx).toFloat(),
            (bounds.top + cursorHeight).toFloat(),
            radius,
            radius,
            paint
        )
    }

    override fun setAlpha(alpha: Int) {
        paint.alpha = alpha
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    override fun getIntrinsicWidth(): Int = widthPx
}
