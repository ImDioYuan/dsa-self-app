import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { AIError, bill, createClient, resolveChoice, type AIClient, type Billed, type ModelChoice, type TokenUsage } from "./ai";
import { fromAnthropicError, parseStructured, structuredParams, supportsEffort, usageOf } from "./ai/anthropic";
import { addBilled, emptyUsage } from "./ai/types";
import { displayName, loadConfig, type ConfigEnv, type Place, type UserConfig } from "./config";
import { aiErrorResponse, json } from "./http";
import { decodeEntities, readPrefix } from "./text";
import {
  allocate,
  ensureScored,
  EXPLORE_SLOTS,
  exploreCandidates,
  describePrefs,
  FeedbackEvent,
  levelOf,
  PrefsUpdate,
  recordFeedback,
  savePrefs,
  topRegions,
  type Prefs,
} from "./prefs";
import { BOM_WARNINGS, feedsFor, GLOBAL, nameOf, REGIONS, TOPICS, type TaggedFeed } from "./topics";

/**
 * 每日新闻：每天早上按用户的兴趣抓取 RSS、天气和汇率，让 AI 选出若干条写成中英双语简报；
 * 点开某条新闻、按下按钮时才生成深度报道（读原文 + 少量搜索），结果存进 KV，再打开不重复花钱。
 * 兴趣、条数、城市、汇率、时区和「关于我」都来自用户配置（config.ts）；每个兴趣几条、常看的地区、
 * 猜你喜欢的候选来自每天根据阅读情况打的分（prefs.ts）
 */

export type NewsEnv = ConfigEnv;

/** 简报和报道在 KV 里保留 60 天 */
const KEEP_SECONDS = 60 * 86_400;

// MARK: - 抓取参数

const USER_AGENT = "Mozilla/5.0 (compatible; DSA-News/1.0)";
/** 每个源只读开头这么多字节，最新的条目都在前面 */
const FEED_BYTES = 80_000;
/** 每个源最多解析这么多条（免费版 Worker 每次只有 10ms CPU，解析要省着用） */
const PARSE_LIMIT = 15;
const PER_FEED = 10;
const MAX_AGE_HOURS = 36;

// MARK: - 给模型的说明（按用户配置拼）

function aboutUser(config: UserConfig): string {
  const name = displayName(config);
  const about = config.about.trim() || "（没有填写个人介绍，按一般读者的兴趣判断。）";
  return `## 关于${name}\n${about}`;
}

function interestList(config: UserConfig): string {
  return config.news.interests.map((i) => `${i.id}（${i.nameZh}${i.hint ? `：${i.hint}` : ""}）`).join("；");
}

/** 这份简报的安排：每个兴趣几条、常看的地区、猜你喜欢的候选。批处理排队时存下来，取回时用同一份 */
export interface BriefPlan {
  allocation: Record<string, number>;
  regions: string[];
  candidates: string[];
}

export function planBrief(config: UserConfig, prefs: Prefs, date: string): BriefPlan {
  const topics = config.news.topics;
  const candidates = exploreCandidates(prefs, topics, date);
  const levels = topics.map((id) => ({ id, level: levelOf(prefs, id) }));
  return {
    allocation: allocate(levels, config.news.count, candidates.length ? EXPLORE_SLOTS : 0),
    regions: topRegions(prefs),
    candidates,
  };
}

/** 旧版排队的批处理没有存安排：每个兴趣一条 */
function fallbackPlan(config: UserConfig): BriefPlan {
  return { allocation: Object.fromEntries(config.news.topics.map((id) => [id, 1])), regions: [], candidates: [] };
}

export function totalOf(plan: BriefPlan): number {
  return Object.values(plan.allocation).reduce((a, b) => a + b, 0) + (plan.candidates.length ? EXPLORE_SLOTS : 0);
}

const topicLabel = (id: string) => {
  const topic = TOPICS.find((t) => t.id === id);
  return topic ? `${id}（${topic.nameZh}：${topic.hint}）` : id;
};

function briefPrompt(config: UserConfig, plan: BriefPlan, categories: string[], warnings: boolean): string {
  const name = displayName(config);
  const { places, interests, fxPairs, customFeeds } = config.news;
  const total = totalOf(plan);
  const cities = places.map((p) => p.nameZh || p.nameEn).join("、");
  const interestNames = interests.map((i) => i.nameZh).join("、");
  const quotas = Object.entries(plan.allocation)
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([id, n]) => `  - ${topicLabel(id)}：${n} 条`)
    .join("\n");
  const countries = REGIONS.filter((r) => r.continent).map((r) => `${r.id}（${r.nameZh}）`).join("、");
  const continents = REGIONS.filter((r) => !r.continent).map((r) => `${r.id}（${r.nameZh}）`).join("、");
  const liked = plan.regions.map((id) => nameOf(id)?.nameZh ?? id).join("、");

  const explore = plan.candidates.length
    ? `- 另外从标签为 explore/… 的标题里挑 ${EXPLORE_SLOTS} 条：这些领域${name}还没选，你根据他的兴趣和介绍判断他最可能感兴趣的。explore 为 true，category 填对应的兴趣 id（${plan.candidates.map(topicLabel).join("；")}），reasonZh / reasonEn 用一句话说明为什么推荐给他（例如「你常看 AI 新闻，这条讲 AI 芯片的出口限制」）。
- 其他新闻 explore 为 false，reasonZh / reasonEn 为空字符串。`
    : `- 所有新闻 explore 都为 false，reasonZh / reasonEn 为空字符串。`;

  const weather = places.length
    ? `## 天气（weather）
- 根据给定的天气预报${warnings ? "和澳洲气象局警告" : ""}，${cities}各写一句今明两天的天气（noteZh / noteEn），city 填城市 id（${places.map((p) => p.id).join("、")}）。
- 出现极端天气时 extreme 为 true：最高温 ≥ 35°C 或最低温 ≤ -10°C、日降水 ≥ 30 mm、阵风 ≥ 70 km/h、雷暴（天气代码 95–99）、大雪${warnings ? "，或者有影响这些城市的气象局警告" : ""}。
- extreme 为 true 时，在新闻里也放一条 weather 类新闻，region 填城市所在的国家，headlineIds 可以为空。`
    : `## 天气（weather）\n- 没有关注的城市，weather 输出空数组。`;

  return `你是${name}的私人新闻编辑。每天早上，你按${name}的兴趣从给定的新闻标题里挑出大约 ${total} 条，写成中英双语简报，再总结这些新闻对${name}有什么直接影响。

${aboutUser(config)}

## 选新闻
- ${name}的兴趣和每个兴趣大约几条（根据他平时爱看什么算出来的）：
${quotas}
- 某个兴趣当天的大新闻多可以多一条，没有重要的就少一条，不要为了凑数放进不重要的新闻。上面没有列出的领域不要，除非是影响很大的事。${customFeeds.length ? "\n- 标签为 custom 的是用户自己添加的新闻源，按内容归到上面的兴趣，都不合适就用 other。" : ""}
- 重要性 = 对世界的影响 + 和${name}的关系。同一件事被几家媒体报道时合并成一条，把这些标题的 id 都写进 headlineIds（最多 4 个）。
- 按重要性从高到低排列，一共大约 ${total} 条（标题实在不够时可以少一些）。
- importance：5 = 影响全球或直接影响${name}的大事，4 = 很重要，3 = 值得知道，2 或 1 = 一般。
- category 只能用这 ${categories.length} 个值之一：${categories.join("、")}。标题前面的标签只表示新闻来自哪个源，按新闻内容归类。

## 地区（region）
- region 填新闻主要涉及的国家：${countries}；涉及别的国家或者说不清是哪国时填所在的洲：${continents}；跨地区的大事填 global。${liked ? `\n- ${name}常看这些地区的新闻：${liked}。同样重要时优先选这些地区的，但其他地区的大事照样要选。` : ""}

## 猜你喜欢（explore）
${explore}

## 写法
- 只依据给定的标题和摘要，不要补充摘要里没有的数字、人名和细节；信息少就写得概括一点。
- titleZh 30 字以内，titleEn 15 个词以内。
- summaryZh / summaryEn：两三句话，讲清楚发生了什么、为什么重要。中文用自然的简体中文，不要翻译腔；英文简洁地道。
- 人名、地名、机构名中文用通用译名，不常见的在括号里注明英文。
- affectsMe：会直接影响${name}（${interestNames}）时为 true。

## 对${name}的影响（impact）
- overviewZh / overviewEn：一两句话总结今天和${name}最相关的事。
- points：3–6 条，每条写清楚具体影响和接下来该关注什么，itemRanks 填相关新闻在 items 里的序号（从 1 开始）。
  area 只能是其中之一：${interestList(config)}。
- 影响要写出传导链条，例如「红海局势升级 → 船只绕行好望角 → 运价上涨、到港推迟」${fxPairs.length ? "，可以结合给定的汇率数据" : ""}。今天没有相关新闻的方面就不要硬写。

${weather}`;
}

