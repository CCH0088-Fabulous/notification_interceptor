package dev.poc.notifgen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GeneratorChannelsTest {
    @Test
    fun `横幅开关关闭保持所有类别原本的渠道和提醒级别`() {
        NoticeCorpus.CATEGORIES.forEach { category ->
            assertEquals(category.channelId, GeneratorChannels.channelIdFor(category))
            assertEquals(if (category.keep) 3 else 2, GeneratorChannels.importanceFor(category))
            assertEquals(if (category.keep) category.channelId else "${category.channelId}_loud",
                GeneratorChannels.channelIdFor(category, loud = true))
            assertEquals(3, GeneratorChannels.importanceFor(category, loud = true))
        }
    }

    @Test
    fun `横幅覆盖保留和拦截类别且优先于响铃模式`() {
        NoticeCorpus.CATEGORIES.forEach { category ->
            listOf(false, true).forEach { loud ->
                assertEquals("${category.channelId}_banner",
                    GeneratorChannels.channelIdFor(category, loud, headsUp = true))
                assertEquals(4, GeneratorChannels.importanceFor(category, loud, headsUp = true))
                assertTrue(GeneratorChannels.nameFor(category, loud, headsUp = true).contains("横幅"))
            }
        }
    }
}
