package com.wisdomose.hey_overlay

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.RoundedCorner
import android.view.View
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * A full-screen, touch-through window over other apps: glowing screen edges
 * plus a status bubble near the bottom. One per process; must be used on the
 * main thread (Flutter method calls already arrive there).
 */
@SuppressLint("StaticFieldLeak") // holds the application context only
class ListeningOverlay private constructor(private val context: Context) {
    enum class State { LISTENING, TRANSCRIBING, SAVED, NOTHING }

    companion object {
        // Palette from the app's design canvas.
        const val AMBER = 0xFFF5B841.toInt()
        const val GREEN = 0xFF6FD08C.toInt()
        const val MUTED = 0xFF9BA39E.toInt()
        private const val SURFACE = 0xFF1A1F1D.toInt()
        private const val BORDER = 0xFF2A302D.toInt()
        private const val TEXT = 0xFFECEFEA.toInt()
        private const val TEXT_SOFT = 0xFFB8BFBA.toInt()

        /** Removed automatically if nobody updates it for this long. */
        private const val WATCHDOG_MS = 3 * 60 * 1000L

        @Volatile private var instance: ListeningOverlay? = null

        fun get(context: Context): ListeningOverlay =
            instance ?: synchronized(this) {
                instance ?: ListeningOverlay(context.applicationContext).also { instance = it }
            }
    }

    private val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    private val main = Handler(Looper.getMainLooper())
    private val watchdog = Runnable { hide() }

    private var root: FrameLayout? = null
    private lateinit var glow: EdgeGlowView
    private lateinit var bubble: LinearLayout
    private lateinit var icon: StatusIconView
    private lateinit var title: TextView
    private lateinit var subtitle: TextView
    private var pulse: ValueAnimator? = null
    private var state: State? = null
    private var level = 0f

    /** True while the window is attached and laid out on screen. */
    val isShowing get() = root?.isAttachedToWindow == true

    fun show(state: State, text: String, level: Float) {
        if (!Settings.canDrawOverlays(context)) {
            Log.w("HeyOverlay", "not allowed to draw over other apps")
            return
        }
        if (root == null && !attach()) return
        main.removeCallbacks(watchdog)
        main.postDelayed(watchdog, WATCHDOG_MS)

        this.level = level.coerceIn(0f, 1f)
        if (state != this.state) {
            this.state = state
            applyState(state)
        }
        icon.level = this.level
        // Only real content under the title: your words, or the note title.
        val sub = if (state == State.NOTHING) "" else text
        subtitle.text = sub
        subtitle.visibility = if (sub.isBlank()) View.GONE else View.VISIBLE
    }

    fun hide() {
        main.removeCallbacks(watchdog)
        val view = root ?: return
        root = null
        state = null
        pulse?.cancel()
        pulse = null
        icon.stop()
        view.animate().alpha(0f).setDuration(200).withEndAction {
            try {
                wm.removeView(view)
            } catch (_: Exception) {
            }
        }.start()
    }

