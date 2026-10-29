package dev.poc.notifgen

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class CategorySelectionTest {
    @Test
    fun `多选发送比例在所选类别之间重新归一化`() {
        val selection = CategorySelection(setOf("chat", "group"))
        assertEquals(20, selection.totalWeight)
        assertEquals(60.0, selection.probabilityPercent("chat"), 0.0001)
        assertEquals(40.0, selection.probabilityPercent("group"), 0.0001)
        assertEquals(0.0, selection.probabilityPercent("promo"), 0.0)

        selection.setSelected("group", false)
        assertEquals(100.0, selection.probabilityPercent("chat"), 0.0)
    }

    @Test
    fun `多选传给语料生成后不会产生未选中的类别`() {
        val selection = CategorySelection(setOf("code", "logistics", "promo"))
        val corpus = NoticeCorpus(Random(42))
        val generated = (1..1000).map { corpus.next(corpus.pickCategory(selection.selectedCategories)) }
        assertEquals(selection.selectedIds, generated.map { it.category.id }.toSet())
        val percentages = selection.selectedIds.sumOf { selection.probabilityPercent(it) }
        assertEquals(100.0, percentages, 0.0001)
    }

    @Test
    fun `清空选择和恢复已保存的空集不会退回全部通知`() {
        val selection = CategorySelection()
        selection.clear()
        assertTrue(selection.selectedIds.isEmpty())
        assertEquals(0, selection.totalWeight)
        assertEquals(0.0, selection.probabilityPercent("chat"), 0.0)

        val restored = CategorySelection.restore(selection.selectedIds, "chat", 1)
        assertTrue(restored.selectedIds.isEmpty())
    }

    @Test
    fun `首次启动全选且全选后恢复原始权重`() {
        val selection = CategorySelection.restore(null)
        assertEquals(NoticeCorpus.CATEGORIES.map { it.id }, selection.selectedCategories.map { it.id })
        assertEquals(95, selection.totalWeight)
        selection.clear()
        selection.selectAll()
        assertEquals(13, selection.selectedIds.size)
        assertEquals(95, selection.totalWeight)
    }

    @Test
    fun `旧单选设置迁移为一个勾选项`() {
        val selection = CategorySelection.restore(null, "logistics", 2)
        assertEquals(setOf("logistics"), selection.selectedIds)
        assertEquals(100.0, selection.probabilityPercent("logistics"), 0.0)
    }

    @Test
    fun `旧分组随机设置迁移为对应多选而新设置优先`() {
        val migrated = CategorySelection.restore(null, null, 2)
        assertEquals(setOf("code", "bank", "logistics", "calendar"), migrated.selectedIds)
        val restored = CategorySelection.restore(setOf("chat", "bank"), "logistics", 2)
        assertEquals(setOf("chat", "bank"), restored.selectedIds)
    }

    @Test
    fun `恢复时移除未知类别且保存集合不与内部状态共享`() {
        val saved = mutableSetOf("chat", "removed-category")
        val selection = CategorySelection.restore(saved)
        saved.clear()
        assertEquals(setOf("chat"), selection.selectedIds)
        assertFalse(selection.isSelected("removed-category"))
        selection.setSelected("bank", true)
        assertTrue(saved.isEmpty())
    }
}
