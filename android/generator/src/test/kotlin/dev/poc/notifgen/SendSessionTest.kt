package dev.poc.notifgen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SendSessionTest {
    private fun config(mode: SendMode, count: Int = 10) =
        SendConfiguration(mode, count, categoryIds = setOf("chat", "code"), headsUp = true)

    @Test
    fun `单条配置只投递一次且不会遗留后续任务`() {
        val session = SendSession()
        val run = session.start(config(SendMode.SINGLE))
        assertEquals(1, session.remainingCount)
        assertFalse(session.recordSent(run))
        assertEquals(1, session.sentCount)
        assertFalse(session.isRunning)
        assertFalse(session.recordSent(run))
        assertEquals(1, session.sentCount)
    }

    @Test
    fun `定量发送按自定义数量完成且全部沿用同一横幅配置`() {
        val session = SendSession()
        val configuration = config(SendMode.BATCH, count = 3)
        val run = session.start(configuration)
        assertTrue(session.recordSent(run))
        assertEquals(2, session.remainingCount)
        assertTrue(session.activeRun!!.configuration.headsUp)
        assertTrue(session.recordSent(run))
        assertEquals(1, session.remainingCount)
        assertFalse(session.recordSent(run))
        assertEquals(3, session.sentCount)
        assertFalse(session.isRunning)
    }

    @Test
    fun `持续发送不受定量次数限制且停止后旧回调不能续发`() {
        val session = SendSession()
        val run = session.start(config(SendMode.CONTINUOUS))
        repeat(150) { assertTrue(session.recordSent(run)) }
        assertNull(session.remainingCount)
        session.stop()
        assertFalse(session.isActive(run))
        assertFalse(session.recordSent(run))
        assertEquals(150, session.sentCount)
    }

    @Test
    fun `替换任务后旧回调既不计数也不延续新任务`() {
        val session = SendSession()
        val old = session.start(config(SendMode.CONTINUOUS))
        session.recordSent(old)
        val new = session.start(config(SendMode.BATCH, count = 2))
        assertNotEquals(old.id, new.id)
        assertFalse(session.recordSent(old))
        assertEquals(0, session.sentCount)
        assertEquals(2, session.remainingCount)
        assertTrue(session.recordSent(new))
    }

    @Test
    fun `启动时复制类别选择防止配置被后续修改`() {
        val selected = mutableSetOf("chat", "group")
        val configuration = SendConfiguration(SendMode.BATCH, categoryIds = selected, headsUp = true)
        selected.clear()
        selected.add("spam")
        assertEquals(setOf("chat", "group"), configuration.categoryIds)
        assertTrue(configuration.headsUp)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `定量数量零被拒绝而非静默改为一`() {
        config(SendMode.BATCH, 0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `定量数量超过上限被拒绝`() {
        config(SendMode.BATCH, 101)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `空类别配置不能启动发送`() {
        SendConfiguration(SendMode.SINGLE, categoryIds = emptySet())
    }
}
