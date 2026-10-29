package dev.poc.notifgen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BannerGroupingTest {
    private fun child(
        id: Int,
        title: String = "通知$id",
        text: String = "内容$id",
        group: String? = BannerGrouping.GROUP_KEY,
        timestamp: Long = id.toLong(),
    ) = BannerChild(NoticeIdentity("gen_code_$id", id), title, text, group, postedAt = timestamp)

    private fun summaryPlan(vararg children: BannerChild) =
        BannerGrouping.plan(children.toList()) as BannerSummaryPlan.Upsert

    @Test
    fun `只有横幅模式加入同一个稳定应用分组`() {
        assertNull(BannerGrouping.groupKeyFor(false))
        val keys = NoticeCorpus.CATEGORIES.map { BannerGrouping.groupKeyFor(true) }.toSet()
        assertEquals(setOf(BannerGrouping.GROUP_KEY), keys)
        assertFalse(GeneratorTags.isGenerated(BannerGrouping.SUMMARY_TAG))
        assertTrue(BannerGrouping.SUMMARY_ID < 0)
    }

    @Test
    fun `没有真实子通知或仅剩摘要时取消摘要`() {
        assertEquals(BannerSummaryPlan.Cancel, BannerGrouping.plan(emptyList()))
        val summary = BannerChild(
            NoticeIdentity(BannerGrouping.SUMMARY_TAG, BannerGrouping.SUMMARY_ID),
            "通知生成器", "共3条", BannerGrouping.GROUP_KEY, isSummary = true,
        )
        assertEquals(BannerSummaryPlan.Cancel, BannerGrouping.plan(listOf(summary)))
    }

    @Test
    fun `摘要不会把其他分组和普通模式通知计入存活数量`() {
        val plan = summaryPlan(
            child(1),
            child(2, group = null),
            child(3, group = "other-app-group"),
        )
        assertEquals(1, plan.childCount)
        assertEquals(listOf("通知1：内容1"), plan.lines)
    }

    @Test
    fun `即使摘要标记遗漏也不会把固定摘要或系统聚合当作样本`() {
        val ownSummary = BannerChild(
            NoticeIdentity(BannerGrouping.SUMMARY_TAG, BannerGrouping.SUMMARY_ID),
            "摘要", "内容", BannerGrouping.GROUP_KEY,
        )
        val systemSummary = child(2).copy(identity = NoticeIdentity("0|pkg|g:Aggregate", 2))
        val misidentifiedSummary = child(3).copy(isSummary = true)
        assertEquals(
            BannerSummaryPlan.Cancel,
            BannerGrouping.plan(listOf(ownSummary, systemSummary, misidentifiedSummary)),
        )
    }

    @Test
    fun `同一身份的重复快照只计一次并使用最新内容`() {
        val plan = summaryPlan(
            child(1, text = "旧内容", timestamp = 1),
            child(2, timestamp = 2),
            child(1, text = "最新内容", timestamp = 3),
        )
        assertEquals(2, plan.childCount)
        assertEquals(listOf("通知1：最新内容", "通知2：内容2"), plan.lines)
    }

    @Test
    fun `身份使用tag和id共同判断不会合并不同真实通知`() {
        val original = child(1)
        val otherTag = original.copy(identity = NoticeIdentity("gen_group_1", 1))
        val otherId = original.copy(identity = NoticeIdentity("gen_code_1", 2))
        assertEquals(3, summaryPlan(original, otherTag, otherId).childCount)
        assertNotEquals(original.identity, otherTag.identity)
    }

    @Test
    fun `超过六条只展示最新六行而计数仍包含全部存活通知`() {
        val plan = BannerGrouping.plan((1..12).map { child(it) }) as BannerSummaryPlan.Upsert
        assertEquals(12, plan.childCount)
        assertEquals(6, plan.lines.size)
        assertEquals("通知12：内容12", plan.lines.first())
        assertEquals("通知7：内容7", plan.lines.last())
    }

    @Test
    fun `更新计划只反映当前仍存活的子通知不保留被取消通知`() {
        assertEquals(3, summaryPlan(child(1), child(2), child(3)).childCount)
        val afterRemoval = summaryPlan(child(2))
        assertEquals(1, afterRemoval.childCount)
        assertEquals(listOf("通知2：内容2"), afterRemoval.lines)
        assertEquals(BannerSummaryPlan.Cancel, BannerGrouping.plan(emptyList()))
    }

    @Test
    fun `摘要行压平换行并限制长度且空内容仍有可读占位`() {
        val plan = summaryPlan(
            child(1, title = "群聊\n 小李", text = "已收到\t文件"),
            child(2, title = "", text = ""),
            child(3, title = "长通知", text = "内容".repeat(200)),
        )
        assertEquals(3, plan.childCount)
        assertTrue(plan.lines.all { it.length <= 180 })
        assertTrue(plan.lines.none { '\n' in it || '\t' in it })
        assertTrue(plan.lines.contains("新通知"))
        assertTrue(plan.lines.contains("群聊 小李：已收到 文件"))
    }
}
