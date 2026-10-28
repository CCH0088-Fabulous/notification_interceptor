/// 主题是可编辑的关键词起点，不进行语义分类；不依赖生成器类别或渠道。
class RuleTopic {
  const RuleTopic(this.name, this.keywords);
  final String name;
  final List<String> keywords;

  static const suggestions = [
    RuleTopic('促销购物', ['秒杀', '降价', '大促', '优惠', '优惠券']),
    RuleTopic('会员营销', ['会员日', '签到', '积分', '回归礼包']),
    RuleTopic('视频更新', ['新视频', '更新了视频', '直播开始']),
    RuleTopic('重要提醒', ['验证码', '会议', '取件码']),
  ];
}
