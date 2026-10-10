import { z } from "zod";
import { createClient, PROVIDERS, resolveChoice, supportsVision, type AIClient } from "./ai";
import { displayName, handleConfig, loadConfig, type UserConfig } from "./config";
import { aiErrorResponse, json } from "./http";
import { handleNews, runScheduledNews, type NewsEnv } from "./news";

export interface Env extends NewsEnv {
  /** app 和 Worker 共享的访问口令 */
  APP_TOKEN: string;
}
/** 每条消息最多发给模型的正文长度，控制成本（邮件签名、引用的历史邮件一般在后面） */
const MAX_BODY_CHARS = 2000;
const MAX_MESSAGES = 50;

// MARK: - 请求 / 返回格式

const InboxMessage = z.object({
  id: z.string().min(1),
  source: z.string(),
  from: z.string(),
  subject: z.string(),
  receivedAt: z.string(),
  body: z.string(),
});

const AnalyzeRequest = z.object({
  messages: z.array(InboxMessage).min(1).max(MAX_MESSAGES),
  now: z.string(),
  timezone: z.string(),
});

/** Claude 的结构化输出格式 */
const ExtractedTask = z.object({
  sourceId: z.string().describe("对应消息的 id，原样照抄"),
  title: z.string().describe("一句话说明要做什么，中文，25 字以内；课程代码和作业名保留原文，不写日期时间"),
  // 列表外的值不让整批结果作废：归为 info，没命中特别关注就会被过滤掉
  kind: z.enum(["deadline", "meeting", "reply", "info"]).catch("info"),
  due: z.string().nullable().describe("ISO 8601 时间，带时区偏移；没有明确时间则为 null"),
  importance: z.number().int().describe("1 不重要 / 2 一般 / 3 重要 / 4 很重要，只看后果，不看还剩多少时间"),
  reason: z.string().describe("一两句话说明依据，中文"),
  watched: z.boolean().describe("是否命中「特别关注」里的规则"),
});
const ExtractionResult = z.object({ tasks: z.array(ExtractedTask) });

/**
 * 邮件分析的系统提示词。称呼、个人介绍和特别关注规则来自用户配置（App 设置 → 个人资料），
 * 命中特别关注的消息即使不需要行动也要同步给用户
 */
