package dev.poc.notifgen

/**
 * 渠道选择规则（纯 Kotlin，可 JVM 单测）。
 *
 * 默认：应保留的类别用 IMPORTANCE_DEFAULT（会响），应拦截的用 IMPORTANCE_LOW（不响）。
 * 这会让"拦截 = 静音"变成假象，所以额外提供**响铃模式**：噪声类别改用一个
 * 独立的高重要度渠道，用来验证"被拦截的通知其实已经响过了"。
 *
 * 渠道只能创建、不能改重要度，因此响铃模式必须用不同的渠道 id（加 `_loud` 后缀）。
 */
object GeneratorChannels {

    const val LOUD_SUFFIX = "_loud"

    // 与 android.app.NotificationManager.IMPORTANCE_LOW / IMPORTANCE_DEFAULT 一致。
    const val IMPORTANCE_LOW = 2
    const val IMPORTANCE_DEFAULT = 3

    fun channelIdFor(category: Category, loud: Boolean = false): String =
        if (loud && !category.keep) "${category.channelId}$LOUD_SUFFIX" else category.channelId

    fun nameFor(category: Category, loud: Boolean = false): String =
        if (loud && !category.keep) "${category.channelName}（响铃）" else category.channelName

    fun importanceFor(category: Category, loud: Boolean = false): Int =
        if (category.keep || loud) IMPORTANCE_DEFAULT else IMPORTANCE_LOW
}
