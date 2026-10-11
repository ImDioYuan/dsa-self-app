import Foundation

/// 用前配置的每一步：属于哪一组、标题、图标、教程内容。
/// 教程按 2026-10 核对过：app 和 Worker 的代码、各家控制台、Google Cloud、iOS 27 的快捷指令。改功能时记得同步这里
enum SetupStep: String, CaseIterable, Identifiable {
    case deployWorker, connectWorker, aiKeys, profile
    case calendars, icalFeeds, gmail, forwarding, watchRules
    case emailCharges, applePay, quickEntry, widgets, csvImport
    case interests, newsBasics
    case backgroundRefresh

    var id: String { rawValue }

    enum Group: CaseIterable {
        case required, today, ledger, news, other

        var title: String {
            switch self {
            case .required: "必需"
            case .today: "今日"
            case .ledger: "记账"
            case .news: "新闻"
            case .other: "其他"
            }
        }
    }

    var group: Group {
        switch self {
        case .deployWorker, .connectWorker, .aiKeys, .profile: .required
        case .calendars, .icalFeeds, .gmail, .forwarding, .watchRules: .today
        case .emailCharges, .applePay, .quickEntry, .widgets, .csvImport: .ledger
        case .interests, .newsBasics: .news
        case .backgroundRefresh: .other
        }
    }

    /// Mac 上没有的功能
    var iOSOnly: Bool {
        switch self {
        case .applePay, .quickEntry, .backgroundRefresh: true
        default: false
        }
    }

    static var visible: [SetupStep] {
        #if os(iOS)
        allCases
        #else
        allCases.filter { !$0.iOSOnly }
        #endif
    }

    var title: String {
        switch self {
        case .deployWorker: "部署 Worker"
        case .connectWorker: "连接 Worker"
        case .aiKeys: "添加 AI 的 API key"
        case .profile: "填个人资料"
        case .calendars: "苹果日历和提醒事项"
        case .icalFeeds: "订阅日历（Moodle、Canvas 等）"
        case .gmail: "连接 Gmail"
        case .forwarding: "学校或公司邮箱转发到 Gmail"
        case .watchRules: "邮件特别关注"
        case .emailCharges: "邮件自动记账"
        case .applePay: "Apple Pay 自动记账"
        case .quickEntry: "操作按钮 · Siri · 控制中心"
        case .widgets: "小组件"
        case .csvImport: "导入银行流水"
        case .interests: "选新闻兴趣"
        case .newsBasics: "城市 · 汇率 · 对你的影响"
        case .backgroundRefresh: "后台 App 刷新"
        }
    }

    var systemImage: String {
        switch self {
        case .deployWorker: "icloud.and.arrow.up"
        case .connectWorker: "link"
        case .aiKeys: "key"
        case .profile: "person.crop.circle"
        case .calendars: "calendar"
        case .icalFeeds: "calendar.badge.plus"
        case .gmail: "envelope"
        case .forwarding: "arrowshape.turn.up.right"
        case .watchRules: "star"
        case .emailCharges: "envelope.badge"
        case .applePay: "wallet.pass"
        case .quickEntry: "bolt.circle"
        case .widgets: "square.grid.2x2"
        case .csvImport: "tablecells"
        case .interests: "slider.horizontal.3"
        case .newsBasics: "cloud.sun"
        case .backgroundRefresh: "arrow.clockwise"
        }
    }

