package dev.poc.notifgen

/** Selection and displayed probabilities use exactly the same weights as NoticeCorpus. */
class CategorySelection(
    initialIds: Set<String> = NoticeCorpus.CATEGORIES.map { it.id }.toSet(),
    private val categories: List<Category> = NoticeCorpus.CATEGORIES,
) {
    private val knownIds = categories.map { it.id }.toSet()
    private val selected = categories.filter { it.id in initialIds }.mapTo(linkedSetOf()) { it.id }

    val selectedIds: Set<String> get() = selected.toSet()
    val selectedCategories: List<Category> get() = categories.filter { it.id in selected }
    val totalWeight: Int get() = selectedCategories.sumOf { it.weight }

    fun isSelected(id: String): Boolean = id in selected

    fun setSelected(id: String, selected: Boolean) {
        require(id in knownIds) { "未知通知类别：$id" }
        if (selected) this.selected.add(id) else this.selected.remove(id)
    }

    fun selectAll() {
        selected.clear()
        selected.addAll(knownIds)
    }

    fun clear() = selected.clear()

    fun probabilityPercent(id: String): Double {
        if (id !in selected || totalWeight == 0) return 0.0
        return categories.first { it.id == id }.weight * 100.0 / totalWeight
    }

    companion object {
        /** A saved empty set is intentional. Only absent settings use the legacy migration. */
        fun restore(
            savedIds: Set<String>?,
            legacyCategoryId: String? = null,
            legacyGroup: Int = 0,
        ): CategorySelection {
            if (savedIds != null) return CategorySelection(savedIds)
            if (NoticeCorpus.CATEGORIES.any { it.id == legacyCategoryId }) {
                return CategorySelection(setOf(requireNotNull(legacyCategoryId)))
            }
            // Retained only to migrate settings from the previous two-level interface.
            val legacyIds = when (legacyGroup) {
                1 -> setOf("chat", "group")
                2 -> setOf("code", "bank", "logistics", "calendar")
                3 -> setOf("promo", "marketing", "news", "social", "game", "spam")
                4 -> setOf("junk")
                else -> NoticeCorpus.CATEGORIES.map { it.id }.toSet()
            }
            return CategorySelection(legacyIds)
        }
    }
}
