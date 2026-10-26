package dev.poc.notifgen

/**
 * 通知 tag 约定：`gen_<category>_<sequence>`。
 *
 * 端到端脚本靠它区分"这是生成器真实发出的通知"还是"系统自动分组的聚合通知"
 * （后者 tag 形如 `0|pkg|g:Aggregate_...`，即使继承了渠道 id 也不能算作一条）。
 * 纯 Kotlin，无 android 依赖，可 JVM 单测。
 */
object GeneratorTags {

    const val PREFIX = "gen_"

    fun forCategory(category: Category, sequence: Int): String = "$PREFIX${category.id}_$sequence"

    fun categoryOf(tag: String): String {
        val trimmed = tag.removePrefix(PREFIX)
        val index = trimmed.lastIndexOf('_')
        return if (index > 0) trimmed.substring(0, index) else UNKNOWN
    }

    fun isGenerated(tag: String?): Boolean = tag?.startsWith(PREFIX) == true

    const val UNKNOWN = "unknown"
}