    /// 教程开头的一句话
    var intro: String {
        switch self {
        case .deployWorker:
            "Worker 是你自己的后端：AI 的 key、个人资料和新闻都存在里面，只有你能访问。用 Cloudflare 免费版就够（每天 10 万次请求），在 Mac 上做一次就好。"
        case .connectWorker:
            "把 Worker 地址和口令填进 app。连上之后，个人资料、AI 模型和新闻这些设置才能用。"
        case .aiKeys:
            "分析邮件、识别小票、每日简报和深度报道都要用 AI，至少要有一家的 API key。key 存在你的 Worker 里，不经过手机。"
        case .profile:
            "AI 挑新闻、写「对你的影响」、判断哪封邮件要提醒你时，都会参考你的资料。"
        case .calendars:
            "把苹果日历里的日程和提醒事项里的待办，自动整理进「今日」。"
        case .icalFeeds:
            "学校作业截止时间这类日历，可以用订阅链接加进来。只读，不用登录。"
        case .gmail:
            "让 DSA 读最近的邮件：AI 找出要处理的事（截止、面试、账单）放进「今日」，也能自动记账。只要只读权限，分析在你自己的 Worker 里做。"
        case .forwarding:
            "学校或公司的邮箱（比如 Outlook）转发到 Gmail 后，DSA 也能读到，并标成 Outlook 来源。需要先连接 Gmail。"
        case .watchRules:
            "有些邮件不用你做什么，但你想知道（比如求职进展）。写成规则，命中的邮件就会出现在「今日」。"
        case .emailCharges:
            "自动从 Gmail 里找付款收据（订阅续费、自动扣款、网购、外卖、退款）记进账本。Apple Pay 已经记过的同一笔会跳过。"
        case .applePay:
            "每次用 Apple Pay 刷卡，自动记一笔，并按商家自动分类。需要在「快捷指令」里设置一次。"
        case .quickEntry:
            "不用打开 app 也能快速记账。"
        case .widgets:
            "在主屏幕或锁屏上看今天花了多少、本月预算用了多少。"
        case .csvImport:
            "银行、支付宝、微信导出的流水，可以一次导入。"
        case .interests:
            "每天早上的新闻简报按你的兴趣挑新闻。"
        case .newsBasics:
            "简报里还有关注城市的天气、汇率，和「对你的影响」。"
        case .backgroundRefresh:
            "打开后，iPhone 会在后台提前同步邮件和日历、下载早上的简报，打开 app 就能看。"
        }
    }

