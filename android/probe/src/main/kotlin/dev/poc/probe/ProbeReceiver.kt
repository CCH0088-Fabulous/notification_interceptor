package dev.poc.probe

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 通过 adb broadcast 驱动的测试探针。
 *
 * 例：
 * ```
 * adb shell am broadcast -n dev.poc.probe/.ProbeReceiver \
 *   -a dev.poc.probe.POST --es scenario ongoing --es tag t1 --es title 秒杀
 * adb shell am broadcast -n dev.poc.probe/.ProbeReceiver -a dev.poc.probe.VERIFY
 * ```
 */
class ProbeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        ProbeNotifications.ensureChannels(context)
        val probe = ProbeNotifications(context)

        when (intent.action) {
            ACTION_POST -> probe.post(
                scenario = intent.getStringExtra(EXTRA_SCENARIO) ?: ProbeNotifications.SCENARIO_BASIC,
                tag = intent.getStringExtra(EXTRA_TAG) ?: "probe",
                title = intent.getStringExtra(EXTRA_TITLE) ?: "Probe",
                text = intent.getStringExtra(EXTRA_TEXT) ?: "probe body",
                id = intent.getIntExtra(EXTRA_ID, 2001),
                count = intent.getIntExtra(EXTRA_COUNT, 1),
                delayMs = intent.getLongExtra(EXTRA_DELAY, 0L),
            )
            ACTION_VERIFY -> probe.verify(intent.getStringExtra(EXTRA_TAG))
            ACTION_CLEAR -> probe.cancelAll()
            else -> Unit
        }
    }

    companion object {
        const val ACTION_POST = "dev.poc.probe.POST"
        const val ACTION_VERIFY = "dev.poc.probe.VERIFY"
        const val ACTION_CLEAR = "dev.poc.probe.CLEAR"

        const val EXTRA_SCENARIO = "scenario"
        const val EXTRA_TAG = "tag"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_ID = "id"
        const val EXTRA_COUNT = "count"
        const val EXTRA_DELAY = "delay"
    }
}
