/// 规则动作。字符串是跨语言契约（PLAN.md §3.4），不使用序号。
enum RuleAction {
  allow('allow', '放行'),
  intercept('intercept', '拦截'),
  logOnly('log_only', '仅记录');

  const RuleAction(this.wire, this.label);

  final String wire;
  final String label;

  static RuleAction fromWire(Object? value) {
    final raw = value?.toString();
    for (final action in RuleAction.values) {
      if (action.wire == raw) return action;
    }
    return RuleAction.allow;
  }
}

/// 取消通知的实测结果，用于暴露"取消被系统静默拒绝"的边界。
enum CancelStatus {
  notAttempted('not_attempted', '未尝试'),
  // 取消请求已发出、尚未收到系统移除回调（ADR 0008）。历史记录只会在确认后落盘，
  // 所以正常读取时不会看到它；仅实时事件可能短暂出现。
  pending('pending', '待确认'),
  success('success', '已取消'),
  rejected('rejected', '被系统拒绝'),
  failed('failed', '取消失败');

  const CancelStatus(this.wire, this.label);

  final String wire;
  final String label;

  static CancelStatus fromWire(Object? value) {
    final raw = value?.toString();
    for (final status in CancelStatus.values) {
      if (status.wire == raw) return status;
    }
    return CancelStatus.notAttempted;
  }
}
