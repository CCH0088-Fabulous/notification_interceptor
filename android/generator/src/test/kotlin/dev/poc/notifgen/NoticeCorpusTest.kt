package dev.poc.notifgen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/**
 * 语料与 tag 约定的纯 JVM 测试。端到端脚本依赖 tag 格式判断"谁留下了"，
 * 所以这层契约必须有测试兜住。
 */
class NoticeCorpusTest {

    @Test
    fun `同 seed 产出完全一致的序列`() {
        val first = sequence(seed = 42L, count = 20)
        val second = sequence(seed = 42L, count = 20)

        assertEquals(first, second)
        assertEquals(20, first.size)
    }

    @Test
    fun `不同 seed 会产出不同序列`() {
        val a = sequence(seed = 1L, count = 20)
        val b = sequence(seed = 2L, count = 20)

        assertTrue(a != b)
    }

    @Test
    fun `每类语料都能产出非空且带渠道的文案`() {
        val corpus = NoticeCorpus(Random(7))
        NoticeCorpus.CATEGORIES.forEach { category ->
            val draft = corpus.next(category)
            assertEquals(category, draft.category)
            assertTrue("${category.id} title 为空", draft.title.isNotBlank())
            assertTrue("${category.id} text 为空", draft.text.isNotBlank())
            assertTrue("${category.id} 渠道不符合约定", category.channelId.startsWith(GeneratorTags.PREFIX))
        }
    }

    @Test
    fun `保留与拦截两类都有足够样本`() {
        val corpus = NoticeCorpus(Random(3))
        val picked = (1..500).map { corpus.pickCategory() }

        assertEquals(NoticeCorpus.CATEGORIES.toSet(), picked.toSet())
        assertTrue(picked.any { it.keep })
        assertTrue(picked.any { !it.keep })
    }

    @Test
    fun `tag 可以还原出类别，聚合通知不会被误认`() {
        val category = NoticeCorpus.CATEGORIES.first { it.id == "chat" }

        assertEquals("gen_chat_12", GeneratorTags.forCategory(category, 12))
        assertEquals("chat", GeneratorTags.categoryOf("gen_chat_12"))
        assertTrue(GeneratorTags.isGenerated("gen_chat_12"))
        assertFalse(GeneratorTags.isGenerated("0|dev.poc.notifgen|g:Aggregate_AlertingSection"))
        assertEquals(GeneratorTags.UNKNOWN, GeneratorTags.categoryOf("broken"))
    }

    @Test
    fun `响铃模式只抬高噪声类别，保留类别的渠道不变`() {
        val keep = NoticeCorpus.CATEGORIES.first { it.id == "code" }
        val drop = NoticeCorpus.CATEGORIES.first { it.id == "promo" }

        // 默认：保留类会响，噪声类不响
        assertEquals("gen_code", GeneratorChannels.channelIdFor(keep))
        assertEquals(GeneratorChannels.IMPORTANCE_DEFAULT, GeneratorChannels.importanceFor(keep))
        assertEquals(GeneratorChannels.IMPORTANCE_LOW, GeneratorChannels.importanceFor(drop))

        // 响铃模式：噪声类换到独立高重要度渠道，保留类保持不变
        assertEquals("gen_promo_loud", GeneratorChannels.channelIdFor(drop, loud = true))
        assertEquals(GeneratorChannels.IMPORTANCE_DEFAULT, GeneratorChannels.importanceFor(drop, loud = true))
        assertEquals(GeneratorChannels.IMPORTANCE_DEFAULT, GeneratorChannels.importanceFor(keep, loud = true))
        assertEquals("gen_code", GeneratorChannels.channelIdFor(keep, loud = true))
    }

    private fun sequence(seed: Long, count: Int): List<String> {
        val corpus = NoticeCorpus(Random(seed))
        return (1..count).map {
            val draft = corpus.next()
            "${draft.category.id}|${draft.title}|${draft.text}"
        }
    }
}
