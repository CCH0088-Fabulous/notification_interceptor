package dev.poc.notifgen

import java.util.Random
import java.util.Locale

/** 通知的构造形态。聊天类走 MessagingStyle 才像真实 IM。 */
enum class NoticeStyle { MESSAGING, BIG_TEXT, BASIC }

/**
 * 一类通知。渠道按类别拆分，规则用 channelIds 就能精确分流，
 * 不必依赖会被系统改写的标题（MessagingStyle 会把 title 换成会话名）。
 *
 * [keep] 只用于演示与验收的期望值：true 表示"这类应该留在通知栏"。
 */
data class Category(
    val id: String,
    val channelId: String,
    val channelName: String,
    val label: String,
    val keep: Boolean,
    val style: NoticeStyle,
    val weight: Int,
)

/** 一条待发出的通知内容。 */
data class Draft(
    val category: Category,
    val persona: String,
    val title: String,
    val text: String,
    val sender: String? = null,
)

/**
 * 内置语料：把"营销短信 / 验证码 / 群聊 / 资讯推送"等真实世界的通知文案写成模板，
 * 每次随机挑类别、随机挑句式并填随机值。刻意不联网、不调 NLP 服务，
 * 保证演示可复现、离线可用（`seed` 固定时序列完全一致）。
 */
class NoticeCorpus(private val random: Random) {

    fun pickCategory(categories: List<Category> = CATEGORIES): Category {
        require(categories.isNotEmpty()) { "至少选择一个通知类别" }
        require(categories.all { it.weight > 0 }) { "通知类别权重必须大于零" }
        val total = categories.sumOf { it.weight }
        var ticket = random.nextInt(total)
        for (category in categories) {
            ticket -= category.weight
            if (ticket < 0) return category
        }
        return categories.first()
    }

    fun findCategory(id: String): Category? = CATEGORIES.firstOrNull { it.id == id }

    fun next(category: Category = pickCategory()): Draft = when (category.id) {
        "chat" -> chat(category)
        "group" -> group(category)
        "code" -> code(category)
        "bank" -> bank(category)
        "logistics" -> logistics(category)
        "calendar" -> calendar(category)
        "promo" -> promo(category)
        "marketing" -> marketing(category)
        "news" -> news(category)
        "social" -> social(category)
        "game" -> game(category)
        "spam" -> spam(category)
        "junk" -> junk(category)
        else -> throw IllegalArgumentException("未定义语料的通知类别：${category.id}")
    }

    private fun chat(category: Category): Draft {
        val person = pick(PEOPLE)
        val text = pick(
            "文档我改完了，你看下有没有漏的",
            "中午一起吃饭？12:30 楼下等你",
            "刚收到快递，我放前台了",
            "会议纪要发你邮箱了，注意看第三点",
            "代码我看过了，那两个注释可以删",
            "这版设计稿我传到共享盘了",
            "下午有空对一下接口吗",
            "我到楼下了，你下来吧",
            "[图片] 这个颜色你觉得怎么样？",
            "刚才信号不好，方便再打给我吗？",
            "收到，今晚我来订餐厅",
            "那份文件已经签好了，明早带给你",
        )
        return Draft(category, person, person, text, person)
    }

    private fun group(category: Category): Draft {
        val groupName = pick(GROUPS)
        val sender = pick(PEOPLE)
        val text = pick(
            "明天的评审改到 3 点",
            "线上有人反馈登录失败，谁看下",
            "周末爬山报名截止今天下午",
            "发布窗口定在周四晚 8 点",
            "会议室临时换到 5 楼",
            "这周的周报记得周五前发我",
            "@所有人 请大家确认一下明天的排班",
            "[文件] 需求评审_v3.pdf",
            "[图片] 今晚的菜单，大家看看想吃什么",
            "我先出门了，球场见",
            "新版本已经发布，有问题在群里反馈",
        )
        return Draft(category, groupName, groupName, "$sender：$text", sender)
    }