    var blocks: [GuideBlock] {
        switch self {
        case .deployWorker:
            [
                .heading("准备"),
                .step("注册免费的 Cloudflare 账号"),
                .link("dash.cloudflare.com/sign-up", "https://dash.cloudflare.com/sign-up"),
                .step("在 Mac 上安装 Node.js 22 或更新的版本"),
                .link("nodejs.org", "https://nodejs.org"),
                .step("下载 DSA 的代码，在「终端」里进入 worker 文件夹"),
                .command("cd worker"),
                .heading("部署"),
                .step("安装依赖"),
                .command("npm install"),
                .step("登录 Cloudflare，会打开浏览器，点「允许」"),
                .command("npx wrangler login"),
                .step("创建存数据的空间，记下显示的 id"),
                .command("npx wrangler kv namespace create NEWS"),
                .step("复制配置文件，把上一步的 id 填进 wrangler.toml 里 id = 后面的引号里"),
                .command("cp wrangler.example.toml wrangler.toml"),
                .step("生成一串访问口令，复制下来，等会儿 app 里也要填"),
                .command("openssl rand -hex 24"),
                .step("把口令存进 Worker：运行后粘贴口令，回车"),
                .command("npx wrangler secret put APP_TOKEN"),
                .step("部署。第一次会让你给 workers.dev 起一个子域名"),
                .command("npx wrangler deploy"),
                .note("部署成功后显示的 https://dsa-worker.<子域名>.workers.dev 就是 Worker 地址。下一步要添加 AI 的 key；以后改了代码，再运行一次 npx wrangler deploy。"),
            ]
        case .connectWorker:
            [
                .step("打开 设置 → Worker"),
                .step("填 Worker 地址，例如 https://dsa-worker.xxx.workers.dev"),
                .step("填部署时生成的访问口令（APP_TOKEN）"),
                .step("点「测试连接」，显示「已连接」就好了"),
                .note("连上后，app 会把这台设备的时区告诉 Worker，简报按你当地的时间生成。"),
            ]
        case .aiKeys:
            [
                .heading("选一家（或几家）"),
                .providers,
                .heading("选模型"),
                .text("在 设置 → AI 模型 里，「任务和记账」「每日简报」「深度报道」可以各选一家。选「自动」时，按 Claude → OpenAI → Gemini → Grok → DeepSeek 的顺序，用第一家配了 key 的。"),
                .note("key 添加后马上生效，回到 设置 → AI 模型 下拉刷新就能看到「已配置」。key 不对时，app 会提示是哪一家的 key 有问题。"),
            ]
        case .profile:
            [
                .step("打开 设置 → 个人资料"),
                .step("称呼：AI 在简报里怎么叫你"),
                .step("关于我：你的身份、所在城市、学校和专业，以及关心的事（投资、家里的生意、在找的工作……）"),
                .note("例如：「我在墨尔本读研究生，学会计，在找实习；持有一些指数基金。」写得越具体，新闻和提醒越准。"),
            ]
        case .calendars:
            [
                .step("打开 设置 → 今日"),
                .step("打开「苹果日历」和「提醒事项」"),
                .step("系统弹出权限请求时，选「允许完全访问」"),
                .note("如果之前点了不允许：iPhone 设置 → 隐私与安全性 → 日历（或提醒事项）→ DSA，改成「完全访问」。"),
            ]
        case .icalFeeds:
            [
                .heading("Moodle"),
                .step("Calendar → 页面底部 Import or export calendars → Export calendar"),
                .step("Events to export 选 All events，Time period 选 Recent and next 60 days"),
                .step("点 Get calendar URL，再点 Copy URL"),
                .heading("Canvas"),
                .step("左侧 Calendar → 右侧栏底部 Calendar Feed"),
                .step("复制弹出框里的链接"),
                .heading("Google 日历（电脑网页版）"),
                .step("右上角齿轮 → 设置"),
                .step("左侧选要订阅的日历 → 集成日历（Integrate calendar）"),
                .step("复制「iCal 格式的私密地址」"),
                .heading("Outlook（网页版）"),
                .step("设置 → 日历 → 共享日历"),
                .step("发布日历（Publish a calendar）：选日历和能看到的详细程度 → 发布"),
                .step("复制 ICS 链接"),
                .heading("加到 DSA"),
                .step("设置 → 今日 → 添加订阅日历"),
                .step("起个名字（会显示在任务上），粘贴链接"),
                .note("这些链接不用登录就能看到你的日程，别发给别人。"),
            ]
        case .gmail:
            [
                .heading("在 Google Cloud 创建 Client ID（一次就好）"),
                .step("打开 Google Cloud Console，新建一个项目"),
                .link("console.cloud.google.com", "https://console.cloud.google.com"),
                .step("APIs & Services → Library，搜 Gmail API → Enable"),
                .step("Google Auth platform → Get Started：填 app 名称和你的邮箱；Audience 选 External；填联系邮箱；同意条款后 Create"),
                .step("Audience → Test users → Add users，加上你自己的 Gmail"),
                .step("Clients → Create client → Application type 选 iOS，Bundle ID 填下面这个，然后 Create"),
                .bundleID,
                .step("复制生成的 Client ID（形如 123-abc.apps.googleusercontent.com）"),
                .heading("登录"),
                .step("打开 设置 → Gmail，粘贴 Client ID"),
                .step("点「登录 Gmail」。看到「Google 未验证此应用」时点「继续」，允许读取邮件"),
                .note("项目保持测试（Testing）状态就行。测试状态下 Google 每 7 天让登录失效一次，到时候回 设置 → Gmail 重新登录。"),
            ]
        case .forwarding:
            [
                .step("先在 Gmail 建过滤器（顺序不能反，否则转发来的邮件会先进收件箱）：搜索框右边的筛选图标 →「包含字词」填 deliveredto:你的名字+school@gmail.com → 创建过滤器 → 勾选「跳过收件箱」「应用标签」（新建一个，比如 School）「一律不发送到垃圾邮件」"),
                .step("再在学校邮箱里开转发。以 Outlook 网页版为例：设置 → 邮件 → 转发 → 启用转发，填 你的名字+school@gmail.com，勾选「保留转发邮件的副本」"),
                .step("最后在 设置 → Gmail →「转发邮件的标签」里填标签名（比如 School）"),
                .note("+school 是 Gmail 的别名写法，发到这个地址的邮件会进你自己的 Gmail。"),
            ]
        case .watchRules:
            [
                .step("打开 设置 → 今日 → 邮件特别关注"),
                .step("添加规则，用一句话写清楚。例如：「我在申请 X 公司的工作，招聘相关的邮件（测评、面试、offer、拒信）都提醒我，促销邮件不算」"),
                .step("如果这类邮件常被 Gmail 分到「推广」，在下面的 Gmail 搜索里填关键词，例如 company (interview OR offer)"),
                .note("需要先连接 Gmail 和 Worker。"),
            ]
        case .emailCharges:
            [
                .step("先连接 Gmail 和 Worker"),
                .step("打开 设置 → 记账，确认「邮件自动记账」开着（默认开着）"),
                .note("每天 8 点后第一次打开 DSA 时检查一次；也可以在 设置 → 记账 里点「立即检查付款邮件」。"),
            ]
        case .applePay:
            [
                .heading("iOS 27"),
                .step("打开「快捷指令」app，点下方的「+」新建一个快捷指令"),
                .step("点「编辑」，在下方动作列表里点「自动化」，选「交易」，勾选你的卡"),
                .step("在动作列表里搜「DSA」，添加「记录 Apple Pay 交易」"),
                .step("点动作里的「金额」→ 选「快捷指令输入」，再点一次改成「金额」；「商家」同样改成「商家」"),
                .step("如果每次刷卡都要你确认才运行：在快捷指令的详细信息（ⓘ）→ 隐私 里，打开「锁定时允许运行」"),
                .heading("iOS 26 及更早"),
                .step("快捷指令 → 底部「自动化」→「+」→「交易」"),
                .step("勾选你的卡，选「立即运行」，点「下一步」"),
                .step("「新建空白自动化」→「添加操作」→ 搜「DSA」→「记录 Apple Pay 交易」"),
                .step("「金额」「商家」同样设成快捷指令输入里的金额和商家"),
                .note("只有 Apple Pay 刷卡会触发；网购、自动扣款用「邮件自动记账」或导入 CSV 补上。默认按澳元记，在别的国家可以把动作里的「币种代码」填成 CNY、USD 等。在记账页改过某个商家的分类后，以后同一个商家就用你改的分类。"),
            ]
        case .quickEntry:
            [
                .heading("操作按钮（iPhone 15 Pro 及更新）"),
                .step("iPhone 设置 → 操作按钮"),
                .step("左右滑到「快捷指令」，点下方的按钮，选 DSA 的「记一笔」"),
                .note("以后按住操作按钮就弹出记一笔。"),
                .heading("Siri"),
                .text("说「DSA记一笔」或「用DSA记账」：打开记一笔。\n说「用DSA记一笔支出」：Siri 会问金额和分类，不用打开 app。"),
                .heading("控制中心"),
                .step("打开控制中心，长按空白处 →「添加控制」"),
                .step("搜「DSA」，添加「记一笔」或「拍小票记账」"),
                .heading("锁屏拍小票"),
                .step("长按锁屏 →「自定」→ 锁定屏幕"),
                .step("点底部左右两个按钮之一，换成 DSA 的「拍小票记账」"),
                .note("锁屏时按这个按钮直接拍小票，解锁后自动识别。"),
            ]
        case .widgets:
            [
                .step("长按主屏幕空白处 →「编辑」→「添加小组件」"),
                .step("搜「DSA」，选「今日支出」（小号或中号）；锁屏的小组件区域也可以加"),
                .note("月预算在记账页右上角的「分类与预算」里设置。"),
            ]
        case .csvImport:
            [
                .step("在银行 app、网银、支付宝或微信里导出交易记录（CSV）"),
                .step("DSA 记账页 → 右上角「识别账单」→「导入 CSV」，选择文件"),
                .step("看一遍要导入的记录再确认；以前记过的（包括 Apple Pay、邮件记的）默认不勾选"),
                .note("支持 CommBank、Westpac、NAB、ANZ、ING、Up、支付宝、微信支付，以及一般的银行流水格式。连上 Worker 后会自动分类。"),
            ]
        case .interests:
            [
                .step("打开新闻页右上角的「我的兴趣」（或 设置 → 新闻 → 我的兴趣）"),
                .step("点「+」，按大类选兴趣"),
                .step("之后每天 AI 根据你点开了什么、看了多久、👍👎 自动调整每个兴趣的长条；你也可以自己拖"),
                .note("第一天每个兴趣平均分条数。长条下面的「最近爱看」是自动学的，点一下可以改。"),
            ]
        case .newsBasics:
            [
                .step("打开 设置 → 新闻"),
                .step("关注的城市：加你所在和关心的城市，简报写天气、提醒极端天气"),
                .step("汇率：加你关心的货币对"),
                .step("对你的影响：按哪几方面总结（例如学业、投资、家里的生意），说明里写清楚你关心什么"),
                .step("每天几条、几点前生成好"),
                .note("用 Claude 时会提前一小时排队，半价生成。"),
            ]
        case .backgroundRefresh:
            [
                .step("iPhone 设置 → 通用 → 后台 App 刷新"),
                .step("确认总开关打开，并打开 DSA"),
            ]
        }
    }
}

