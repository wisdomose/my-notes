package com.wisdomose.hey_overlay

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.View
import android.view.animation.LinearInterpolator

/**
 * Soft glow around the screen edges: stacked rounded-rect strokes that fade
 * inwards, scaled by [intensity] (0..1).
 */
internal class EdgeGlowView(context: Context) : View(context) {
    var color = ListeningOverlay.AMBER
        set(value) { field = value; invalidate() }
    var intensity = 1f
        set(value) { field = value.coerceIn(0f, 1f); invalidate() }

    /** The screen's corner radius; replaced by the real one on Android 12+. */
    var cornerRadius = context.dp(36f)
        set(value) { field = value; invalidate() }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = context.dp(2.2f)
    }
    private val rect = RectF()
    private val layers = 16
    private val step = context.dp(1.6f)

    override fun onDraw(canvas: Canvas) {
        for (i in 0 until layers) {
            val t = i / (layers - 1f)
            val a = (255 * (1 - t) * (1 - t) * intensity).toInt()
            if (a <= 0) continue
            paint.color = Color.argb(a, Color.red(color), Color.green(color), Color.blue(color))
            val inset = step * i + paint.strokeWidth / 2
            rect.set(inset, inset, width - inset, height - inset)
            val r = (cornerRadius - inset).coerceAtLeast(0f)
            canvas.drawRoundRect(rect, r, r, paint)
        }
    }
}

/** 44 dp status icon: mic (pulses with [level]), spinner, check, or "×". */
internal class StatusIconView(context: Context) : View(context) {
    enum class Mode { MIC, SPINNER, CHECK, NOTHING, FAILED }

    var mode = Mode.MIC
        set(value) {
            field = value
            if (value == Mode.SPINNER) spin() else stop()
            invalidate()
        }
    var level = 0f
        set(value) { field = value; if (mode == Mode.MIC) invalidate() }

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val path = Path()
    private val oval = RectF()
    private var angle = 0f
    private var spinner: ValueAnimator? = null

    private val ink = 0xFF0B0D0C.toInt()

    fun stop() {
        spinner?.cancel()
        spinner = null
    }

    private fun spin() {
        if (spinner != null) return
        spinner = ValueAnimator.ofFloat(0f, 360f).apply {
            duration = 900
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener { angle = it.animatedValue as Float; invalidate() }
            start()
        }
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = minOf(width, height) / 2f
        val u = r / 22f // drawing unit: icon geometry is in a 44-unit box
        when (mode) {
            Mode.MIC -> {
                // Halo that grows with the voice level.
                fill.color = Color.argb((70 * level).toInt() + 30, 0xF5, 0xB8, 0x41)
                canvas.drawCircle(cx, cy, r, fill)
                fill.color = ListeningOverlay.AMBER
                canvas.drawCircle(cx, cy, r * (0.78f + 0.22f * level), fill)
                drawMic(canvas, cx, cy, u)
            }
            Mode.SPINNER -> {
                stroke.color = Color.argb(60, 0xF5, 0xB8, 0x41)
                stroke.strokeWidth = 3 * u
                oval.set(cx - r + 3 * u, cy - r + 3 * u, cx + r - 3 * u, cy + r - 3 * u)
                canvas.drawOval(oval, stroke)
                stroke.color = ListeningOverlay.AMBER
                canvas.drawArc(oval, angle - 90, 100f, false, stroke)
            }
            Mode.CHECK -> {
                fill.color = ListeningOverlay.GREEN
                canvas.drawCircle(cx, cy, r, fill)
                stroke.color = ink
                stroke.strokeWidth = 3.2f * u
                path.reset()
                path.moveTo(cx - 8 * u, cy + 0.5f * u)
                path.lineTo(cx - 2.5f * u, cy + 6 * u)
                path.lineTo(cx + 8.5f * u, cy - 6 * u)
                canvas.drawPath(path, stroke)
            }
            Mode.FAILED -> {
                // "!" on the danger colour.
                fill.color = ListeningOverlay.DANGER
                canvas.drawCircle(cx, cy, r, fill)
                stroke.color = ink
                stroke.strokeWidth = 3.2f * u
                canvas.drawLine(cx, cy - 8 * u, cx, cy + 2 * u, stroke)
                fill.color = ink
                canvas.drawCircle(cx, cy + 7.5f * u, 2f * u, fill)
            }
            Mode.NOTHING -> {
                fill.color = 0xFF3A403C.toInt()
                canvas.drawCircle(cx, cy, r, fill)
                stroke.color = ListeningOverlay.MUTED
                stroke.strokeWidth = 2.8f * u
                canvas.drawLine(cx - 6 * u, cy - 6 * u, cx + 6 * u, cy + 6 * u, stroke)
                canvas.drawLine(cx + 6 * u, cy - 6 * u, cx - 6 * u, cy + 6 * u, stroke)
            }
        }
    }

    /** The app's mic glyph: capsule, cradle arc and stem. */
    private fun drawMic(canvas: Canvas, cx: Float, cy: Float, u: Float) {
        stroke.color = ink
        stroke.strokeWidth = 2.4f * u
        oval.set(cx - 4 * u, cy - 11 * u, cx + 4 * u, cy + 3 * u)
        canvas.drawRoundRect(oval, 4 * u, 4 * u, stroke)
        oval.set(cx - 8.5f * u, cy - 8 * u, cx + 8.5f * u, cy + 7.5f * u)
        canvas.drawArc(oval, 10f, 160f, false, stroke)
        canvas.drawLine(cx, cy + 7.5f * u, cx, cy + 11.5f * u, stroke)
    }
}