    private fun code(category: Category): Draft {
        val provider = pick(CODE_PROVIDERS)
        val code = String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000))
        val minutes = pick("3", "5", "10")
        return Draft(
            category = category,
            persona = provider,
            title = "$provider 登录验证",
            text = "您的验证码为 $code，用于本次登录，$minutes 分钟内有效。工作人员不会向您索要验证码。",
        )
    }

    private fun bank(category: Category): Draft {
        val bank = pick(BANKS)
        val cents = 100 + random.nextInt(1_999_900)
        val amount = money(cents)
        val balance = money(cents + 100_000 + random.nextInt(8_000_000))
        val tail = (1000 + random.nextInt(9000)).toString()
        val text = if (random.nextBoolean()) {
            "您尾号 $tail 的储蓄卡收到转账，入账 ¥$amount，账户余额 ¥$balance。"
        } else {
            "您尾号 $tail 的储蓄卡完成消费，支出 ¥$amount，账户余额 ¥$balance。如非本人操作，请及时联系客服。"
        }
        return Draft(category, bank, "$bank 账户动账提醒", text)
    }

    private fun logistics(category: Category): Draft {
        val courier = pick(COURIERS)
        val shelf = 1 + random.nextInt(9)
        val code = "$shelf-${1 + random.nextInt(6)}-${1000 + random.nextInt(9000)}"
        val tail = 1000 + random.nextInt(9000)
        val text = "尾号 $tail 的包裹将送至 $courier（$shelf 号楼），取件码 $code。请以实际到件提醒为准。"
        return Draft(category, courier, "$courier · 包裹动态", text)
    }

    private fun calendar(category: Category): Draft {
        val hour = pick("09:30", "11:00", "15:00", "16:30", "19:00")
        val what = pick(
            "与张总开会 · 会议室 B",
            "牙科复诊 · 3 楼 302",
            "季度评审 · 线上会议",
            "接孩子放学",
            "体检 · 空腹",
        )
        return Draft(category, "日程提醒", "即将开始 · $what", "今天 $hour，$what。距离日程开始还有 15 分钟，请提前安排出行。")
    }

    private fun promo(category: Category): Draft {
        val shop = pick(SHOPS)
        val text = pick(
            "限时秒杀！满 199 减 100，仅剩 3 小时",
            "您关注的商品降价了，券后 ¥59 起",
            "今日 20:00 大促开场，前 1000 名半价",
            "购物车里有 3 件商品已降价，点击查看",
            "你的收藏有新优惠：运动鞋直降 80 元，售完即止",
            "周末好价已上线，生活用品第二件半价",
            "今晚直播专享价，熟悉的好物补货了",
        )
        return Draft(category, shop, shop, text)
    }

    private fun marketing(category: Category): Draft {
        val text = pick(
            "尊贵的黄金会员，您有一张 50 元无门槛券待领取",
            "签到得积分，今日可领 30 积分",
            "会员日双倍积分，仅限今天",
            "您已 7 天未登录，回归礼包已备好",
            "您的会员专属福利已到账，本周可享两次免运费",
            "周末双倍成长值，专属好礼等你解锁",
            "限时加赠：续费年度会员多送 30 天",
        )
        return Draft(category, "会员中心", "会员中心", text)
    }

    private fun news(category: Category): Draft {
        val text = pick(
            "惊！这三种早餐千万别吃",
            "刚刚：某球队 3:0 大胜，球迷沸腾",
            "热搜第一：某明星官宣恋情",
            "这五个习惯正在悄悄伤害你的腰",
            "城市快讯：地铁新线路本周末开通试运营",
            "你关注的话题更新了，今天有 12 条新动态",
            "赛后速递：最后一分钟完成逆转，精彩集锦已上线",
        )
        return Draft(category, "热点资讯", "热点资讯", text)
    }

    private fun social(category: Category): Draft {
        val text = pick(
            "3 人赞了你的动态",
            "你有 2 条新评论",
            "你可能认识的人：${pick(PEOPLE)}",
            "你的好友发布了新照片",
            "${pick(PEOPLE)} 回复了你的评论：这家店我也去过！",
            "你关注的创作者刚刚更新了一篇笔记",
            "昨天发布的作品又收到了 8 个赞",
        )
        return Draft(category, "社区互动", "社区互动", text)
    }

    private fun game(category: Category): Draft {
        val text = pick(
            "体力已恢复满，快来继续闯关",
            "限时活动最后 2 小时，登录领 10 连抽",
            "你的好友冲到了排行榜第 3 名",
            "每日任务已刷新，完成可领 200 金币",
            "公会好友邀请你组队，今晚一起挑战新副本",
            "新赛季已开启，专属外观限时返场",
            "离线收益已达上限，上线即可领取",
        )
        return Draft(category, "游戏中心", "游戏中心", text)
    }

    private fun spam(category: Category): Draft {
        val text = pick(
            "恭喜您被抽中一等奖，点击链接领取 iPhone",
            "您的账户存在异常，请点击链接完成验证",
            "低息贷款，秒批 20 万，无需抵押",
            "您有一笔退款待确认，逾期失效",
            "有一份神秘礼物等您签收，回复即可领取",
            "专属名额最后一天，快速办理无需等待",
        )
        return Draft(category, "未知来源", "未知来源", text)
    }

    private fun junk(category: Category): Draft {
        val tool = pick(TOOLS)
        val text = pick(
            "发现 2.1GB 垃圾，立即清理可提速 40%",
            "后台有 12 个应用在耗电，点击优化",
            "内存占用 87%，一键加速释放 1.8GB",
            "今日已为您省电 12%，继续保持",
            "存储空间不足，建议清理重复照片和缓存文件",
            "检测到长时间未使用的应用，可释放 860MB 空间",
            "本周设备使用报告已生成，点此查看详情",
        )
        return Draft(category, tool, tool, text)
    }

    private fun pick(items: List<String>): String = items[random.nextInt(items.size)]

    private fun money(cents: Int): String = String.format(Locale.ROOT, "%,.2f", cents / 100.0)

    private fun pick(vararg items: String): String = items[random.nextInt(items.size)]

    companion object {
        const val TAG_LOG = "NotifGen"

        val CATEGORIES: List<Category> = listOf(
            Category("chat", "gen_chat", "生成器 · 私聊", "私聊消息", true, NoticeStyle.MESSAGING, 12),
            Category("group", "gen_group", "生成器 · 群聊", "群聊消息", true, NoticeStyle.MESSAGING, 8),
            Category("code", "gen_code", "生成器 · 验证码", "验证码", true, NoticeStyle.BIG_TEXT, 10),
            Category("bank", "gen_bank", "生成器 · 账户变动", "银行/支付", true, NoticeStyle.BIG_TEXT, 8),
            Category("logistics", "gen_logistics", "生成器 · 物流", "物流", true, NoticeStyle.BIG_TEXT, 6),
            Category("calendar", "gen_calendar", "生成器 · 日程", "日程提醒", true, NoticeStyle.BIG_TEXT, 4),
            Category("promo", "gen_promo", "生成器 · 促销", "电商促销", false, NoticeStyle.BASIC, 12),
            Category("marketing", "gen_marketing", "生成器 · 营销短信", "营销短信", false, NoticeStyle.BASIC, 8),
            Category("news", "gen_news", "生成器 · 资讯推送", "资讯推送", false, NoticeStyle.BASIC, 6),
            Category("social", "gen_social", "生成器 · 社交互动", "社交互动", false, NoticeStyle.BASIC, 6),
            Category("game", "gen_game", "生成器 · 游戏", "游戏运营", false, NoticeStyle.BASIC, 5),
            Category("spam", "gen_spam", "生成器 · 可疑信息", "可疑/诈骗", false, NoticeStyle.BASIC, 5),
            Category("junk", "gen_junk", "生成器 · 工具提醒", "清理/省电提醒", false, NoticeStyle.BASIC, 5),
        )

        private val PEOPLE = listOf("小李", "王强", "陈工", "刘姐", "老周", "赵敏", "孙悦", "阿 May")
        private val GROUPS = listOf("产品评审群", "后端值班群", "家庭群", "羽毛球约球群", "楼栋业主群")
        private val CODE_PROVIDERS = listOf("【招商银行】", "【支付宝】", "【GitHub】", "【某某云】")
        private val BANKS = listOf("【招商银行】", "【工商银行】", "【支付宝】", "【微信支付】")
        private val COURIERS = listOf("菜鸟驿站", "丰巢智能柜", "顺丰速运", "京东物流")
        private val SHOPS = listOf("【某某商城】", "【某某优选】", "【某某超市】", "【某某旗舰店】")
        private val TOOLS = listOf("【清理大师】", "【省电助手】", "【极速优化】")
    }
}