function reportPrompt(config: UserConfig): string {
  const name = displayName(config);
  const interestNames = config.news.interests.map((i) => i.nameZh).join("、");
  return `你是${name}的私人新闻编辑。${name}在今天的新闻简报里点开了一条新闻，想看深度报道。

${aboutUser(config)}

## 步骤
1. 用 web_fetch 打开给出的原文链接（打不开或者有付费墙就换另一个链接），需要时用 web_search 查背景和最新进展。
2. 写一篇中英双语深度报道，然后调用一次 submit_report 提交。

## 报道
- sections：4 节，依次是「发生了什么 / What happened」「来龙去脉 / Background」「各方说法 / Perspectives」「接下来关注 / What to watch」。每节中英文各 1–3 段，段落之间空一行。
- impactZh / impactEn：这件事对${name}的具体影响（${interestNames}）。没有明显影响就直说，不要硬凑。
- 事实以原文和搜索结果为准；不确定的写明「据报道」或「尚未证实」；不要编造数字和引语。
- 中文用自然的简体中文，英文简洁地道。可以用 **粗体** 标出关键数字和结论，不要用标题符号、列表或表格。
- sources：实际用到的文章，名称加链接。`;
}

// MARK: - 模型的输出格式

/** 分类：明天有条数的兴趣 + 猜你喜欢的候选 + 天气（有城市时）+ 其他（有自定义源时） */
function categoriesFor(config: UserConfig, plan: BriefPlan): string[] {
  return [
    ...Object.keys(plan.allocation).filter((id) => plan.allocation[id] > 0),
    ...plan.candidates,
    ...(config.news.places.length ? ["weather"] : []),
    ...(config.news.customFeeds.length ? ["other"] : []),
  ];
}

function briefSchema(categories: string[], config: UserConfig, plan: BriefPlan) {
  return z.object({
    items: z
      .array(
        z.object({
          category: z.string().describe(`只能是其中之一：${categories.join("、")}`),
          region: z.string().describe("国家或洲的 id，跨地区填 global"),
          explore: z.boolean().describe("是不是猜你喜欢"),
          reasonZh: z.string().describe("猜你喜欢的推荐理由，其他新闻为空"),
          reasonEn: z.string(),
          importance: z.number().int().describe("1–5，5 最重要"),
          titleZh: z.string(),
          titleEn: z.string(),
          summaryZh: z.string(),
          summaryEn: z.string(),
          headlineIds: z.array(z.string()).describe("依据的标题 id，例如 n12"),
          affectsMe: z.boolean(),
        }),
      )
      .describe(`按重要性从高到低，大约 ${totalOf(plan)} 条`),
    impact: z.object({
      overviewZh: z.string(),
      overviewEn: z.string(),
      points: z.array(
        z.object({
          area: z.string().describe(`只能是其中之一：${config.news.interests.map((i) => i.id).join("、")}`),
          titleZh: z.string(),
          titleEn: z.string(),
          detailZh: z.string(),
          detailEn: z.string(),
          itemRanks: z.array(z.number().int()).describe("相关新闻的序号，从 1 开始"),
        }),
      ),
    }),
    weather: z.array(
      z.object({
        city: z.string().describe(`城市 id：${config.news.places.map((p) => p.id).join("、") || "（无）"}`),
        extreme: z.boolean(),
        noteZh: z.string(),
        noteEn: z.string(),
      }),
    ),
  });
}

type BriefOut = z.infer<ReturnType<typeof briefSchema>>;

const ReportOut = z.object({
  titleZh: z.string(),
  titleEn: z.string(),
  sections: z.array(
    z.object({ headingZh: z.string(), headingEn: z.string(), bodyZh: z.string(), bodyEn: z.string() }),
  ),
  impactZh: z.string(),
  impactEn: z.string(),
  sources: z.array(z.object({ name: z.string(), url: z.string() })),
});

/** 深度报道用工具提交，因为网页搜索带引用，不能和结构化输出一起用 */
const SUBMIT_REPORT_TOOL: Anthropic.Tool = {
  name: "submit_report",
  description: "提交写好的中英双语深度报道。写完后调用一次。",
  strict: true,
  input_schema: (() => {
    const { $schema: _, ...schema } = z.toJSONSchema(ReportOut) as Record<string, unknown>;
    return schema as Anthropic.Tool.InputSchema;
  })(),
};

// MARK: - 存储格式（app 读取的就是这些）

interface Headline {
  id: string;
  source: string;
  /** 来源标签，例如 topic/ai、region/china、explore/music */
  tag: string;
  title: string;
  summary: string;
  link: string;
  published: Date | null;
}

interface WeatherDay {
  date: string;
  code: number;
  max: number;
  min: number;
  precip: number;
  gust: number;
}

interface FxRate {
  pair: string;
  rate: number;
  change7d: number | null;
}

type Names = Record<string, { nameZh: string; nameEn: string }>;

interface Brief {
  date: string;
  generatedAt: string;
  items: {
    id: string;
    rank: number;
    category: string;
    /** 国家或洲，跨地区为 global */
    region: string;
    /** 猜你喜欢 */
    explore?: boolean;
    reasonZh?: string;
    reasonEn?: string;
    importance: number;
    titleZh: string;
    titleEn: string;
    summaryZh: string;
    summaryEn: string;
    sources: { name: string; url: string; title: string }[];
    affectsMe: boolean;
  }[];
  impact: BriefOut["impact"];
  weather: {
    city: string;
    nameZh: string;
    nameEn: string;
    extreme: boolean;
    noteZh: string;
    noteEn: string;
    days: WeatherDay[];
  }[];
  fx: FxRate[];
  /** 分类和「影响」各方面的显示名字（App 按这个显示，认识的 id 用专门的图标） */
  categories: Names;
  regions: Names;
  interests: Names;
  /** batch：用 Batch API 半价生成的；priced：false 时模型不在价格表里，花费不准 */
  stats: {
    feeds: number;
    failedFeeds: string[];
    headlines: number;
    costUSD: number;
    batch?: boolean;
    priced?: boolean;
    model?: string;
  };
}

/** 组装简报需要的输入（排队等批处理时只存这些，标题只留组装要用的字段） */
interface BriefInputs {
  /** 旧版排队的批处理没有 */
  plan?: BriefPlan;
  headlines: Pick<Headline, "id" | "source" | "link" | "title">[];
  feeds: number;
  failedFeeds: string[];
  places: Place[];
  weather: WeatherDay[][] | null;
  fx: FxRate[];
}

