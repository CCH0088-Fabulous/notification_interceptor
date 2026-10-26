package dev.poc.notifinterceptor.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationDeduplicatorTest {

    private val dedup = NotificationDeduplicator(maxEntries = 4)

    @Test
    fun `首次投递需要处理`() {
        assertTrue(dedup.shouldProcess(testSnapshot()))
    }

    @Test
    fun `内容与 postTime 完全相同的重复回调被忽略`() {
        val snapshot = testSnapshot()
        assertTrue(dedup.shouldProcess(snapshot))
        assertFalse(dedup.shouldProcess(snapshot))
    }

    @Test
    fun `内容更新的通知仍会处理`() {
        assertTrue(dedup.shouldProcess(testSnapshot(text = "第一版")))
        assertTrue(dedup.shouldProcess(testSnapshot(text = "第二版")))
    }

    @Test
    fun `重新发出（postTime 变化）仍会处理`() {
        assertTrue(dedup.shouldProcess(testSnapshot(postTime = 1000L)))
        assertTrue(dedup.shouldProcess(testSnapshot(postTime = 2000L)))
    }

    @Test
    fun `不同 key 互不影响`() {
        assertTrue(dedup.shouldProcess(testSnapshot(key = "k1")))
        assertTrue(dedup.shouldProcess(testSnapshot(key = "k2")))
        assertFalse(dedup.shouldProcess(testSnapshot(key = "k1")))
    }

    @Test
    fun `容量上限内不会误杀最近的通知`() {
        repeat(4) { index ->
            assertTrue(dedup.shouldProcess(testSnapshot(key = "k$index", postTime = index.toLong())))
        }
        // 最旧的 k0 被淘汰后再次出现，应重新处理
        assertTrue(dedup.shouldProcess(testSnapshot(key = "k0", postTime = 1000L)))
    }

    @Test
    fun `多行文本变化会被视为更新`() {
        assertTrue(dedup.shouldProcess(testSnapshot(textLines = listOf("a"))))
        assertTrue(dedup.shouldProcess(testSnapshot(textLines = listOf("a", "b"))))
    }
}
