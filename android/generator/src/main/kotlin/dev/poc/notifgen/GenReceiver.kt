package dev.poc.notifgen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

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
                try {
                    readSeed(intent)?.let { generator.reseed(it) }
                    generator.post(
                        count = intent.getIntExtra(EXTRA_COUNT, 1),
                        categoryId = intent.getStringExtra(EXTRA_CATEGORY),
                        delayMs = intent.getLongExtra(EXTRA_DELAY, 0L),
                        loud = intent.getBooleanExtra(EXTRA_LOUD, false),
                        realistic = intent.getBooleanExtra(EXTRA_REALISTIC, false),
                        headsUp = intent.getBooleanExtra(EXTRA_HEADS_UP, false),
                    )
                } catch (error: IllegalArgumentException) {
                    Log.w(NoticeCorpus.TAG_LOG, "GEN|rejected|-|-|FAILED|${error.message}")
                }
            }

            ACTION_CLEAR -> generator.clearAll()
            ACTION_VERIFY -> generator.verify()
            else -> Unit
        }
    }

    // adb --el 传 Long；同时兼容早期使用 --es 传入的字符串 seed。
    @Suppress("DEPRECATION")
    private fun readSeed(intent: Intent): Long? = when (val value = intent.extras?.get(EXTRA_SEED)) {
        is Long -> value
        is Int -> value.toLong()
        is String -> value.toLongOrNull()
        else -> null
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

        /** 手工仿真可开启；默认保持 E2E 的一条投递对应一条独立通知。 */
        const val EXTRA_REALISTIC = "realistic"

        /** Opt-in high-importance channel; existing broadcast defaults remain unchanged. */
        const val EXTRA_HEADS_UP = "headsUp"
    }
}