    private fun attach(): Boolean {
        val frame = FrameLayout(context)
        glow = EdgeGlowView(context)
        frame.addView(glow, FrameLayout.LayoutParams(-1, -1))
        bubble = buildBubble()
        val bottom = navBarHeight() + context.dp(32f).toInt()
        frame.addView(
            bubble,
            // Fixed width (screen minus margins, at most 360 dp): with
            // wrap_content the bubble kept the previous state's width and
            // cut longer titles off ("Didn't ca…").
            FrameLayout.LayoutParams(bubbleWidth(), -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                val side = context.dp(16f).toInt()
                setMargins(side, 0, side, bottom)
            },
        )

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT,
        ).apply {
            // Android 12+ only passes touches through other apps' overlays
            // at 80% opacity or less.
            alpha = 0.8f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            setTitle("Hey Notes listening")
        }
        if (isAtLeastS) {
            frame.setOnApplyWindowInsetsListener { v, insets ->
                insets.getRoundedCorner(RoundedCorner.POSITION_BOTTOM_LEFT)?.let {
                    glow.cornerRadius = it.radius.toFloat()
                }
                v.onApplyWindowInsets(insets)
            }
        }
        return try {
            wm.addView(frame, params)
            root = frame
            glow.alpha = 0f
            glow.animate().alpha(1f).setDuration(250).start()
            bubble.translationY = context.dp(120f)
            bubble.alpha = 0f
            bubble.animate().translationY(0f).alpha(1f).setDuration(320)
                .setInterpolator(DecelerateInterpolator()).start()
            true
        } catch (e: Exception) {
            Log.e("HeyOverlay", "could not add the overlay window", e)
            false
        }
    }

    private fun buildBubble(): LinearLayout {
        val box = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                setColor(SURFACE)
                cornerRadius = context.dp(28f)
                setStroke(context.dp(1f).toInt(), BORDER)
            }
            val h = context.dp(14f).toInt()
            setPadding(h, context.dp(12f).toInt(), context.dp(20f).toInt(), context.dp(12f).toInt())
        }
        icon = StatusIconView(context)
        val size = context.dp(44f).toInt()
        box.addView(icon, LinearLayout.LayoutParams(size, size))

        val texts = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        title = TextView(context).apply {
            setTextColor(TEXT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        subtitle = TextView(context).apply {
            setTextColor(TEXT_SOFT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 2
        }
        texts.addView(title)
        texts.addView(subtitle)
        box.addView(
            texts,
            LinearLayout.LayoutParams(0, -2, 1f).apply { marginStart = context.dp(14f).toInt() },
        )
        return box
    }

    private fun applyState(state: State) {
        pulse?.cancel()
        pulse = null
        when (state) {
            State.LISTENING -> {
                title.text = "Listening…"
                // Live text: keep the newest words visible.
                subtitle.ellipsize = TextUtils.TruncateAt.START
                glow.color = AMBER
                icon.mode = StatusIconView.Mode.MIC
                startPulse(900)
            }
            State.TRANSCRIBING -> {
                title.text = "Transcribing…"
                subtitle.ellipsize = TextUtils.TruncateAt.START
                glow.color = AMBER
                icon.mode = StatusIconView.Mode.SPINNER
                startPulse(1800)
            }
            State.SAVED -> {
                title.text = "Saved"
                subtitle.ellipsize = TextUtils.TruncateAt.END
                glow.color = GREEN
                glow.intensity = 1f
                icon.mode = StatusIconView.Mode.CHECK
            }
            State.NOTHING -> {
                title.text = "Didn’t catch that"
                subtitle.ellipsize = TextUtils.TruncateAt.END
                glow.color = MUTED
                glow.intensity = 0.6f
                icon.mode = StatusIconView.Mode.NOTHING
            }
        }
    }

    /** Breathing glow; louder speech makes it brighter while listening. */
    private fun startPulse(periodMs: Long) {
        pulse = ValueAnimator.ofFloat(0.55f, 1f).apply {
            duration = periodMs
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            addUpdateListener {
                val base = it.animatedValue as Float
                glow.intensity = if (state == State.LISTENING) {
                    (base * (0.75f + 0.25f * level) + 0.35f * level).coerceAtMost(1f)
                } else {
                    base * 0.8f
                }
            }
            start()
        }
    }

    private fun bubbleWidth(): Int {
        val screen = context.resources.displayMetrics.widthPixels
        return minOf(screen - context.dp(32f).toInt(), context.dp(360f).toInt())
    }

    @SuppressLint("DiscouragedApi", "InternalInsetResource")
    private fun navBarHeight(): Int {
        val id = context.resources.getIdentifier("navigation_bar_height", "dimen", "android")
        return if (id > 0) context.resources.getDimensionPixelSize(id) else 0
    }
}