/** 已经提交、还没取回的简报批处理 */
interface PendingBrief {
  batchId: string;
  model: string;
  submittedAt: string;
  inputs: BriefInputs;
}

/** 一篇深度报道实际用了多少（存在报道里，App 底部显示花费） */
interface ReportStats {
  costUSD: number;
  inputTokens: number;
  cacheWriteTokens: number;
  cacheReadTokens: number;
  outputTokens: number;
  searches: number;
  fetches: number;
  turns: number;
  priced?: boolean;
  model?: string;
}

interface Usage {
  usd: number;
  briefs: number;
  reports: number;
  /** 花了钱但没生成出来的次数（格式不对、被截断、批处理失败等） */
  failures?: number;
}

/** 累计多次请求的用量。报道生成到一半出错时，已经花掉的钱也能记上 */
class Meter {
  billed: Billed = { usage: emptyUsage(), costUSD: 0, priced: true };
  turns = 0;

  add(billed: Billed): void {
    this.billed = addBilled(this.billed, billed);
    this.turns += 1;
  }

  get cost(): number {
    return this.billed.costUSD;
  }

  stats(model: string): ReportStats {
    const u: TokenUsage = this.billed.usage;
    return {
      costUSD: round(this.billed.costUSD, 4),
      inputTokens: u.input,
      cacheWriteTokens: u.cacheWrite,
      cacheReadTokens: u.cacheRead,
      outputTokens: u.output,
      searches: u.searches,
      fetches: u.fetches,
      turns: this.turns,
      ...(this.billed.priced ? {} : { priced: false }),
      model,
    };
  }
}

class NewsError extends Error {
  constructor(
    message: string,
    readonly status = 502,
  ) {
    super(message);
  }
}

// MARK: - 入口

export async function handleNews(request: Request, url: URL, env: NewsEnv): Promise<Response> {
  try {
    const config = await loadConfig(env);
    if (url.pathname === "/news/dates" && request.method === "GET") {
      return json(await listDates(env, config));
    }
    if (url.pathname === "/news/brief" && request.method === "GET") {
      const date = url.searchParams.get("date") ?? localNow(config.timezone).date;
      if (!isDate(date)) return json({ error: "bad date" }, 400);
      const brief = await env.NEWS.get(`brief:${date}`);
      if (!brief) {
        const generating = (await env.NEWS.get(`lock:brief:${date}`)) !== null;
        return json({ error: "not_ready", date, generating }, 404);
      }
      // 原样拼进去，不用先解析再序列化
      return new Response(`{"brief":${brief}}`, { headers: { "Content-Type": "application/json; charset=utf-8" } });
    }
    if (url.pathname === "/news/generate" && request.method === "POST") {
      return await generate(request, env, config);
    }
    if (url.pathname === "/news/report" && request.method === "POST") {
      return await report(request, env, config);
    }
    if (url.pathname === "/news/feedback" && request.method === "POST") {
      const parsed = FeedbackEvent.safeParse(await request.json().catch(() => null));
      if (!parsed.success) return json({ error: "bad request", issues: parsed.error.issues }, 400);
      const { date, id, ...event } = parsed.data;
      await recordFeedback(env, date, id, event);
      return json({ ok: true });
    }
    if (url.pathname === "/news/prefs") {
      return await prefsRoute(request, env, config);
    }
    return json({ error: "not found" }, 404);
  } catch (err) {
    if (err instanceof NewsError) return json({ error: err.message }, err.status);
    return aiErrorResponse(err);
  }
}

/** GET：兴趣分数、明天几条、常看地区、建议加入的兴趣。PUT：拖长条、不想再被推荐某个兴趣 */
async function prefsRoute(request: Request, env: NewsEnv, config: UserConfig): Promise<Response> {
  const today = localNow(config.timezone).date;
  const prefs = await ensureScored(env, config, today);
  if (request.method === "PUT") {
    const parsed = PrefsUpdate.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return json({ error: "bad request", issues: parsed.error.issues }, 400);
    for (const [id, level] of Object.entries(parsed.data.levels ?? {})) {
      if (config.news.topics.includes(id)) prefs.levels[id] = Math.round(level);
    }
    if (parsed.data.dismiss) {
      prefs.dismissed[parsed.data.dismiss] = today;
      delete prefs.discover[parsed.data.dismiss];
    }
    await savePrefs(env, prefs);
  } else if (request.method !== "GET") {
    return json({ error: "method not allowed" }, 405);
  }
  return json(describePrefs(prefs, config, today));
}

/** Batch API 所有 token 五折 */
const BATCH_DISCOUNT = 0.5;

/** 一天里的各个时间点（分钟，用户时区），都相对设置的简报时间 */
function schedule(briefTime: string) {
  const [h, m] = briefTime.split(":").map(Number);
  const at = h * 60 + m;
  return {
    /** 提前一小时提交半价批处理 */
    batchFrom: Math.max(0, at - 60),
    /** 不用批处理的服务商提前一刻钟开始生成 */
    syncFrom: Math.max(0, at - 15),
    /** 批处理到这个时间还没完成，就取消掉马上生成（全价），保证早上有简报 */
    deadline: at + 30,
    /** 失败了每 15 分钟再试一次，到这个时间为止 */
    until: Math.min(24 * 60 - 1, at + 180),
  };
}

/**
 * 定时触发（每 15 分钟）：Claude 在简报时间前一小时起用 Batch API 半价生成，之后每次触发检查是否完成。
 * 批处理失败或者过了简报时间半小时还没完成，就改成马上生成；其他服务商直接生成。失败了下一次触发会再试
 */
export async function runScheduledNews(at: Date, env: NewsEnv): Promise<void> {
  const config = await loadConfig(env);
  const now = localNow(config.timezone, at);
  const times = schedule(config.news.briefTime);
  const pending = await env.NEWS.get<PendingBrief>(pendingKey(now.date), "json");
  try {
    if ((await env.NEWS.get(`brief:${now.date}`)) !== null) {
      // 用户已经点了「立即生成」，排队的那份不要了
      if (pending) await dropPending(env, now.date, pending);
      return;
    }
    if (pending) {
      const result = await collectBatch(env, config, now.date, pending);
      if (result === "done" || (result === "waiting" && now.minutes < times.deadline)) return;
      await dropPending(env, now.date, pending);
      await generateWithLock(env, config, now.date, now.weekday);
      return;
    }
    const choice = resolveChoice(env, config.ai.brief, "brief");
    const batch = choice.provider === "anthropic";
    if (now.minutes < (batch ? times.batchFrom : times.syncFrom) || now.minutes > times.until) return;
    if (!batch || now.minutes >= times.deadline) {
      // 不能批处理，或者已经太晚了（比如之前的尝试都失败了），直接生成
      await generateWithLock(env, config, now.date, now.weekday);
      return;
    }
    await submitBatch(env, config, choice, now.date, now.weekday);
  } catch (err) {
    console.error("news brief failed", err);
  }
}

function pendingKey(date: string): string {
  return `batch:brief:${date}`;
}

function anthropicClient(env: NewsEnv): Anthropic {
  return new Anthropic({ apiKey: env.ANTHROPIC_API_KEY ?? "" });
}

async function submitBatch(env: NewsEnv, config: UserConfig, choice: ModelChoice, date: string, weekday: string): Promise<void> {
  const inputs = await gatherInputs(env, config, date);
  requireEnoughHeadlines(inputs);
  const batch = await anthropicClient(env).messages.batches.create({
    requests: [{ custom_id: `brief-${date}`, params: structuredParams(choice.model, briefRequest(config, date, weekday, inputs)) }],
  });
  const pending: PendingBrief = {
    batchId: batch.id,
    model: choice.model,
    submittedAt: new Date().toISOString(),
    inputs: storedInputs(inputs),
  };
  await env.NEWS.put(pendingKey(date), JSON.stringify(pending), { expirationTtl: 2 * 86_400 });
}

