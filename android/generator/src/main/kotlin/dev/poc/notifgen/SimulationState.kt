package dev.poc.notifgen

/** A notification identity stays stable while the same conversation receives new messages. */
data class NoticeIdentity(val tag: String, val id: Int)

data class ConversationMessage(val text: String, val sender: String, val timestamp: Long)

data class PlannedNotice(val identity: NoticeIdentity, val messages: List<ConversationMessage>)

/** Shared by all Generator owners in one process, including separately created broadcast receivers. */
class SimulationSession(nextSequence: () -> Int) {
    val conversations = SimulationState(nextSequence)
    val updates = SimulationUpdates()
}

/** Pure state: ordinary test notifications remain independent from simulated conversations. */
class SimulationState(
    private val nextSequence: () -> Int,
    private val maxMessages: Int = 6,
    private val maxConversations: Int = 24,
) {
    private val conversations = LinkedHashMap<String, PlannedNotice>(16, 0.75f, true)

    init {
        require(maxMessages > 0 && maxConversations > 0)
    }

    @Synchronized
    fun plan(
        draft: Draft,
        realistic: Boolean,
        timestamp: Long,
        identityScope: String = "",
        isActive: (NoticeIdentity) -> Boolean,
    ): PlannedNotice {
        val sender = draft.sender ?: draft.persona
        val message = ConversationMessage(draft.text.removePrefix("$sender："), sender, timestamp)
        if (!realistic || draft.category.style != NoticeStyle.MESSAGING) {
            return PlannedNotice(newIdentity(draft.category), listOf(message))
        }

        // Android cannot move an existing notification to another channel. Keep separate identities
        // for normal / loud / banner conversations and resume the matching channel when switching back.
        val key = "${draft.category.id}|${draft.persona}|$identityScope"
        val previous = conversations[key]?.takeIf { isActive(it.identity) }
        val notice = PlannedNotice(
            previous?.identity ?: newIdentity(draft.category),
            (previous?.messages.orEmpty() + message).takeLast(maxMessages),
        )
        conversations[key] = notice
        while (conversations.size > maxConversations) {
            conversations.remove(conversations.keys.first())
        }
        return notice
    }

    @Synchronized
    fun clear() = conversations.clear()

    private fun newIdentity(category: Category): NoticeIdentity {
        val sequence = nextSequence()
        return NoticeIdentity(GeneratorTags.forCategory(category, sequence), sequence)
    }
}

data class UpdateToken(val identity: NoticeIdentity, val generation: Long)

/** Invalidates delayed callbacks even when another update starts for the same identity. */
class SimulationUpdates {
    private val running = mutableMapOf<NoticeIdentity, Long>()
    private var generation = 0L

    @Synchronized
    fun start(identity: NoticeIdentity): UpdateToken {
        val token = UpdateToken(identity, ++generation)
        running[identity] = token.generation
        return token
    }

    @Synchronized
    fun permits(token: UpdateToken, isActive: Boolean): Boolean =
        isActive && running[token.identity] == token.generation

    @Synchronized
    fun finish(token: UpdateToken) {
        if (running[token.identity] == token.generation) running.remove(token.identity)
    }

    @Synchronized
    fun clear() = running.clear()
}

data class LogisticsStep(val progress: Int, val status: String, val complete: Boolean = false)

object LogisticsJourney {
    fun steps(draft: Draft): List<LogisticsStep> = listOf(
        LogisticsStep(15, "包裹正在运输"),
        LogisticsStep(45, "包裹已到达配送站"),
        LogisticsStep(80, "快递员正在派送"),
        LogisticsStep(
            100,
            draft.text.replace("包裹将送至", "包裹已到达")
                .replace("请以实际到件提醒为准。", "请及时领取。"),
            complete = true,
        ),
    )
}
