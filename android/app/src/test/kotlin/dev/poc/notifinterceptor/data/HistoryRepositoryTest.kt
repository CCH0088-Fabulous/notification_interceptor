package dev.poc.notifinterceptor.data

import dev.poc.notifinterceptor.domain.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class HistoryRepositoryTest {
    @get:Rule val temp = TemporaryFolder()
    private fun entry(id: Int, ongoing: Boolean = false, action: RuleAction = RuleAction.ALLOW) = HistoryEntry(
        id = id.toString(), timestamp = id.toLong(),
        snapshot = testSnapshot(isOngoing = ongoing, text = "update $id"),
        action = action, matchedRuleId = null, matchedRuleName = null,
        cancelStatus = CancelStatus.NOT_ATTEMPTED,
    )
    @Test fun `frequent ongoing updates never evict ordinary history`() {
        val repo = HistoryRepository(temp.root)
        repeat(1000) { repo.append(entry(it)) }
        repeat(2000) { repo.append(entry(it + 1000, ongoing = true)) }
        assertEquals(1000, repo.count())
        assertEquals((0 until 1000).map { it.toString() }, repo.exportEntries().map { it.id })
        assertEquals(1000, File(temp.root, "history.jsonl").readLines().size)
        repo.append(entry(3000))
        assertEquals("1", repo.exportEntries().first().id)
        assertEquals("3000", repo.exportEntries().last().id)
    }
    @Test fun `upgrade cleans legacy ongoing records before capacity trimming and persists cleanup`() {
        val original = listOf(entry(1), entry(2, true), entry(3), entry(4, true), entry(5))
        val file = File(temp.root, "history.jsonl")
        file.writeText(original.joinToString("\n") { Json.stringify(it.toMap()) } + "\n")
        val repo = HistoryRepository(temp.root, maxEntries = 3)
        assertEquals(listOf("5", "3", "1"), repo.query().map { it.id })
        assertEquals(3, file.readLines().size)
        assertEquals(listOf("1", "3", "5"), HistoryRepository(temp.root).exportEntries().map { it.id })
        assertFalse(repo.exportJson().contains("\"isOngoing\":true"))
    }
    @Test fun `all ongoing actions are excluded but nonclearable ordinary records remain`() {
        val repo = HistoryRepository(temp.root)
        RuleAction.values().forEachIndexed { i, action -> repo.append(entry(i, true, action)) }
        assertEquals(0, repo.count())
        val normal = entry(10).let { it.copy(snapshot = it.snapshot.copy(isClearable = false)) }
        repo.append(normal)
        assertEquals(listOf(normal), repo.query())
        assertEquals(1, repo.stats()["total"])
    }
}