/// 教程里的一块内容
enum GuideBlock {
    /// 小标题，开始新的一组（步骤重新编号）
    case heading(String)
    /// 编号的一步
    case step(String)
    /// 终端命令，带「复制」
    case command(String)
    /// 网址
    case link(String, String)
    case text(String)
    /// 小字提醒
    case note(String)
    /// 这台 app 的 Bundle ID（Google Cloud 里要填），带「复制」
    case bundleID
    /// 五家 AI 服务商的列表
    case providers
}

/// 一家 AI 服务商的 key 怎么拿
struct ProviderGuide: Identifiable {
    let id: String
    let name: String
    let site: String
    let url: String
    let steps: [String]
    let secret: String
    let notes: String
    /// 能力标签（联网搜索、看图这类从 Worker 读，这里是额外的）
    let extras: [String]
    /// 用真实账号完整测过
    let tested: Bool

    static let all: [ProviderGuide] = [
        ProviderGuide(
            id: "anthropic", name: "Claude", site: "platform.claude.com", url: "https://platform.claude.com/settings/keys",
            steps: [
                "打开 platform.claude.com，注册并登录",
                "Settings → Billing → Buy credits，先充值（没有余额用不了）",
                "Settings → API keys → Create key，复制 key（只显示一次）",
            ],
            secret: "ANTHROPIC_API_KEY",
            notes: "DSA 按 Claude 调试，效果最稳。每日简报用批处理，半价；深度报道会读原文并联网搜索。",
            extras: ["批处理半价"], tested: true
        ),
        ProviderGuide(
            id: "openai", name: "OpenAI", site: "platform.openai.com", url: "https://platform.openai.com/api-keys",
            steps: [
                "打开 platform.openai.com 登录",
                "Settings → Billing，先预充值（最少 5 美元）",
                "API keys → Create new secret key，复制 key",
            ],
            secret: "OPENAI_API_KEY",
            notes: "能联网搜索、能看图。",
            extras: [], tested: false
        ),
        ProviderGuide(
            id: "gemini", name: "Gemini", site: "aistudio.google.com", url: "https://aistudio.google.com/apikey",
            steps: [
                "打开 aistudio.google.com，用 Google 账号登录",
                "Get API key → Create API key，复制 key（新 key 以 AQ. 开头，是正常的）",
            ],
            secret: "GEMINI_API_KEY",
            notes: "有免费额度，不用绑卡；用免费额度时，Google 会用你的数据改进产品。能联网搜索、能看图。",
            extras: ["有免费额度"], tested: false
        ),
        ProviderGuide(
            id: "xai", name: "Grok", site: "console.x.ai", url: "https://console.x.ai",
            steps: [
                "打开 console.x.ai 登录",
                "Billing，先充值",
                "API Keys → Create API key，复制 key",
            ],
            secret: "XAI_API_KEY",
            notes: "能联网搜索、能看图。",
            extras: [], tested: false
        ),
        ProviderGuide(
            id: "deepseek", name: "DeepSeek", site: "platform.deepseek.com", url: "https://platform.deepseek.com/api_keys",
            steps: [
                "打开 platform.deepseek.com 登录",
                "Top up，先充值",
                "API keys → 创建 API key，复制 key",
            ],
            secret: "DEEPSEEK_API_KEY",
            notes: "价格便宜，但不能联网搜索，深度报道只读原文；「任务和记账」要用默认的 deepseek-flash 才能识别小票。",
            extras: [], tested: false
        ),
    ]
}
