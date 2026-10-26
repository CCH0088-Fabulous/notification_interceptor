package dev.poc.notifinterceptor.support

import dev.poc.notifinterceptor.domain.HistoryEntry
import dev.poc.notifinterceptor.domain.HistorySink
import java.util.concurrent.Executor

/**
 * 把历史落盘从通知处理线程上移走。
 *
 * 实测单条 JSONL 追加写约 115 ms（模拟器，含 `appendText` 打开+写+关闭）。
 * 如果它在单线程处理队列里同步执行，40 条一批就会累积成 4–5 s 的排队时延，
 * 把"判定慢"和"写盘慢"混为一谈。
 *
 * 顺序由单线程 [executor] 保证；进程被杀时队列里的条目会丢，这是可接受的代价
 * （历史是审计用的旁路数据，不影响取消是否生效）。
 */
class AsyncHistorySink(
    private val delegate: HistorySink,
    private val executor: Executor,
) : HistorySink {

    override fun append(entry: HistoryEntry) {
        executor.execute { runCatching { delegate.append(entry) } }
    }
}
