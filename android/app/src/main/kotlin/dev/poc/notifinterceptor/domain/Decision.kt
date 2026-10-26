package dev.poc.notifinterceptor.domain

/** 判定结果。reason 说明命中来源：disabled / self / rule / default。 */
data class Decision(
    val ruleId: String?,
    val ruleName: String?,
    val action: RuleAction,
    val reason: String,
) {
    val shouldIntercept: Boolean get() = action == RuleAction.INTERCEPT

    fun toMap(): Map<String, Any?> = mapOf(
        "ruleId" to ruleId,
        "ruleName" to ruleName,
        "action" to action.wire,
        "reason" to reason,
    )
}

/** 规则静态校验的告警项，由 UI 展示，不参与运行时判定。 */
data class RuleIssue(
    val ruleId: String,
    val field: String,
    val message: String,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "ruleId" to ruleId,
        "field" to field,
        "message" to message,
    )
}
