# DSA · Dio Self App

[English](#english) · [中文](#中文)

---

## English

A personal, Apple-style app for iPhone, iPad and Mac (one SwiftUI codebase, iOS 26 Liquid Glass). The UI is in Simplified Chinese; the daily news brief is bilingual (Chinese / English).

| Board | What it does |
|---|---|
| **Today** | Pulls to-dos from Apple Calendar, Reminders, subscribed iCal links (Moodle, Canvas, Google Calendar, Outlook…) and Gmail (an AI decides which emails need action). Eisenhower matrix, cross-source de-duplication. |
| **Ledger** | Manual entries in multiple currencies, budgets and charts; receipt scanning; Apple Pay automation via Shortcuts; payment receipts from Gmail; CSV import (Australian banks, Alipay, WeChat Pay); widgets, Control Center buttons and a Camera Control capture extension. |
| **News** | Every morning an AI picks stories for the interests you choose (about 50, from conflict and AI to music and pets) and writes a bilingual brief, plus "what it means for you", weather for your cities and FX rates. It learns from what you read: each interest has a slider that grows when you read it and shrinks when you don't, regions you read about are preferred, and two "you might like" stories a day suggest new interests. Deep reports are generated only when you tap the button. |

### Platforms

| Platform | Support |
|---|---|
| iPhone (iOS 26+) | Everything, including widgets, Control Center buttons and the Camera Control capture extension |
| iPad (iPadOS 26+) | The main app |
| Mac (macOS 26+) | Native Mac app (the three boards; no widgets or capture extension) |
| Backend | Your own Cloudflare Worker (free plan is enough) |

### How it fits together

```
App (iPhone / iPad / Mac) ──► your Cloudflare Worker ──► the AI provider you choose
         │                          │
  data stays on device       API keys (secrets) + your profile and news settings (KV)
```

Each person deploys their own Worker. Your API keys, personal profile ("about me", watch rules) and news settings live in **your** Worker; nothing personal is in this repository.

### AI providers

Set a key for any provider you want to use, then pick the provider and model for each feature group in the app (Settings → AI 模型).

| | Claude | OpenAI | Gemini | Grok | DeepSeek |
|---|---|---|---|---|---|
| Email analysis, bookkeeping | ✓ | ✓ | ✓ | ✓ | ✓ (JSON mode) |
| Receipt photos | ✓ | ✓ | ✓ | ✓ | `deepseek-flash` only |
| Daily brief | ✓ (Batch API, half price) | ✓ | ✓ | ✓ | ✓ |
| Deep reports | reads the articles + web search | web search | Google Search + URL context | web search | reads the original articles only |
| Tested with real API calls | ✓ | not yet | not yet | not yet | not yet |

Claude is the reference implementation. The other adapters are covered by unit tests against the documented request / response formats but have not been run against the real APIs yet. Model names and prices in `worker/src/ai/registry.ts` are as of October 2026; costs shown in the app are estimates.

### Setup

**1. App**

```bash
brew install xcodegen
cp Config/Local.example.xcconfig Config/Local.xcconfig   # fill in your bundle ID prefix and Apple team ID
xcodegen generate && open DSA.xcodeproj
```

Run on a simulator or "My Mac". A free Apple ID works for your own devices (apps expire after 7 days). The App Group name is derived from your bundle ID prefix, so it must be unique.

**2. Worker**（需要 Node.js 22 或更新版本和免费的 Cloudflare 账号）

```bash
cd worker
npm install
npx wrangler login
npx wrangler kv namespace create NEWS          # copy the id it prints
cp wrangler.example.toml wrangler.toml          # paste the KV id
npx wrangler secret put APP_TOKEN              # any random string, e.g. openssl rand -hex 24
npx wrangler secret put ANTHROPIC_API_KEY      # and/or OPENAI_API_KEY, GEMINI_API_KEY, XAI_API_KEY, DEEPSEEK_API_KEY
npx wrangler deploy
```

**3. In the app** (the 设置 tab): the first time you open the app, a short tour points you to 设置 → 用前配置 and its 一步一步配置 wizard, which walks through the four required steps one page at a time. 设置 → 用前配置 is also an in-app checklist with step-by-step guides for everything below (Worker, each AI provider's key, Gmail, calendars, Apple Pay automation…) and shows which steps are done. Enter the Worker URL and `APP_TOKEN` under Worker, then fill in 个人资料 (profile), AI 模型 (provider and model per feature), 今日 (calendars, email watch rules) and 新闻 (display language, interests, number of stories, cities, FX pairs, time).

**4. Optional**: Gmail (create an iOS OAuth client in Google Cloud with your bundle ID, enable the Gmail API, paste the client ID in 设置 → Gmail), subscribed calendars, forwarding a school or work mailbox to a Gmail label.

### Tests

```bash
cd worker && npm test && npm run typecheck
xcodebuild test -scheme DSA -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

---

## 中文

一个苹果风格的个人 app：iPhone / iPad / Mac 共用一套 SwiftUI 代码，界面用 iOS 26 的 Liquid Glass。

| 板块 | 功能 |
|---|---|
| **今日** | 从苹果日历、提醒事项、订阅日历（Moodle、Canvas、Google 日历、Outlook 等的 iCal 链接）和 Gmail（AI 判断哪些邮件要处理）整理待办；四象限；不同来源的同一件事自动合并。 |
| **记账** | 多币种手动记账、预算、图表；拍小票识别；快捷指令 + Apple Pay 自动记账；Gmail 付款收据自动记账；导入 CSV（澳洲银行、支付宝、微信）；小组件、控制中心按钮、相机控制键拍小票。 |
| **新闻** | 每天早上按你选的兴趣（约 50 个，从战争冲突、AI 到音乐、宠物）从 RSS 里挑新闻，写成中英双语简报，再写「对你的影响」、关注城市的天气和汇率。会学习你的喜好：每个兴趣一条长条，常看的变长、不看的慢慢变短；每个兴趣里还会学你「最近爱看」的具体内容（比如电子游戏里的塞尔达、股市里的特斯拉），会多推一条相关的，也会按它搜新闻，学错了可以删、漏了可以自己加；自动统计你常看的地区；每天 2 条「猜你喜欢」帮你发现新兴趣。深度报道点按钮才生成。 |

### 支持的系统

| 平台 | 支持情况 |
|---|---|
| iPhone（iOS 26+） | 全部功能，包括小组件、控制中心按钮、相机控制键拍小票 |
| iPad（iPadOS 26+） | 主 app |
| Mac（macOS 26+） | 原生 Mac 版（三个板块，没有小组件和拍小票扩展） |
| 后端 | 自己部署的 Cloudflare Worker（免费版就够） |

### 结构

每个人部署自己的 Worker。API key 存在 Worker 的 secret 里；「关于我」、特别关注规则、新闻设置存在 Worker 的 KV 里，在 app 的设置里编辑。仓库里没有任何个人信息。

### AI 服务商

给想用的服务商设置 key，然后在 app 的 设置 → AI 模型 里，给「任务和记账」「每日简报」「深度报道」三组功能分别选服务商和模型。各家能力见上面英文部分的表格：Claude 是实测过的参考实现；其他四家按官方文档写了适配和单元测试，**还没有用真实 API 实测**。`worker/src/ai/registry.ts` 里的模型和价格按 2026 年 10 月，app 里显示的花费是估算。

### 第一次运行

**1. App**

```bash
brew install xcodegen
cp Config/Local.example.xcconfig Config/Local.xcconfig   # 填你自己的 bundle ID 前缀和开发者团队 ID
xcodegen generate && open DSA.xcodeproj
```

改了 `project.yml` 或增删文件后要重新运行 `xcodegen generate`。免费 Apple ID 也能装到自己的设备上，7 天后要从 Xcode 重新安装。App Group 的名字由 bundle ID 前缀生成，必须全球唯一。

**2. Worker**

```bash
cd worker
npm install
npx wrangler login                              # 登录 Cloudflare（免费账号即可）
npx wrangler kv namespace create NEWS          # 记下显示的 id
cp wrangler.example.toml wrangler.toml          # 把 KV id 填进去
npx wrangler secret put APP_TOKEN              # 自己生成一串随机字符，例如 openssl rand -hex 24 的输出
npx wrangler secret put ANTHROPIC_API_KEY      # 想用哪家就设置哪家：OPENAI_API_KEY、GEMINI_API_KEY、XAI_API_KEY、DEEPSEEK_API_KEY
npx wrangler deploy                             # 第一次会让你起一个 workers.dev 子域名；部署后显示 https://dsa-worker.<子域名>.workers.dev
```

各家 API key 去哪里拿（都要先充值，Gemini 有免费额度）：Claude 在 platform.claude.com/settings/keys，OpenAI 在 platform.openai.com/api-keys，Gemini 在 aistudio.google.com/apikey，Grok 在 console.x.ai，DeepSeek 在 platform.deepseek.com/api_keys。设置后马上生效，不用重新部署。

本地调试：把 `.dev.vars.example` 复制成 `.dev.vars` 并填写，然后运行 `npm run dev`。

**3. App 里的设置**

第一次打开 app 时有新手引导：先指给你看底部的「设置」，再带你到 设置 → **用前配置** →「一步一步配置」，一页一步做完必需的 4 步（部署 Worker、连接、AI 的 key、个人资料），能在 app 里填的直接在那一页填。以后想再看一遍，在用前配置页底部点「重新看新手引导」。

用前配置 里还有完整的图文步骤（上面的部署、每家 AI 的 key、Gmail、订阅日历、Apple Pay 自动记账等），每一步会显示做完没有；必需的几步没做完时，「今日」顶部会提醒。

设置在底部的「设置」标签里：
1. Worker：填地址和 `APP_TOKEN`，点「测试连接」。
2. AI 模型：给三组功能选服务商和模型。
3. 个人资料：称呼、关于我（身份、城市、关心的事）。
4. 今日：苹果日历、提醒事项、订阅日历，以及邮件特别关注的规则。
5. 新闻：显示语言（中文 / English）、我的兴趣、每天几条和生成时间、关注的城市、汇率、「对你的影响」分哪几方面、自定义 RSS。
6. 我的兴趣（设置 → 新闻，或新闻页右上角）：选兴趣。第一天每个兴趣平均分条数，之后 AI 每天根据你点开了哪些新闻、看了多久、有没有 👍👎 自动调整长条，你也可以自己拖。长条下面是这个兴趣「最近爱看」的内容，点一下可以删改。阅读记录只存在你自己的 Worker 里；按爱看的内容搜新闻时，搜索词会发给 Bing 新闻。

### Gmail（可选）

1. 打开 console.cloud.google.com，新建项目
2. APIs & Services → Library → 搜索 **Gmail API** → Enable
3. Google Auth platform → **Get Started**：填 app 名称和你的邮箱；Audience 选 **External**；填联系邮箱；同意条款后 Create
4. Audience → Test users → Add users，加上你的 Gmail 地址
5. Clients → Create client → Application type 选 **iOS** → Bundle ID 填 `你的前缀.dsa`（和 `Config/Local.xcconfig` 一致，app 的用前配置里也能直接复制）→ Create
6. 复制 Client ID（形如 `123-xxx.apps.googleusercontent.com`），粘贴到 app 的 设置 → Gmail，点「登录 Gmail」；看到「Google 未验证此应用」时点继续

项目保持 Testing 状态即可；测试状态下登录 7 天后失效，到时候在设置里重新登录。

### 订阅日历（可选）

设置 → 今日 → 添加订阅日历，粘贴 iCal 链接并起个名字（任务上会显示这个名字）：

- Moodle：Calendar → 页面底部 Import or export calendars → Export calendar，Events to export 选 All events，Time period 选 Recent and next 60 days → Get calendar URL → Copy URL
- Canvas：Calendar → 右侧栏 Calendar Feed
- Google 日历（网页版）：设置 → 选日历 → 集成日历 →「iCal 格式的私密地址」
- Outlook（网页版）：设置 → 日历 → 共享日历 → 发布日历 → 复制 ICS 链接

### 学校 / 公司邮箱转发到 Gmail（可选）

把邮件转发到 Gmail 的 `+别名`，用过滤器归到一个标签并跳过收件箱，然后在 app 的 设置 → Gmail 填这个标签名，DSA 会读取它们并标成 Outlook 来源。

1. **先建 Gmail 过滤器**（顺序不能反，否则转发过来的邮件会先进收件箱）：搜索框右侧的筛选图标 → 「包含字词」填 `deliveredto:你的邮箱名+school@gmail.com` → 创建过滤器 → 勾选「跳过收件箱」「应用标签：School（新建）」「一律不发送到垃圾邮件」
2. **再开转发**：以 Outlook 为例，设置 → 邮件 → 转发 → 启用转发，填 `你的邮箱名+school@gmail.com`，勾选「保留转发邮件的副本」

### 花费

- 每日简报：20 条，Claude Sonnet 用批处理大约每天 $0.05–0.08；条数和兴趣越多越贵。打分和学习喜好是纯计算，不花钱；给新闻标「最近爱看」用的标签每天多花不到 $0.002。app 的 设置 → 新闻 会显示估算，新闻页底部显示实际花费和本月合计。
- 深度报道：点一次生成一篇，大约 $0.1–0.2，生成过的不再花钱。
- 邮件分析和记账用便宜的小模型，一般每月几美分。

### 测试

```bash
cd worker && npm test && npm run typecheck
xcodebuild test -scheme DSA -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

### 目录

```
project.yml          XcodeGen 配置，用它生成 DSA.xcodeproj
Config/              签名设置（Base.xcconfig 提交，Local.xcconfig 自己填）
DSA/                 App 源码：Models、Sources（各个数据源）、Services、Features（页面）、Ledger、News、Design
DSAWidgets/          小组件和控制中心按钮（iOS）
DSACapture/          相机控制键拍小票的扩展（iOS）
Shared/              app 和扩展共用的代码
DSATests/            App 的单元测试
worker/              Cloudflare Worker：src/ai（各家 AI 的适配）、config.ts（用户配置）、news.ts（新闻）、topics.ts（兴趣、地区和新闻源）、prefs.ts（学习喜好）
```