/** 批处理完成就组装成简报；还在处理返回 waiting；出错、过期或者内容不能用返回 failed */
async function collectBatch(
  env: NewsEnv,
  config: UserConfig,
  date: string,
  pending: PendingBrief,
): Promise<"done" | "waiting" | "failed"> {
  const client = anthropicClient(env);
  const batch = await client.messages.batches.retrieve(pending.batchId);
  if (batch.processing_status !== "ended") return "waiting";

  const model = pending.model ?? "claude-sonnet-5-5";
  for await (const entry of await client.messages.batches.results(pending.batchId)) {
    if (entry.result.type !== "succeeded") {
      console.error("brief batch request not succeeded", entry.result.type);
      return "failed";
    }
    let result;
    try {
      const plan = pending.inputs.plan ?? fallbackPlan(config);
      result = parseStructured(model, entry.result.message, briefSchema(categoriesFor(config, plan), config, plan), BATCH_DISCOUNT);
    } catch (err) {
      console.error("brief batch output unusable", err);
      if (err instanceof AIError && err.billed) await addUsage(env, date, err.billed.costUSD, "failure");
      return "failed";
    }
    await assembleBrief(env, config, date, pending.inputs, result.data, result, model, true);
    await env.NEWS.delete(pendingKey(date));
    return "done";
  }
  return "failed";
}

/** 取消排队中的批处理（已经结束的取消会报错，忽略），删掉记录 */
async function dropPending(env: NewsEnv, date: string, pending: PendingBrief): Promise<void> {
  await anthropicClient(env)
    .messages.batches.cancel(pending.batchId)
    .catch(() => {});
  await env.NEWS.delete(pendingKey(date));
}

async function listDates(env: NewsEnv, config: UserConfig) {
  const today = localNow(config.timezone).date;
  const [list, usage, pending] = await Promise.all([
    env.NEWS.list({ prefix: "brief:" }),
    env.NEWS.get<Usage>(`usage:${today.slice(0, 7)}`, "json"),
    env.NEWS.get(pendingKey(today)),
  ]);
  const dates = list.keys.map((k) => k.name.slice("brief:".length)).sort().reverse();
  return { today, dates, monthCostUSD: usage?.usd ?? 0, todayPending: pending !== null };
}

// MARK: - /news/generate

const GenerateRequest = z.object({
  force: z.boolean().default(false),
  /** 只抓新闻源、不调用 AI，用来检查新闻源是否正常 */
  dryRun: z.boolean().default(false),
});

async function generate(request: Request, env: NewsEnv, config: UserConfig): Promise<Response> {
  const parsed = GenerateRequest.safeParse(await request.json().catch(() => ({})));
  if (!parsed.success) return json({ error: "bad request", issues: parsed.error.issues }, 400);
  const { force, dryRun } = parsed.data;
  const now = localNow(config.timezone);

  if (dryRun) {
    const inputs = await gatherInputs(env, config, now.date);
    const req = briefRequest(config, now.date, now.weekday, inputs);
    return json({
      plan: inputs.plan,
      feeds: inputs.feeds - inputs.failedFeeds.length,
      failedFeeds: inputs.failedFeeds,
      headlines: inputs.headlines.length,
      byTag: countBy(inputs.headlines, (h) => h.tag),
      promptChars: req.system.length + String(req.content).length,
      system: req.system,
      prompt: String(req.content).slice(0, 4000),
    });
  }

  if (!force) {
    const existing = await env.NEWS.get(`brief:${now.date}`);
    if (existing) return new Response(`{"brief":${existing}}`, { headers: { "Content-Type": "application/json; charset=utf-8" } });
  }
  const pending = await env.NEWS.get<PendingBrief>(pendingKey(now.date), "json");
  if (pending) {
    // 排队的批处理已经做完（钱已经花了）就直接用；还没做完就取消，马上生成，免得花两份钱
    if ((await collectBatch(env, config, now.date, pending).catch(() => "failed")) === "done") {
      const ready = await env.NEWS.get(`brief:${now.date}`);
      if (ready) return new Response(`{"brief":${ready}}`, { headers: { "Content-Type": "application/json; charset=utf-8" } });
    }
    await dropPending(env, now.date, pending);
  }
  const brief = await generateWithLock(env, config, now.date, now.weekday);
  return json({ brief });
}

async function generateWithLock(env: NewsEnv, config: UserConfig, date: string, weekday: string): Promise<Brief> {
  const lockKey = `lock:brief:${date}`;
  if ((await env.NEWS.get(lockKey)) !== null) throw new NewsError("今天的简报正在生成，请稍后刷新", 409);
  await env.NEWS.put(lockKey, "1", { expirationTtl: 600 });
  try {
    return await generateBrief(env, config, date, weekday);
  } finally {
    await env.NEWS.delete(lockKey);
  }
}

/** 同步生成（「立即生成」、批处理失败或太慢时、不支持批处理的服务商） */
async function generateBrief(env: NewsEnv, config: UserConfig, date: string, weekday: string): Promise<Brief> {
  const choice = resolveChoice(env, config.ai.brief, "brief");
  const inputs = await gatherInputs(env, config, date);
  requireEnoughHeadlines(inputs);

  const ai = createClient(env, choice);
  try {
    const result = await ai.structured(briefRequest(config, date, weekday, inputs));
    return await assembleBrief(env, config, date, storedInputs(inputs), result.data, result, choice.model, false, ai);
  } catch (err) {
    // 没生成出来也已经花了钱，记上
    if (err instanceof AIError && err.billed) await addUsage(env, date, err.billed.costUSD, "failure");
    throw err;
  }
}

function requireEnoughHeadlines(inputs: Inputs): void {
  const needed = Math.min(30, totalOf(inputs.plan) + 5);
  if (inputs.headlines.length < needed) {
    throw new NewsError(`只抓到 ${inputs.headlines.length} 条新闻，新闻源可能出了问题，或者选的兴趣太少`);
  }
}

/** 同步和批处理用同一份请求 */
function briefRequest(config: UserConfig, date: string, weekday: string, inputs: Inputs) {
  const { plan } = inputs;
  const categories = categoriesFor(config, plan);
  return {
    system: briefPrompt(config, plan, categories, inputs.warnings.length > 0 || hasBomPlace(config.news.places)),
    content: buildPrompt(config, date, weekday, inputs),
    schema: briefSchema(categories, config, plan),
    name: "news_brief",
    // 非流式请求超过约 21000 token 时 SDK 会要求改用流式
    maxTokens: Math.min(21_000, 8_000 + totalOf(plan) * 600),
    effort: "medium" as const,
  };
}

function storedInputs(inputs: Inputs): BriefInputs {
  return {
    plan: inputs.plan,
    headlines: inputs.headlines.map(({ id, source, link, title }) => ({ id, source, link, title })),
    feeds: inputs.feeds,
    failedFeeds: inputs.failedFeeds,
    places: inputs.places,
    weather: inputs.weather,
    fx: inputs.fx,
  };
}

function namesOf(ids: string[]): Names {
  const names: Names = {};
  for (const id of new Set(ids)) {
    const name = nameOf(id);
    if (name) names[id] = name;
  }
  return names;
}

