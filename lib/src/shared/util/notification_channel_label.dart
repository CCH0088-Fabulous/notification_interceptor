/// 仅将已知生成器渠道翻译为中文；原始 ID 与未知渠道保持不变。
String notificationChannelLabel(String channel) {
  if (channel == 'gen_banner_summary') return '通知分组汇总';
  const names = {
    'gen_chat': '私聊消息',
    'gen_group': '群聊消息',
    'gen_code': '验证码',
    'gen_bank': '银行通知',
    'gen_logistics': '物流通知',
    'gen_calendar': '日程提醒',
    'gen_promo': '促销通知',
    'gen_marketing': '营销短信',
    'gen_news': '资讯推送',
    'gen_social': '社交互动',
    'gen_game': '游戏通知',
    'gen_spam': '可疑信息',
    'gen_junk': '清理与省电提醒',
  };
  final suffix = channel.endsWith('_banner')
      ? '_banner'
      : channel.endsWith('_loud')
      ? '_loud'
      : '';
  final base = channel.substring(0, channel.length - suffix.length);
  final name = names[base];
  if (name == null) return channel;
  return switch (suffix) {
    '_banner' => '$name · 横幅提醒',
    '_loud' => '$name · 响铃提醒',
    _ => name,
  };
}