function analyzePrompt(config: UserConfig): string {
  const name = displayName(config);
  const about = config.about.trim();
  const watch = config.watchRules.map((rule) => rule.trim()).filter(Boolean);
  return `你是${name}的私人助理，帮${name}从收到的邮件和消息里找出需要处理的事情。消息可能是中文或英文。
${about ? `\n## 关于${name}\n${about}\n` : ""}
对每条消息判断是否需要${name}采取行动，需要的话输出一条或多条任务：
- deadline：有截止时间的事（作业、缴费、报名、申请、续签等）
- meeting：和别人的约会、会议、课程安排变动、需要到场的活动
- reply：别人在等${name}回复或确认，但没有具体截止时间
- info：不需要行动的消息。广告、营销邮件、newsletter、系统通知、验证码、已经处理完的事一律归为 info，或直接不输出

重要程度（只看这件事本身有多重要、错过的后果有多大，和还剩多少时间无关——紧急程度 app 会按 due 自己算，用于四象限）：
- 4 很重要：影响成绩、钱、签证、工作机会的事，例如考试、作业提交、面试、缴费、签证材料
- 3 重要：需要认真对待，例如小测、老师或学校的直接要求、和朋友的约定、别人在等的私人回复
- 2 一般：做了更好、不做影响不大，例如讲座、可选活动、一般性的确认
- 1 不重要：几乎没有影响，例如群发通知里顺带提到的事

due 用用户所在时区的 ISO 8601 格式并带偏移，例如 2026-10-05T17:00:00+11:00。
"周五下午五点"这类相对时间根据当前时间推算；只有日期没有时间时用当天 23:59；完全没有提到时间则为 null。
title 里的课程代码和作业、测验名称保留原文，例如「提交 COMP3311 Assignment 2」，app 要靠它和订阅日历里的同一项对上；时间只写在 due 里，不要写进 title。
sourceId 必须原样照抄消息的 id。宁可漏掉无关紧要的消息，也不要把广告当成任务。
${
  watch.length
    ? `\n## 特别关注（优先于上面的规则）\n命中下面任意一条的消息，即使不需要行动也必须输出，并把 watched 设为 true；其他任务的 watched 为 false。\n${watch.map((rule) => `- ${rule}`).join("\n")}`
    : "\n没有特别关注的规则，watched 一律为 false。"
}`;
}

// MARK: - 入口

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (!(await isAuthorized(request, env))) {
      return json({ error: "unauthorized" }, 401);
    }
    if (url.pathname === "/health" && request.method === "GET") {
      return json({ ok: true });
    }
    if (url.pathname === "/config") {
      return handleConfig(request, env);
    }
    if (url.pathname === "/analyze" && request.method === "POST") {
      return analyze(request, env);
    }
    if (url.pathname === "/receipt" && request.method === "POST") {
      return receipt(request, env);
    }
    if (url.pathname === "/categorize" && request.method === "POST") {
      return categorize(request, env);
    }
    if (url.pathname === "/charges" && request.method === "POST") {
      return charges(request, env);
    }
    if (url.pathname.startsWith("/news/")) {
      return handleNews(request, url, env);
    }
    return json({ error: "not found" }, 404);
  },

  /** 每 15 分钟触发一次，到了用户设置的时间就生成新闻简报（见 news.ts） */
  async scheduled(controller, env): Promise<void> {
    await runScheduledNews(new Date(controller.scheduledTime), env);
  },
} satisfies ExportedHandler<Env>;

// MARK: - 「任务和记账」用的 AI

/** 按设置选服务商和模型（App → 设置 → AI 服务） */
async function tasksAI(env: Env): Promise<{ ai: AIClient; config: UserConfig }> {
  const config = await loadConfig(env);
  return { ai: createClient(env, resolveChoice(env, config.ai.tasks, "tasks")), config };
}

// MARK: - /analyze

async function analyze(request: Request, env: Env): Promise<Response> {
  const parsed = AnalyzeRequest.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return json({ error: "bad request", issues: parsed.error.issues }, 400);
  }
  const input = parsed.data;

  const messagesForModel = input.messages.map((m) => ({
    id: m.id,
    from: m.from,
    subject: m.subject,
    receivedAt: m.receivedAt,
    body: m.body.slice(0, MAX_BODY_CHARS),
  }));

  try {
    const { ai, config } = await tasksAI(env);
    const result = await ai.structured({
      system: analyzePrompt(config),
      content:
        `当前时间：${input.now}（时区 ${input.timezone}）\n` +
        `以下是 ${messagesForModel.length} 条消息：\n` +
        `<messages>\n${JSON.stringify(messagesForModel, null, 1)}\n</messages>`,
      schema: ExtractionResult,
      name: "tasks",
      maxTokens: 8000,
    });
    return json({ tasks: normalize(result.data.tasks, input.messages), usage: result.usage });
  } catch (err) {
    return aiErrorResponse(err);
  }
}

// MARK: - 记账：分类列表（由 app 传入）

const CategoryRef = z.object({ id: z.string().min(1), name: z.string() });

function categoryList(categories: z.infer<typeof CategoryRef>[]): string {
  return categories.map((c) => `${c.id}（${c.name}）`).join("、");
}

/** 模型返回的分类 id 不在列表里时，退回「其他」或第一个分类 */
function validCategory(id: string, categories: z.infer<typeof CategoryRef>[]): string {
  if (categories.some((c) => c.id === id)) return id;
  return categories.find((c) => c.id === "other")?.id ?? categories[0]?.id ?? "other";
}

// MARK: - /receipt：识别小票图片

const ReceiptRequest = z.object({
  image: z.string().min(1).max(7_000_000), // base64，app 端已缩到 1280px 以内
  mediaType: z.enum(["image/jpeg", "image/png", "image/webp", "image/gif"]).default("image/jpeg"),
  categories: z.array(CategoryRef).min(1).max(100),
  currencyHint: z.string().default("AUD"),
  timezone: z.string().default("UTC"),
});

const ReceiptResult = z.object({
  isReceipt: z.boolean().describe("图片是不是小票、发票、账单或付款截图"),
  merchant: z.string().describe("商家名，简短，保留原文"),
  total: z.number().nullable().describe("实际支付的总额（含税、扣除折扣后），看不出来为 null"),
  currency: z.string().describe("ISO 4217 货币代码，如 AUD、CNY"),
  date: z.string().nullable().describe("消费时间，格式 YYYY-MM-DDTHH:mm 或 YYYY-MM-DD，看不出来为 null"),
  categoryId: z.string().describe("从给定分类里选一个 id"),
  note: z.string().describe("一句话概括买了什么，中文，15 字以内"),
});

async function receipt(request: Request, env: Env): Promise<Response> {
  const parsed = ReceiptRequest.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return json({ error: "bad request", issues: parsed.error.issues }, 400);
  }
  const input = parsed.data;

  try {
    const { ai, config } = await tasksAI(env);
    if (!supportsVision(ai.provider, ai.model)) {
      return json({ error: `${PROVIDERS[ai.provider].name} 的 ${ai.model} 不能识别图片，请在 App 的 AI 服务里给「任务和记账」换一个能看图的模型` }, 400);
    }
    const result = await ai.structured({
      system:
        `你帮${displayName(config)}记账：从小票、发票或付款截图里读出商家、实付总额、币种、时间，并选一个最合适的分类。` +
        "总额要取最终实付金额（Total / 合计 / 实付），不是小计。看不出币种时用用户给的默认币种。",
      content: [
        { type: "image", mediaType: input.mediaType, data: input.image },
        {
          type: "text",
          text: `默认币种：${input.currencyHint}；时区：${input.timezone}\n` + `可选分类：${categoryList(input.categories)}`,
        },
      ],
      schema: ReceiptResult,
      name: "receipt",
      maxTokens: 1024,
    });
    const receipt = result.data;
    return json({
      ...receipt,
      currency: receipt.currency.toUpperCase(),
      categoryId: validCategory(receipt.categoryId, input.categories),
      usage: result.usage,
    });
  } catch (err) {
    return aiErrorResponse(err);
  }
}

// MARK: - /categorize：商家名 → 分类（Apple Pay 自动记账、CSV 导入用）

const CategorizeRequest = z.object({
  items: z
    .array(z.object({ id: z.string().min(1), merchant: z.string(), amount: z.number().optional() }))
    .min(1)
    .max(200),
  categories: z.array(CategoryRef).min(1).max(100),
});

const CategorizeResult = z.object({
  results: z.array(z.object({ id: z.string(), categoryId: z.string(), merchant: z.string().describe("整理后的商家名，去掉门店号、城市、卡号等，保留品牌名") })),
});

async function categorize(request: Request, env: Env): Promise<Response> {
  const parsed = CategorizeRequest.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return json({ error: "bad request", issues: parsed.error.issues }, 400);
  }
  const input = parsed.data;

  try {
    const { ai, config } = await tasksAI(env);
    const result = await ai.structured({
      system:
        `你帮${displayName(config)}给银行流水分类（时区 ${config.timezone}）。每一条根据商家名（可能是银行流水里的原始描述，如 WOOLWORTHS 1234 SYDNEY AU）` +
        "选一个最合适的分类 id，并把商家名整理成简短的品牌名（例如 Woolworths、Uber Eats、Opal）。id 原样照抄。",
      content: `可选分类：${categoryList(input.categories)}\n<items>\n${JSON.stringify(input.items)}\n</items>`,
      schema: CategorizeResult,
      name: "categories",
      maxTokens: 8000,
    });
    const ids = new Set(input.items.map((i) => i.id));
    return json({
      results: result.data.results
        .filter((r) => ids.has(r.id))
        .map((r) => ({ ...r, categoryId: validCategory(r.categoryId, input.categories) })),
      usage: result.usage,
    });
  } catch (err) {
    return aiErrorResponse(err);
  }
}

/**
 * - 丢掉 info（特别关注的除外）和对不上消息 id 的结果
 * - 同一条消息可能有多个任务，给 sourceId 加上序号，app 用它去重
 * - importance 限制在 1...4
 */
function normalize(
  tasks: z.infer<typeof ExtractedTask>[],
  messages: z.infer<typeof InboxMessage>[],
) {
  const ids = new Set(messages.map((m) => m.id));
  const counter = new Map<string, number>();

  return tasks
    .filter((t) => (t.kind !== "info" || t.watched) && ids.has(t.sourceId))
    .map((t) => {
      const n = counter.get(t.sourceId) ?? 0;
      counter.set(t.sourceId, n + 1);
      return {
        ...t,
        sourceId: `${t.sourceId}#${n}`,
        importance: Math.min(4, Math.max(1, Math.round(t.importance))),
        due: t.due && !Number.isNaN(Date.parse(t.due)) ? t.due : null,
      };
    });
}

