package dev.poc.notifgen

/** The Android adapter supplies snapshots from NotificationManager.activeNotifications. */
data class BannerChild(
    val identity: NoticeIdentity,
    val title: String,
    val text: String,
    val groupKey: String?,
    val isSummary: Boolean = false,
    val postedAt: Long = 0L,
)

sealed class BannerSummaryPlan {
    /** No real child remains, so the adapter should remove the summary. */
    object Cancel : BannerSummaryPlan()

    /** Notify using the stable summary identity to either create or update it. */
    data class Upsert(val childCount: Int, val lines: List<String>) : BannerSummaryPlan()
}

/**
 * A single app group avoids creating many sparse groups. Summary content comes only from currently
 * active children, not from the total number of generation attempts or a cached send history.
 */
object BannerGrouping {
    const val GROUP_KEY = "dev.poc.notifgen.banner"
    const val SUMMARY_TAG = "banner_summary"
    const val SUMMARY_ID = -1
    private const val MAX_LINES = 6
    private const val MAX_LINE_LENGTH = 180
    private val whitespace = Regex("\\s+")

    fun groupKeyFor(headsUp: Boolean): String? = if (headsUp) GROUP_KEY else null

    fun plan(active: List<BannerChild>): BannerSummaryPlan {
        val children = active.asSequence()
            .filter {
                it.groupKey == GROUP_KEY && !it.isSummary &&
                    it.identity.id > 0 && GeneratorTags.isGenerated(it.identity.tag)
            }
            .sortedByDescending { it.postedAt }
            .distinctBy { it.identity }
            .toList()
        if (children.isEmpty()) return BannerSummaryPlan.Cancel
        return BannerSummaryPlan.Upsert(
            childCount = children.size,
            lines = children.take(MAX_LINES).map(::summaryLine),
        )
    }

    private fun summaryLine(child: BannerChild): String {
        val title = child.title.replace(whitespace, " ").trim()
        val text = child.text.replace(whitespace, " ").trim()
        val line = when {
            title.isEmpty() && text.isEmpty() -> "新通知"
            title.isEmpty() -> text
            text.isEmpty() || text == title -> title
            else -> "$title：$text"
        }
        return line.take(MAX_LINE_LENGTH)
    }
}
