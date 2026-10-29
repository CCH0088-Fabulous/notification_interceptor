package dev.poc.notifgen

/**
 * 渠道选择规则（纯 Kotlin，可 JVM 单测）。
 *
 * 默认：应保留的类别用 IMPORTANCE_DEFAULT（会响），应拦截的用 IMPORTANCE_LOW（不响）。
 * 这会让"拦截 = 静音"变成假象，所以额外提供**响铃模式**：噪声类别改用一个
 * 独立的高重要度渠道，用来验证"被拦截的通知其实已经响过了"。
 *
 * 横幅模式单独使用 IMPORTANCE_HIGH 与 `_banner` 渠道，优先于响铃模式。
 * 已创建渠道的重要度不能由应用提升，所以两种模式均使用独立渠道。
 */
object GeneratorChannels {

    const val LOUD_SUFFIX = "_loud"
    const val BANNER_SUFFIX = "_banner"
    // Technical container, not a generated category or a ground-truth sample.
    const val BANNER_SUMMARY_CHANNEL = "gen_banner_summary"

    // 与 android.app.NotificationManager.IMPORTANCE_LOW / IMPORTANCE_DEFAULT 一致。
    const val IMPORTANCE_LOW = 2
    const val IMPORTANCE_DEFAULT = 3
    const val IMPORTANCE_HIGH = 4

    fun channelIdFor(category: Category, loud: Boolean = false, headsUp: Boolean = false): String = when {
        headsUp -> "${category.channelId}$BANNER_SUFFIX"
        loud && !category.keep -> "${category.channelId}$LOUD_SUFFIX"
        else -> category.channelId
    }

    fun nameFor(category: Category, loud: Boolean = false, headsUp: Boolean = false): String = when {
        headsUp -> "${category.channelName}（横幅）"
        loud && !category.keep -> "${category.channelName}（响铃）"
        else -> category.channelName
    }

    fun importanceFor(category: Category, loud: Boolean = false, headsUp: Boolean = false): Int = when {
        headsUp -> IMPORTANCE_HIGH
        category.keep || loud -> IMPORTANCE_DEFAULT
        else -> IMPORTANCE_LOW
    }
}