/** 把模型的输出和抓到的输入组装成简报，保存并记账 */
async function assembleBrief(
  env: NewsEnv,
  config: UserConfig,
  date: string,
  inputs: BriefInputs,
  out: BriefOut,
  billed: Billed,
  model: string,
  batch: boolean,
  ai?: AIClient,
): Promise<Brief> {
  const byID = new Map(inputs.headlines.map((h) => [h.id, h]));
  const plan = inputs.plan ?? fallbackPlan(config);
  const categories = categoriesFor(config, plan);
  const interests = config.news.interests;
  const places = inputs.places ?? config.news.places;
  // 每个兴趣可以多一条
  const items = out.items.slice(0, totalOf(plan) + 2).map((item) => {
    const category = toCategory(item.category, categories);
    const explore = item.explore && plan.candidates.includes(category);
    return { ...item, category, region: toRegion(item.region), explore };
  });

  const brief: Brief = {
    date,
    generatedAt: new Date().toISOString(),
    items: items.map((item, i) => {
      const sources = [...new Set(item.headlineIds)]
        .map((id) => byID.get(id))
        .filter((h) => h !== undefined)
        .slice(0, 4)
        .map((h) => ({ name: h.source, url: h.link, title: h.title }));
      return {
        id: String(i + 1),
        rank: i + 1,
        category: item.category,
        region: item.region,
        ...(item.explore ? { explore: true, reasonZh: item.reasonZh, reasonEn: item.reasonEn } : {}),
        importance: Math.min(5, Math.max(1, Math.round(item.importance))),
        titleZh: item.titleZh,
        titleEn: item.titleEn,
        summaryZh: item.summaryZh,
        summaryEn: item.summaryEn,
        sources,
        affectsMe: item.affectsMe,
      };
    }),
    impact: {
      ...out.impact,
      points: out.impact.points.map((p) => ({
        ...p,
        area: toArea(p.area, interests.map((a) => a.id)),
        itemRanks: p.itemRanks.filter((r) => r >= 1 && r <= items.length),
      })),
    },
    weather: places.map((place, i) => {
      const note = out.weather.find((w) => toCity(w.city, places) === place.id);
      return {
        city: place.id,
        nameZh: place.nameZh || place.nameEn,
        nameEn: place.nameEn || place.nameZh,
        extreme: note?.extreme ?? false,
        noteZh: note?.noteZh ?? "",
        noteEn: note?.noteEn ?? "",
        days: inputs.weather?.[i] ?? [],
      };
    }),
    fx: inputs.fx,
    categories: namesOf(items.map((i) => i.category)),
    regions: namesOf(items.map((i) => i.region)),
    interests: Object.fromEntries(interests.map((i) => [i.id, { nameZh: i.nameZh, nameEn: i.nameEn }])),
    stats: {
      // 部署前排队的批处理没有 feeds 字段
      feeds: (inputs.feeds ?? inputs.failedFeeds.length) - inputs.failedFeeds.length,
      failedFeeds: inputs.failedFeeds,
      headlines: inputs.headlines.length,
      costUSD: round(billed.costUSD, 4),
      ...(batch ? { batch: true } : {}),
      ...(billed.priced ? {} : { priced: false }),
      model,
    },
  };

  let cost = billed.costUSD;
  const fix = await fixLanguages(ai ?? createClient(env, resolveChoice(env, config.ai.brief, "brief")), brief);
  if (fix) {
    cost += fix.costUSD;
    brief.stats.costUSD = round(cost, 4);
    if (!fix.priced) brief.stats.priced = false;
  }

  await env.NEWS.put(`brief:${date}`, JSON.stringify(brief), { expirationTtl: KEEP_SECONDS });
  await addUsage(env, date, cost, "brief");
  return brief;
}

const CJK = /[㐀-鿿]/g;
const TranslateOut = z.object({ texts: z.array(z.string()) });

/** 中文字段里一个汉字都没有（或英文字段一半以上是汉字）就算写错了语言 */
function wrongLanguage(text: string, want: "zh" | "en"): boolean {
  const t = text.trim();
  if (!t) return false;
  const han = t.match(CJK)?.length ?? 0;
  return want === "zh" ? han === 0 : han / t.length > 0.3;
}

/**
 * 简报里中文字段偶尔是空的或写成了英文（或反过来），比如「对你的影响」的标题。
 * 挑出写错语言的字段，用另一种语言的对应字段一次性补翻译。返回花了多少钱；出错就保持原样
 */
async function fixLanguages(ai: AIClient, brief: Brief): Promise<Billed | null> {
  type Text = Record<string, unknown>;
  const pairs: [Text, string, string][] = [
    ...brief.items.flatMap((i): [Text, string, string][] => [
      [i, "titleZh", "titleEn"],
      [i, "summaryZh", "summaryEn"],
    ]),
    [brief.impact, "overviewZh", "overviewEn"],
    ...brief.impact.points.flatMap((p): [Text, string, string][] => [
      [p, "titleZh", "titleEn"],
      [p, "detailZh", "detailEn"],
    ]),
    ...brief.weather.map((w): [Text, string, string] => [w, "noteZh", "noteEn"]),
  ];
  const jobs: { obj: Text; key: string; source: string; to: "zh" | "en" }[] = [];
  for (const [obj, zh, en] of pairs) {
    const zhText = String(obj[zh] ?? "").trim(), enText = String(obj[en] ?? "").trim();
    if (!zhText && !enText) continue;
    // 空着的也要补：App 会退回显示另一种语言
    if (!zhText || wrongLanguage(zhText, "zh")) jobs.push({ obj, key: zh, source: enText || zhText, to: "zh" });
    else if (!enText || wrongLanguage(enText, "en")) jobs.push({ obj, key: en, source: zhText, to: "en" });
  }
  if (jobs.length === 0) return null;

  try {
    const result = await ai.structured({
      system: "你是新闻简报的翻译。",
      content:
        "把下面每一条翻译成指定语言，用新闻简报的口吻，简洁自然，人名地名用通行译法。" +
        "按原顺序返回 texts，条数一样。\n\n" +
        JSON.stringify(jobs.map((j) => ({ to: j.to === "zh" ? "简体中文" : "English", text: j.source }))),
      schema: TranslateOut,
      name: "translations",
      maxTokens: 4000,
      effort: "low",
    });
    if (result.data.texts.length !== jobs.length) {
      console.error("fixLanguages: unexpected output");
      return result;
    }
    result.data.texts.forEach((text, i) => {
      if (text.trim() && !wrongLanguage(text, jobs[i].to)) jobs[i].obj[jobs[i].key] = text.trim();
    });
    console.log(`fixLanguages: fixed ${jobs.length} field(s)`);
    return result;
  } catch (err) {
    console.error("fixLanguages failed", err);
    return err instanceof AIError ? err.billed : null;
  }
}

// MARK: - /news/report

const ReportRequest = z.object({
  date: z.string().refine(isDate),
  id: z.string().min(1).max(4),
  /** false：只取已经生成过的，没有就返回 404，不调用 AI（打开详情页时用，点按钮才生成）。旧版 App 不传，默认生成 */
  generate: z.boolean().default(true),
});