// MARK: - /charges：从付款收据邮件里提取扣费记录（邮件自动记账）

const ChargesRequest = z.object({
  messages: z.array(InboxMessage).min(1).max(MAX_MESSAGES),
  categories: z.array(CategoryRef).min(1).max(100),
  incomeCategories: z.array(CategoryRef).max(50).default([]),
  currencyHint: z.string().default("AUD"),
  timezone: z.string().default("UTC"),
});

const ExtractedCharge = z.object({
  sourceId: z.string().describe("对应邮件的 id，原样照抄"),
  kind: z.enum(["expense", "refund"]).catch("expense").describe("expense = 扣款 / 付款；refund = 退款到账"),
  merchant: z.string().describe("商家或服务的品牌名，简短，例如 Netflix、Apple、Uber Eats、Optus"),
  amount: z.number().describe("实际扣款总额（含税），正数"),
  currency: z.string().describe("ISO 4217 货币代码"),
  date: z.string().nullable().describe("扣款时间，YYYY-MM-DDTHH:mm 或 YYYY-MM-DD；邮件里没写就用收件时间的日期"),
  categoryId: z.string().describe("expense 从支出分类里选，refund 从收入分类里选"),
  note: z.string().describe("一句话说明是什么，中文，15 字以内，例如「Netflix 月度订阅」"),
  recurring: z.boolean().describe("是否订阅续费 / 自动扣款 / 自动充值这类周期性扣费"),
});
const ChargesResult = z.object({ charges: z.array(ExtractedCharge) });

