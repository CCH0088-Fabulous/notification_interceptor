package dev.poc.notifinterceptor.domain

/** 规则命中后执行的动作。字符串形式是跨语言契约，禁止使用序号。 */
enum class RuleAction(val wire: String) {
    ALLOW("allow"),
    INTERCEPT("intercept"),
    LOG_ONLY("log_only");

    companion object {
        fun fromWire(value: String?): RuleAction =
            entries.firstOrNull { it.wire == value } ?: ALLOW
    }
}

/** 条件组之间的组合方式。ALL = 组间 AND（默认），ANY = 组间 OR。 */
enum class MatchMode(val wire: String) {
    ALL("all"),
    ANY("any");

    companion object {
        fun fromWire(value: String?): MatchMode =
            entries.firstOrNull { it.wire == value } ?: ALL
    }
}

/** 取消通知的实测结果，用于暴露"取消被系统静默拒绝"这一边界。 */
enum class CancelStatus(val wire: String) {
    NOT_ATTEMPTED("not_attempted"),

    /**
     * 取消请求已发出，尚未确认。
     *
     * `cancelNotification` 是异步的：返回成功只代表请求被接受，通知是否真的消失
     * 要等 `onNotificationRemoved` 回调或超时复查。这个中间态让取消不必等待确认，
     * 从而把"确认生效"整段移出关键路径（见 ADR 0008）。
     */
    PENDING("pending"),
    SUCCESS("success"),
    REJECTED("rejected"),
    FAILED("failed"),
    ;

    companion object {
        fun fromWire(value: String?): CancelStatus =
            entries.firstOrNull { it.wire == value } ?: NOT_ATTEMPTED
    }
}
