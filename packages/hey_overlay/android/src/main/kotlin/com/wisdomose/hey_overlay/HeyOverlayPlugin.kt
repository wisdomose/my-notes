package com.wisdomose.hey_overlay

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel "hey_overlay". Registered in every engine (the UI and the
 * background voice service); all of them drive the same [ListeningOverlay].
 */
class HeyOverlayPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "hey_overlay")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canDraw" -> result.success(Settings.canDrawOverlays(context))
            "openPermissionSettings" -> {
                val intent = Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                result.success(null)
            }
            "show" -> {
                val state = when (call.argument<String>("state")) {
                    "transcribing" -> ListeningOverlay.State.TRANSCRIBING
                    "saved" -> ListeningOverlay.State.SAVED
                    "nothing" -> ListeningOverlay.State.NOTHING
                    "failed" -> ListeningOverlay.State.FAILED
                    else -> ListeningOverlay.State.LISTENING
                }
                ListeningOverlay.get(context).show(
                    state,
                    call.argument<String>("text") ?: "",
                    (call.argument<Double>("level") ?: 0.0).toFloat(),
                )
                result.success(null)
            }
            "isShowing" -> result.success(ListeningOverlay.get(context).isShowing)
            "hide" -> {
                ListeningOverlay.get(context).hide()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}

internal fun Context.dp(v: Float) = v * resources.displayMetrics.density

internal val isAtLeastS get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
