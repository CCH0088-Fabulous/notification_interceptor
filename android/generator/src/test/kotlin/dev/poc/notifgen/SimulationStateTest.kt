package dev.poc.notifgen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SimulationStateTest {
    private val chat = NoticeCorpus.CATEGORIES.first { it.id == "chat" }
    private val group = NoticeCorpus.CATEGORIES.first { it.id == "group" }
    private val logistics = NoticeCorpus.CATEGORIES.first { it.id == "logistics" }
    private var sequence = 0

    private fun state(maxMessages: Int = 6, maxConversations: Int = 24) =
        SimulationState({ ++sequence }, maxMessages, maxConversations)

    private fun draft(persona: String = "小李", text: String = "收到", category: Category = chat) =
        Draft(category, persona, persona, text, "小李")

    @Test
    fun `同一会话的后续消息保留通知标识和发送时间`() {
        val state = state()
        val first = state.plan(draft(text = "先开会"), true, 100) { true }
        val second = state.plan(draft(text = "会议室换到三楼"), true, 200) { true }

        assertEquals(first.identity, second.identity)
        assertEquals(listOf("先开会", "会议室换到三楼"), second.messages.map { it.text })
        assertEquals(listOf(100L, 200L), second.messages.map { it.timestamp })
        assertEquals("gen_chat_1", second.identity.tag)
    }

    @Test
    fun `不同会话和不同类别不会合并`() {
        val state = state()
        val direct = state.plan(draft(), true, 100) { true }
        val other = state.plan(draft(persona = "王强"), true, 200) { true }
        val groupNotice = state.plan(draft(category = group), true, 300) { true }

        assertEquals(3, setOf(direct.identity, other.identity, groupNotice.identity).size)
        assertEquals("gen_group_3", groupNotice.identity.tag)
    }

    @Test
    fun `普通测试通知始终独立且不会写入会话历史`() {
        val state = state()
        val first = state.plan(draft(text = "第一条"), true, 100) { true }
        val independent = state.plan(draft(text = "测试消息"), false, 200) { true }
        val another = state.plan(draft(text = "第二个测试"), false, 300) { true }
        val resumed = state.plan(draft(text = "第二条"), true, 400) { true }

        assertNotEquals(first.identity, independent.identity)
        assertNotEquals(independent.identity, another.identity)
        assertEquals(first.identity, resumed.identity)
        assertEquals(listOf("第一条", "第二条"), resumed.messages.map { it.text })
    }

    @Test
    fun `已划走或拦截的会话重新收到消息时使用新标识`() {
        val state = state()
        val old = state.plan(draft(text = "旧消息"), true, 100) { true }
        val new = state.plan(draft(text = "新消息"), true, 200) { false }

        assertNotEquals(old.identity, new.identity)
        assertEquals(listOf("新消息"), new.messages.map { it.text })
    }

    @Test
    fun `历史有上限且不会重复显示群聊发送者前缀`() {
        val state = state(maxMessages = 3)
        var last: PlannedNotice? = null
        repeat(8) { index ->
            last = state.plan(draft("项目群", "小李：消息$index", group), true, index.toLong()) { true }
        }

        assertEquals(listOf("消息5", "消息6", "消息7"), last!!.messages.map { it.text })
        assertTrue(last!!.messages.all { it.sender == "小李" })
    }

    @Test
    fun `清空通知后不再复用旧会话`() {
        val state = state()
        val old = state.plan(draft(), true, 100) { true }
        state.clear()
        val new = state.plan(draft(), true, 200) { true }

        assertNotEquals(old.identity, new.identity)
        assertEquals(1, new.messages.size)
    }

    @Test
    fun `会话数量有界且最近访问的会话仍可继续更新`() {
        val state = state(maxConversations = 2)
        val first = state.plan(draft("会话一"), true, 1) { true }
        val evicted = state.plan(draft("会话二"), true, 2) { true }
        state.plan(draft("会话一"), true, 3) { true }
        state.plan(draft("会话三"), true, 4) { true }
        val kept = state.plan(draft("会话一"), true, 5) { true }
        val recreated = state.plan(draft("会话二"), true, 6) { true }

        assertEquals(first.identity, kept.identity)
        assertNotEquals(evicted.identity, recreated.identity)
    }

    @Test
    fun `物流更新保持原包裹信息且终态结束进度`() {
        val text = "尾号 1234 的包裹将送至菜鸟驿站，取件码 2-3-4567。请以实际到件提醒为准。"
        val steps = LogisticsJourney.steps(draft(text = text, category = logistics))

        assertEquals(listOf(15, 45, 80, 100), steps.map { it.progress })
        assertTrue(steps.dropLast(1).none { it.complete })
        assertTrue(steps.last().complete)
        assertTrue(steps.last().status.contains("尾号 1234"))
        assertTrue(steps.last().status.contains("取件码 2-3-4567"))
        assertTrue(steps.last().status.contains("包裹已到达"))
    }

    @Test
    fun `清空后延迟物流回调失效且新任务不接受旧回调`() {
        val updates = SimulationUpdates()
        val identity = NoticeIdentity("gen_logistics_1", 1)
        val old = updates.start(identity)
        assertTrue(updates.permits(old, true))

        updates.clear()
        assertFalse(updates.permits(old, true))
        val replacement = updates.start(identity)
        assertFalse(updates.permits(old, true))
        updates.finish(old)
        assertTrue(updates.permits(replacement, true))
    }

    @Test
    fun `取消或完成一条物流不会影响其他物流`() {
        val updates = SimulationUpdates()
        val first = updates.start(NoticeIdentity("gen_logistics_1", 1))
        val second = updates.start(NoticeIdentity("gen_logistics_2", 2))

        assertFalse(updates.permits(first, false))
        updates.finish(first)
        assertFalse(updates.permits(first, true))
        assertTrue(updates.permits(second, true))
        updates.finish(second)
        assertFalse(updates.permits(second, true))
    }

    @Test
    fun `另一个生成器清空时旧物流回调即使系统仍显示通知也被作废`() {
        val sharedSession = SimulationSession { ++sequence }
        val activityOwner = sharedSession
        val broadcastOwner = sharedSession
        val old = activityOwner.updates.start(NoticeIdentity("gen_logistics_1", 1))
        assertTrue(activityOwner.updates.permits(old, isActive = true))

        // Android cancelAll is asynchronous: the previous notification may still appear active.
        broadcastOwner.updates.clear()
        assertFalse(activityOwner.updates.permits(old, isActive = true))
        val next = broadcastOwner.updates.start(NoticeIdentity("gen_logistics_2", 2))
        activityOwner.updates.finish(old)
        assertTrue(broadcastOwner.updates.permits(next, isActive = true))
    }

    @Test
    fun `不同生成器共享会话且另一实例清空后不恢复历史`() {
        val sharedSession = SimulationSession { ++sequence }
        val firstBroadcast = sharedSession
        val secondBroadcast = sharedSession
        val first = firstBroadcast.conversations.plan(draft(text = "第一条"), true, 1) { true }
        val second = secondBroadcast.conversations.plan(draft(text = "第二条"), true, 2) { true }
        assertEquals(first.identity, second.identity)
        assertEquals(2, second.messages.size)

        secondBroadcast.conversations.clear()
        val afterClear = firstBroadcast.conversations.plan(draft(text = "清空后"), true, 3) { true }
        assertNotEquals(first.identity, afterClear.identity)
        assertEquals(listOf("清空后"), afterClear.messages.map { it.text })
    }

    @Test
    fun `普通会话与横幅会话使用不同通知标识以支持切换渠道`() {
        val state = state()
        val first = state.plan(draft(text = "普通消息"), true, 1, "gen_chat") { true }
        val banner = state.plan(draft(text = "横幅消息"), true, 2, "gen_chat_banner") { true }
        val normalAgain = state.plan(draft(text = "又一条普通消息"), true, 3, "gen_chat") { true }
        assertNotEquals(first.identity, banner.identity)
        assertEquals(first.identity, normalAgain.identity)
        assertEquals(listOf("普通消息", "又一条普通消息"), normalAgain.messages.map { it.text })
        assertEquals(listOf("横幅消息"), banner.messages.map { it.text })
    }
}