const CHARGES_PROMPT = `从邮件里找出「已经发生的付款」，每笔输出一条记录。

算作付款（输出）：
- 收据、发票（已付款）、付款确认、订单确认里写明已扣款的金额
- 订阅续费、自动扣款（direct debit）、自动充值（如 Opal auto top-up）、账单已自动支付
- 外卖、网购、打车、App Store / Google Play 等的消费收据
- 退款到账 → kind 为 refund

不算（不要输出）：
- 即将扣款的提醒、试用即将到期、价格调整通知、账单到期但还没付
- 付款失败、待付款、报价、购物车提醒、促销广告、发货 / 物流通知（除非里面写明了扣款）
- 银行月结单、余额通知、转账收款通知（不是消费）
- 同一笔付款在一封邮件里只输出一次；一封邮件有多笔不同的扣款才输出多条

amount 用最终实付总额（Total / Amount charged / 合计），不要小计。看不出币种时用用户给的默认币种。
sourceId 必须原样照抄邮件的 id。拿不准是不是已付款的，宁可不输出。`;

async function charges(request: Request, env: Env): Promise<Response> {
  const parsed = ChargesRequest.safeParse(await request.json().catch(() => null));
  if (!parsed.success) {
    return json({ error: "bad request", issues: parsed.error.issues }, 400);
  }
  const input = parsed.data;
  const messagesForModel = input.messages.map((m) => ({
    id: m.id,
    from: m.from,
    subject: m.subject,
    receivedAt: m.receivedAt,
    body: m.body.slice(0, MAX_BODY_CHARS),
  }));

  try {
    const { ai, config } = await tasksAI(env);
    const response = await ai.structured({
      system: `你帮${displayName(config)}记账：${CHARGES_PROMPT}`,
      content:
        `默认币种：${input.currencyHint}；时区：${input.timezone}\n` +
        `支出分类：${categoryList(input.categories)}\n` +
        `收入分类：${categoryList(input.incomeCategories)}\n` +
        `<emails>\n${JSON.stringify(messagesForModel, null, 1)}\n</emails>`,
      schema: ChargesResult,
      name: "charges",
      maxTokens: 8000,
    });

    const ids = new Set(input.messages.map((m) => m.id));
    const counter = new Map<string, number>();
    const result = response.data.charges
      .filter((c) => ids.has(c.sourceId) && Number.isFinite(c.amount) && Math.abs(c.amount) > 0)
      .map((c) => {
        const n = counter.get(c.sourceId) ?? 0;
        counter.set(c.sourceId, n + 1);
        const pool = c.kind === "refund" && input.incomeCategories.length > 0 ? input.incomeCategories : input.categories;
        return {
          ...c,
          // 同一封邮件可能有多笔扣款，加序号给 app 去重用
          externalId: `${c.sourceId}#${n}`,
          amount: Math.round(Math.abs(c.amount) * 100) / 100,
          currency: c.currency.toUpperCase(),
          categoryId: validCategory(c.categoryId, pool),
        };
      });
    return json({ charges: result, usage: response.usage });
  } catch (err) {
    return aiErrorResponse(err);
  }
}

// MARK: - 工具

async function isAuthorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!env.APP_TOKEN || !token) return false;

  // 先做哈希再比较，长度一致，避免时序攻击
  const enc = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(token)),
    crypto.subtle.digest("SHA-256", enc.encode(env.APP_TOKEN)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}