async function report(request: Request, env: NewsEnv, config: UserConfig): Promise<Response> {
  const parsed = ReportRequest.safeParse(await request.json().catch(() => null));
  if (!parsed.success) return json({ error: "bad request", issues: parsed.error.issues }, 400);
  const { date, id, generate } = parsed.data;

  const key = `report:${date}:${id}`;
  const cached = await env.NEWS.get(key);
  if (cached) return new Response(`{"report":${cached}}`, { headers: { "Content-Type": "application/json; charset=utf-8" } });
  if (!generate) return json({ error: "not_generated" }, 404);

  const brief = await env.NEWS.get<Brief>(`brief:${date}`, "json");
  const item = brief?.items.find((i) => i.id === id);
  if (!item) return json({ error: "news item not found" }, 404);

  const choice = resolveChoice(env, config.ai.report, "report");
  const lockKey = `lock:${key}`;
  if ((await env.NEWS.get(lockKey)) !== null) throw new NewsError("这篇报道正在生成，请稍后再试", 409);
  await env.NEWS.put(lockKey, "1", { expirationTtl: 300 });
  const meter = new Meter();
  try {
    const content =
      choice.provider === "anthropic"
        ? await generateReportClaude(env, config, choice.model, date, item, meter)
        : await generateReportGeneric(createClient(env, choice), config, date, item, meter);
    const report = { ...content, stats: meter.stats(choice.model) };
    await env.NEWS.put(key, JSON.stringify(report), { expirationTtl: KEEP_SECONDS });
    await addUsage(env, date, meter.cost, "report");
    // 生成深度报道说明很感兴趣，记进阅读情况
    await recordFeedback(env, date, id, { event: "report" }).catch(() => {});
    return json({ report });
  } catch (err) {
    // 没生成出来也已经花了钱，记上
    if (err instanceof AIError && err.billed) meter.add(err.billed);
    if (meter.cost > 0) await addUsage(env, date, meter.cost, "failure");
    throw err;
  } finally {
    await env.NEWS.delete(lockKey);
  }
}

function reportUserPrompt(date: string, item: Brief["items"][number]): string {
  const sources = item.sources.map((s) => `- ${s.name}：${s.url}（${s.title}）`).join("\n");
  return (
    `简报日期：${date}\n` +
    `新闻：${item.titleZh} / ${item.titleEn}\n` +
    `摘要：${item.summaryZh}\n${item.summaryEn}\n` +
    `原文链接：\n${sources || "（没有原文链接，请用搜索查找）"}`
  );
}

/** Claude：读原文 + 搜索，用 submit_report 工具提交 */
async function generateReportClaude(
  env: NewsEnv,
  config: UserConfig,
  model: string,
  date: string,
  item: Brief["items"][number],
  meter: Meter,
) {
  const client = anthropicClient(env);
  const messages: Anthropic.MessageParam[] = [{ role: "user", content: reportUserPrompt(date, item) }];
  const tools: Anthropic.ToolUnion[] = [
    { type: "web_fetch_20260209", name: "web_fetch", max_uses: 4, max_content_tokens: 8000 },
    { type: "web_search_20260209", name: "web_search", max_uses: 3 },
    SUBMIT_REPORT_TOOL,
  ];

  for (let turn = 0; turn < 6; turn++) {
    let response: Anthropic.Message;
    try {
      response = await client.messages.create({
        model,
        max_tokens: 16000,
        // 开缓存后，搜索和抓到的网页会自动缓存：后面每一步按缓存价（一折）读取，不再全价重算。内容不变
        cache_control: { type: "ephemeral" },
        system: reportPrompt(config),
        tools,
        messages,
        ...(supportsEffort(model) ? { output_config: { effort: "medium" } } : {}),
      });
    } catch (err) {
      fromAnthropicError(err);
    }
    meter.add(bill("anthropic", model, usageOf(response.usage)));
    if (response.stop_reason === "refusal") throw new NewsError("模型拒绝生成这篇报道");

    const call = response.content.find(
      (b): b is Anthropic.ToolUseBlock => b.type === "tool_use" && b.name === "submit_report",
    );
    if (call) {
      const parsed = ReportOut.safeParse(call.input);
      if (!parsed.success) throw new NewsError("报道格式不正确，请重试");
      return { ...repairReport(parsed.data), generatedAt: new Date().toISOString() };
    }
    if (response.stop_reason === "max_tokens") throw new NewsError("报道太长被截断了，请重试");

    messages.push({ role: "assistant", content: response.content });
    // pause_turn：服务器端的搜索循环到了上限，原样发回去就会接着做；其他情况提醒它提交
    if (response.stop_reason !== "pause_turn") {
      messages.push({ role: "user", content: "请调用 submit_report 提交报道。" });
    }
  }
  throw new NewsError("没能生成报道，请重试");
}

