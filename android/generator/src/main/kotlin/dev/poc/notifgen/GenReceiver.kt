package dev.poc.notifgen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * adb 驱动入口，供端到端脚本使用。
 *
 * ```
 * adb shell am broadcast -n dev.poc.notifgen/.GenReceiver \
 *   -a dev.poc.notifgen.POST --ei count 20 --el seed 7
 * adb shell am broadcast -n dev.poc.notifgen/.GenReceiver -a dev.poc.notifgen.VERIFY
 * ```
 */
class GenReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        Generator.ensureChannels(context)
        val generator = Generator(context)
        when (intent.action) {
            ACTION_POST -> {
                intent.getStringExtra(EXTRA_SEED)?.toLongOrNull()?.let { generator.reseed(it) }
                generator.post(
                    count = intent.getIntExtra(EXTRA_COUNT, 1),
                    categoryId = intent.getStringExtra(EXTRA_CATEGORY),
                    delayMs = intent.getLongExtra(EXTRA_DELAY, 0L),
                    loud = intent.getBooleanExtra(EXTRA_LOUD, false),
                )
            }

            ACTION_CLEAR -> generator.clearAll()
            ACTION_VERIFY -> generator.verify()
            else -> Unit
        }
    }

    companion object {
        const val ACTION_POST = "dev.poc.notifgen.POST"
        const val ACTION_CLEAR = "dev.poc.notifgen.CLEAR"
        const val ACTION_VERIFY = "dev.poc.notifgen.VERIFY"

        const val EXTRA_COUNT = "count"
        const val EXTRA_CATEGORY = "category"
        const val EXTRA_SEED = "seed"
        const val EXTRA_DELAY = "delay"

        /** true 时噪声类别用高重要度渠道发布，用于验证"被拦截的通知其实已经响过"。 */
        const val EXTRA_LOUD = "loud"
    }
}