/** 其他服务商分两步：先查资料写稿（原生搜索，或只读原文），再整理成和 Claude 一样的报道格式 */
async function generateReportGeneric(ai: AIClient, config: UserConfig, date: string, item: Brief["items"][number], meter: Meter) {
  if (!ai.research) throw new NewsError("这个服务商不支持生成深度报道");
  const system = reportPrompt(config)
    .replace(/## 步骤[\s\S]*?## 报道/, "## 步骤\n1. 打开给出的原文链接（打不开或者有付费墙就换另一个），需要时搜索背景和最新进展。\n2. 按下面的要求写一篇中英双语深度报道，最后列出实际用到的文章（名称和链接）。\n\n## 报道");
  const draft = await ai.research({
    system,
    prompt: reportUserPrompt(date, item),
    urls: item.sources.map((s) => s.url),
    maxTokens: 16000,
    effort: "medium",
    maxSearches: 3,
  });
  meter.add(draft);

  const formatted = await ai.structured({
    system: "把给出的深度报道稿整理成规定的格式。内容照搬，不要增删事实；段落之间空一行。sources 用稿子里列出的文章和给出的来源。",
    content:
      `报道稿：\n${draft.text}\n\n已知来源：\n` +
      (draft.sources.map((s) => `- ${s.name}：${s.url}`).join("\n") || "（无）") +
      "\n\nsections 依次是「发生了什么 / What happened」「来龙去脉 / Background」「各方说法 / Perspectives」「接下来关注 / What to watch」。",
    schema: ReportOut,
    name: "news_report",
    maxTokens: 16000,
    effort: "low",
  });
  meter.add(formatted);
  return { ...repairReport(formatted.data), generatedAt: new Date().toISOString() };
}

/** 模型有时把换行写成字面上的 \\n；impactZh 还会写过头，把 `","impactEn":"…"}` 或 `<parameter name="impactEn">…` 也写进去，真正的 impactEn 只剩 "placeholder" */
export function repairReport(r: z.infer<typeof ReportOut>): z.infer<typeof ReportOut> {
  const unescape = (t: string) => t.replaceAll("\\n", "\n").replaceAll('\\"', '"').trim();
  let { impactZh, impactEn } = r;
  const leak = /"\s*,(?:\s|\\n)*(?:"impactEn"\s*:\s*"|<parameter name="impactEn">)/.exec(impactZh);
  if (leak) {
    const leaked = impactZh.slice(leak.index + leak[0].length).replace(/(?:<\/parameter>|"\s*\}?)\s*$/, "");
    impactZh = impactZh.slice(0, leak.index);
    const en = impactEn.trim();
    if (!en || en.toLowerCase() === "placeholder" || en.length < leaked.length / 2) impactEn = leaked;
  }
  return {
    ...r,
    sections: r.sections.map((s) => ({ ...s, bodyZh: unescape(s.bodyZh), bodyEn: unescape(s.bodyEn) })),
    impactZh: unescape(impactZh),
    impactEn: unescape(impactEn),
  };
}

// MARK: - 抓取输入

interface Inputs {
  plan: BriefPlan;
  headlines: Headline[];
  feeds: number;
  failedFeeds: string[];
  places: Place[];
  weather: WeatherDay[][] | null;
  warnings: string[];
  fx: FxRate[];
}

/** 先用昨天的阅读情况打分，算出今天的安排，再按安排抓源 */
async function gatherInputs(env: NewsEnv, config: UserConfig, date: string): Promise<Inputs> {
  const now = new Date();
  const prefs = await ensureScored(env, config, date);
  const plan = planBrief(config, prefs, date);
  const feeds = feedsFor({ ...plan, custom: config.news.customFeeds });
  const places = config.news.places;
  const [collected, weather, warnings, fx] = await Promise.all([
    collectHeadlines(feeds, now),
    places.length ? fetchWeather(places).catch(() => null) : Promise.resolve([]),
    fetchWarnings(places).catch(() => []),
    fetchFx(date, config.news.fxPairs).catch(() => []),
  ]);
  return { ...collected, plan, feeds: feeds.length, places, weather, warnings, fx };
}

async function collectHeadlines(
  feeds: TaggedFeed[],
  now: Date,
): Promise<{ headlines: Headline[]; failedFeeds: string[] }> {
  const results = await Promise.allSettled(feeds.map((feed) => fetchFeed(feed.url)));
  const cutoff = now.getTime() - MAX_AGE_HOURS * 3_600_000;
  const headlines: Headline[] = [];
  const failedFeeds: string[] = [];
  const seenTitles = new Set<string>();
  // 源多的时候每个源少取几条，标题总数控制在 320 条左右（提示词长度和花费）
  const perFeed = Math.min(PER_FEED, Math.max(5, Math.floor(320 / Math.max(1, feeds.length))));

  results.forEach((result, i) => {
    const feed = feeds[i];
    if (result.status === "rejected") {
      failedFeeds.push(feed.name);
      return;
    }
    const fresh = result.value
      .filter((h) => h.title && h.link)
      .filter((h) => !h.published || (h.published.getTime() >= cutoff && h.published.getTime() <= now.getTime() + 3_600_000))
      .sort((a, b) => (b.published?.getTime() ?? 0) - (a.published?.getTime() ?? 0))
      .slice(0, perFeed);
    for (const h of fresh) {
      const key = h.title.toLowerCase();
      if (seenTitles.has(key)) continue;
      seenTitles.add(key);
      headlines.push({ ...h, id: `n${headlines.length + 1}`, source: feed.name, tag: feed.tag });
    }
  });
  return { headlines, failedFeeds };
}

type FeedEntry = { title: string; summary: string; link: string; published: Date | null };

async function fetchFeed(url: string): Promise<FeedEntry[]> {
  const response = await fetch(url, {
    headers: { "User-Agent": USER_AGENT, Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml" },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return parseFeed(await readPrefix(response, FEED_BYTES));
}

/** RSS（含 RDF）和 Atom 都支持。用 indexOf 找标签，比正则和完整的 XML 解析都省 CPU */
export function parseFeed(xml: string, limit = PARSE_LIMIT): FeedEntry[] {
  const entries: FeedEntry[] = [];
  const atom = xml.indexOf("<item") < 0;
  for (const block of elements(xml, atom ? "entry" : "item")) {
    if (entries.length >= limit) break;
    const date = tag(block, "pubDate") ?? tag(block, "published") ?? tag(block, "updated") ?? tag(block, "dc:date");
    const published = date ? new Date(clean(date, 60)) : null;
    entries.push({
      title: clean(tag(block, "title"), 200),
      // 有的源把整篇文章的 HTML 放在摘要里，先截一段再清理
      summary: clean((tag(block, "description") ?? tag(block, "summary") ?? tag(block, "content"))?.slice(0, 800), 220),
      link: linkOf(block),
      published: published && !Number.isNaN(published.getTime()) ? published : null,
    });
  }
  return entries;
}

/** 依次取出每个 <name ...>…</name> 的内容 */
function* elements(xml: string, name: string): Generator<string> {
  let from = 0;
  for (;;) {
    const found = openTag(xml, name, from);
    if (!found) return;
    const close = xml.indexOf(`</${name}>`, found.bodyStart);
    if (close < 0) return;
    yield xml.slice(found.bodyStart, close);
    from = close + name.length + 3;
  }
}

/** 第一个 <name ...> 里的内容；没有就是 undefined */
function tag(block: string, name: string): string | undefined {
  const found = openTag(block, name, 0);
  if (!found) return undefined;
  const close = block.indexOf(`</${name}>`, found.bodyStart);
  return close < 0 ? undefined : block.slice(found.bodyStart, close);
}

/** 找 <name> 或 <name 属性…>，跳过 <names> 这类更长的标签名和 <name … /> 这种自闭合的 */
function openTag(text: string, name: string, from: number): { bodyStart: number } | null {
  for (;;) {
    const start = text.indexOf(`<${name}`, from);
    if (start < 0) return null;
    const next = text.charCodeAt(start + name.length + 1);
    // > 空格 换行 回车 制表
    if (next === 62 || next === 32 || next === 10 || next === 13 || next === 9) {
      const end = text.indexOf(">", start);
      if (end < 0) return null;
      if (text.charCodeAt(end - 1) !== 47 /* / */) return { bodyStart: end + 1 };
    }
    from = start + 1;
  }
}

function linkOf(block: string): string {
  const rss = tag(block, "link");
  if (rss?.trim()) return clean(rss, 1000);
  const atom =
    /<link\b[^>]*rel="alternate"[^>]*href="([^"]+)"/.exec(block)?.[1] ?? /<link\b[^>]*href="([^"]+)"/.exec(block)?.[1];
  if (atom) return decodeEntities(atom);
  const guid = tag(block, "guid")?.trim();
  return guid && /^https?:\/\//.test(guid) ? guid : "";
}

/** 去掉 CDATA 和 HTML 标签，解码实体，压缩空白，截断 */
function clean(raw: string | undefined, max: number): string {
  if (!raw) return "";
  let s = raw.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
  s = decodeEntities(s)
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

const OpenMeteo = z.object({
  daily: z.object({
    time: z.array(z.string()),
    weather_code: z.array(z.number().nullable()),
    temperature_2m_max: z.array(z.number().nullable()),
    temperature_2m_min: z.array(z.number().nullable()),
    precipitation_sum: z.array(z.number().nullable()),
    wind_gusts_10m_max: z.array(z.number().nullable()),
  }),
});

/** Open-Meteo：关注城市未来 3 天，一次请求 */
async function fetchWeather(places: Place[]): Promise<WeatherDay[][]> {
  const params = new URLSearchParams({
    latitude: places.map((c) => c.lat).join(","),
    longitude: places.map((c) => c.lon).join(","),
    daily: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,wind_gusts_10m_max",
    timezone: "auto",
    forecast_days: "3",
  });
  const response = await fetch(`https://api.open-meteo.com/v1/forecast?${params}`, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`weather HTTP ${response.status}`);
  const body = await response.json();
  // 只有一个坐标时返回的是对象，不是数组
  const cities = z.array(OpenMeteo).parse(Array.isArray(body) ? body : [body]);
  return cities.map(({ daily: d }) =>
    d.time.map((date, i) => ({
      date,
      code: d.weather_code[i] ?? 0,
      max: d.temperature_2m_max[i] ?? 0,
      min: d.temperature_2m_min[i] ?? 0,
      precip: d.precipitation_sum[i] ?? 0,
      gust: d.wind_gusts_10m_max[i] ?? 0,
    })),
  );
}

function bomFeeds(places: Place[]): string[] {
  return [...new Set(places.filter((p) => p.country === "AU").map((p) => BOM_WARNINGS[p.admin1]).filter(Boolean))];
}

function hasBomPlace(places: Place[]): boolean {
  return bomFeeds(places).length > 0;
}

/** 澳洲气象局的天气警告（只有关注澳洲城市时才抓） */
async function fetchWarnings(places: Place[]): Promise<string[]> {
  const lists = await Promise.all(
    bomFeeds(places).map(async (url) => {
      const response = await fetch(url, { headers: { "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(10_000) });
      if (!response.ok) return [];
      return parseFeed(await readPrefix(response, 40_000)).map((e) => e.title);
    }),
  );
  return lists.flat();
}

const Frankfurter = z.object({ rates: z.record(z.string(), z.record(z.string(), z.number())) });

/** 汇率和一周涨跌（欧洲央行数据，Frankfurter）。一次请求取所有币种对欧元的汇率，再算交叉汇率 */
async function fetchFx(date: string, pairs: string[]): Promise<FxRate[]> {
  if (pairs.length === 0) return [];
  const currencies = [...new Set(pairs.flatMap((p) => p.split("/")))].filter((c) => c !== "EUR");
  const start = new Date(Date.parse(`${date}T00:00:00Z`) - 8 * 86_400_000).toISOString().slice(0, 10);
  const query = currencies.length ? `&symbols=${currencies.join(",")}` : "";
  const response = await fetch(`https://api.frankfurter.dev/v1/${start}..?base=EUR${query}`, {
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) return [];
  const { rates } = Frankfurter.parse(await response.json());
  const days = Object.keys(rates).sort();
  if (days.length === 0) return [];
  const perEUR = (r: Record<string, number>, c: string) => (c === "EUR" ? 1 : r[c]);
  const rate = (r: Record<string, number>, pair: string) => {
    const [base, quote] = pair.split("/");
    return perEUR(r, quote) / perEUR(r, base);
  };
  const first = rates[days[0]];
  const last = rates[days[days.length - 1]];
  return pairs
    .map((pair) => {
      const now = rate(last, pair);
      const before = rate(first, pair);
      return {
        pair,
        rate: round(now, 4),
        change7d: days.length > 1 && Number.isFinite(before) ? round((now / before - 1) * 100, 2) : null,
      };
    })
    .filter((r) => Number.isFinite(r.rate));
}

// MARK: - 拼提示词

function buildPrompt(config: UserConfig, date: string, weekday: string, inputs: Inputs): string {
  const shortTime = new Intl.DateTimeFormat("en-GB", {
    timeZone: config.timezone,
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const weather = inputs.places
    .map((place, i) => {
      const days = inputs.weather?.[i] ?? [];
      const text = days
        .map((d) => `${d.date.slice(5)} 代码${d.code} ${d.min}–${d.max}°C 降水${d.precip}mm 阵风${d.gust}km/h`)
        .join("；");
      return `${place.id} ${place.nameZh} ${place.nameEn}：${text || "（没有数据）"}`;
    })
    .join("\n");

  const fx = inputs.fx
    .map((r) => `${r.pair} ${r.rate}${r.change7d === null ? "" : `（一周 ${r.change7d >= 0 ? "+" : ""}${r.change7d}%）`}`)
    .join("\n");

  const headlines = inputs.headlines
    .map((h) => {
      const time = h.published ? shortTime.format(h.published) : "-";
      return `${h.id} | ${h.tag} | ${h.source} | ${time} | ${h.title}${h.summary ? ` — ${h.summary}` : ""}`;
    })
    .join("\n");

  return [
    `今天是 ${date}（${weekday}，${config.timezone} 时间）。`,
    ...(inputs.places.length ? [`<weather>\n${weather}\n</weather>`] : []),
    ...(hasBomPlace(inputs.places) ? [`<bom_warnings>\n${inputs.warnings.join("\n") || "（无）"}\n</bom_warnings>`] : []),
    ...(config.news.fxPairs.length ? [`<fx>\n${fx || "（没有数据）"}\n</fx>`] : []),
    `<headlines count="${inputs.headlines.length}">\nid | 来源标签 | 来源 | 发布时间 | 标题 — 摘要\n${headlines}\n</headlines>`,
  ].join("\n\n");
}

// MARK: - 工具

/** 用户时区的日期（YYYY-MM-DD）、从零点起的分钟数和星期 */
export function localNow(timezone: string, at = new Date()): { date: string; minutes: number; weekday: string } {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(at)
      .map((p) => [p.type, p.value]),
  );
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    minutes: Number(parts.hour) * 60 + Number(parts.minute),
    weekday: new Intl.DateTimeFormat("zh-CN", { timeZone: timezone, weekday: "long" }).format(at),
  };
}

/** 模型偶尔会用列表外的分类（比如照抄标题前的来源标签），归到最接近的那个，不让整份简报作废 */
const CATEGORY_ALIASES: Record<string, string> = {
  tech: "ai",
  tech_ai: "ai",
  technology: "big_tech",
  world: "diplomacy",
  international: "diplomacy",
  war: "conflict",
  business: "economy",
  finance: "markets",
  stocks: "markets",
  games: "gaming",
  game: "gaming",
  cars: "auto",
  ev: "auto",
  defense: "military",
  defence: "military",
  health: "medicine",
  movies: "film_tv",
  film: "film_tv",
  tv: "film_tv",
  custom: "other",
};

/** 去掉来源标签的前缀（topic/ai → ai），空格和连字符换成下划线 */
function normalizeID(raw: string): string {
  const key = raw.trim().toLowerCase().replace(/[\s-]+/g, "_");
  return key.includes("/") ? key.slice(key.lastIndexOf("/") + 1) : key;
}

export function toCategory(raw: string, allowed: string[]): string {
  const key = normalizeID(raw);
  if (allowed.includes(key)) return key;
  const alias = CATEGORY_ALIASES[key];
  if (alias && allowed.includes(alias)) return alias;
  return allowed.includes("other") ? "other" : (allowed[0] ?? "other");
}

const REGION_ALIASES: Record<string, string> = {
  cn: "china",
  prc: "china",
  hong_kong: "china",
  hongkong: "china",
  macau: "china",
  taiwan: "asia",
  usa: "us",
  united_states: "us",
  america: "us",
  gb: "uk",
  britain: "uk",
  united_kingdom: "uk",
  england: "uk",
  korea: "south_korea",
  au: "australia",
  nz: "new_zealand",
  eu: "europe",
  mideast: "middle_east",
  latam: "latin_america",
  world: GLOBAL,
  international: GLOBAL,
};

export function toRegion(raw: string): string {
  const key = normalizeID(raw);
  if (key === GLOBAL || REGIONS.some((r) => r.id === key)) return key;
  return REGION_ALIASES[key] ?? GLOBAL;
}

export function toArea(raw: string, allowed: string[]): string {
  const key = raw.trim().toLowerCase();
  if (allowed.includes(key)) return key;
  if ((key === "finance" || key === "market") && allowed.includes("markets")) return "markets";
  return allowed.includes("life") ? "life" : allowed[0];
}

export function toCity(raw: string, places: Place[]): string {
  const key = raw.trim().toLowerCase();
  const match =
    places.find((p) => p.id.toLowerCase() === key) ??
    places.find((p) => key.includes(p.id.toLowerCase()) || (p.nameZh && key.includes(p.nameZh)) || key.includes(p.nameEn.toLowerCase()));
  return match?.id ?? places[0]?.id ?? key;
}

function isDate(s: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(s);
}

async function addUsage(env: NewsEnv, date: string, usd: number, kind: "brief" | "report" | "failure"): Promise<void> {
  const key = `usage:${date.slice(0, 7)}`;
  const usage = (await env.NEWS.get<Usage>(key, "json")) ?? { usd: 0, briefs: 0, reports: 0 };
  usage.usd = round(usage.usd + usd, 4);
  if (kind === "brief") usage.briefs += 1;
  else if (kind === "report") usage.reports += 1;
  else usage.failures = (usage.failures ?? 0) + 1;
  await env.NEWS.put(key, JSON.stringify(usage), { expirationTtl: 400 * 86_400 });
}

function round(value: number, digits: number): number {
  const f = 10 ** digits;
  return Math.round(value * f) / f;
}

function countBy<T>(items: T[], key: (item: T) => string): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const item of items) counts[key(item)] = (counts[key(item)] ?? 0) + 1;
  return counts;
}
