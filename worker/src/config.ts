import { z } from "zod";
import { configuredProviders, PROVIDERS, type AIEnv } from "./ai";
import { PROVIDER_IDS, type AITask } from "./ai/types";
import { json } from "./http";
import { DEFAULT_TOPICS, GROUPS, LEGACY_TOPICS, TOPICS } from "./topics";

/**
 * 用户配置：称呼、关于我、特别关注、新闻设置、AI 服务。存在这个 Worker 自己的 KV 里（key = config），
 * 在 App 的设置里编辑。每个人部署自己的 Worker，所以这里就是个人的私密存储，代码里不写任何个人信息。
 * 每个字段都有默认值，旧数据或坏数据不会让请求失败
 */

export interface ConfigEnv extends AIEnv {
  NEWS: KVNamespace;
}

const CONFIG_KEY = "config";

const validTimezone = (tz: string) => {
  try {
    new Intl.DateTimeFormat("en", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
};

/** 逐项校验的数组：不合法的项（例如空字符串）单独丢掉，不会让整个列表变回默认值 */
function lenientArray<T extends z.ZodType>(item: T, max: number) {
  return z
    .array(z.unknown())
    .transform((items) =>
      items.flatMap((raw) => {
        const parsed = item.safeParse(raw);
        return parsed.success ? [parsed.data as z.infer<T>] : [];
      }).slice(0, max),
    )
    .catch([]);
}

const Place = z.object({
  /** 简报里天气的 id，例如 sydney */
  id: z.string().min(1).max(40),
  nameZh: z.string().max(40),
  nameEn: z.string().max(60),
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  /** ISO 国家代码，例如 AU */
  country: z.string().max(4).catch(""),
  /** 省 / 州，例如 New South Wales（用来抓澳洲气象局的警告） */
  admin1: z.string().max(60).catch(""),
});

/** 「对我的影响」分哪几方面 */
const Interest = z.object({
  id: z.string().regex(/^[a-z0-9_]{1,30}$/),
  nameZh: z.string().trim().min(1).max(20),
  nameEn: z.string().trim().max(30),
  /** 一两句说明，写进提示词 */
  hint: z.string().max(1500).catch(""),
});

const ModelChoice = z.object({
  provider: z.enum(PROVIDER_IDS),
  model: z.string().max(80).catch(""),
});

export const DEFAULT_INTERESTS: z.infer<typeof Interest>[] = [
  { id: "ai_tools", nameZh: "AI 工具", nameEn: "AI tools", hint: "能用的新 AI 模型和功能、价格变化" },
  { id: "markets", nameZh: "市场", nameEn: "Markets", hint: "股市、利率、汇率" },
  { id: "study", nameZh: "学业工作", nameEn: "Study & work", hint: "学业、工作、签证和职业机会" },
  { id: "life", nameZh: "生活", nameEn: "Life", hint: "所在城市的生活、交通、物价" },
  { id: "weather", nameZh: "天气", nameEn: "Weather", hint: "关注城市的天气" },
];

const NewsConfig = z.object({
  /** 选的兴趣（topics.ts 的 TOPICS）。旧版的话题 id 换成对应的兴趣，旧的地区话题去掉（地区改成从阅读里推断） */
  topics: z
    .array(z.string())
    .transform((ids) => {
      const mapped = ids.flatMap((id) => (TOPICS.some((t) => t.id === id) ? [id] : (LEGACY_TOPICS[id] ?? [])));
      const unique = mapped.filter((id, i) => mapped.indexOf(id) === i);
      return unique.length ? unique : DEFAULT_TOPICS;
    })
    .catch(DEFAULT_TOPICS),
  customFeeds: lenientArray(z.object({ name: z.string().trim().min(1).max(40), url: z.url({ protocol: /^https?$/ }) }), 10),
  count: z.number().int().min(5).max(30).catch(20),
  places: lenientArray(Place, 4),
  fxPairs: lenientArray(z.string().regex(/^[A-Z]{3}\/[A-Z]{3}$/), 6),
  interests: lenientArray(Interest, 6).transform((list) => (list.length ? list : DEFAULT_INTERESTS)),
  /** 每天几点（用户时区）之前生成好简报，HH:mm */
  briefTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/).catch("08:00"),
});

export const UserConfig = z.object({
  /** 称呼，写进提示词 */
  name: z.string().max(40).catch(""),
  /** 关于我：身份、关心什么。新闻挑选和「对我的影响」都靠它 */
  about: z.string().max(3000).catch(""),
  /** IANA 时区，App 保存时自动带上设备时区 */
  timezone: z.string().refine(validTimezone).catch("UTC"),
  /** 特别关注：命中的邮件即使不需要行动也要提醒 */
  watchRules: lenientArray(z.string().trim().min(1).max(1000), 10),
  news: NewsConfig.catch(() => NewsConfig.parse({})),
  /** 三组功能各用哪家的哪个模型；null = 用第一家配了 key 的服务商的默认模型 */
  ai: z
    .object({
      tasks: ModelChoice.nullable().catch(null),
      brief: ModelChoice.nullable().catch(null),
      report: ModelChoice.nullable().catch(null),
    } satisfies Record<AITask, unknown>)
    .catch({ tasks: null, brief: null, report: null }),
  updatedAt: z.string().catch(""),
});

export type UserConfig = z.infer<typeof UserConfig>;
export type Place = z.infer<typeof Place>;

export async function loadConfig(env: ConfigEnv): Promise<UserConfig> {
  const raw = await env.NEWS.get(CONFIG_KEY, "json").catch(() => null);
  return UserConfig.parse(raw ?? {});
}

/** 提示词里怎么称呼用户 */
export function displayName(config: UserConfig): string {
  return config.name.trim() || "用户";
}

/** GET /config：配置 + 各服务商是否配好 key + 新闻话题目录。PUT /config：保存 */
export async function handleConfig(request: Request, env: ConfigEnv): Promise<Response> {
  if (request.method === "PUT") {
    const body = await request.json().catch(() => null);
    if (!body || typeof body !== "object") return json({ error: "bad request" }, 400);
    const config = UserConfig.parse({ ...body, updatedAt: new Date().toISOString() });
    await env.NEWS.put(CONFIG_KEY, JSON.stringify(config));
    return json(await describe(env, config));
  }
  if (request.method === "GET") return json(await describe(env, await loadConfig(env)));
  return json({ error: "method not allowed" }, 405);
}

async function describe(env: ConfigEnv, config: UserConfig) {
  const configured = new Set(configuredProviders(env));
  return {
    config,
    providers: Object.values(PROVIDERS).map((p) => ({
      id: p.id,
      name: p.name,
      keyName: p.keyName,
      configured: configured.has(p.id),
      webSearch: p.webSearch,
      defaults: p.defaults,
      // App 用价格估算每天的花费
      models: Object.entries(p.models).map(([id, m]) => ({
        id,
        input: m.price.input,
        output: m.price.output,
        vision: m.vision ?? true,
      })),
    })),
    topics: TOPICS.map(({ id, nameZh, nameEn, group, feeds }) => ({ id, nameZh, nameEn, group, feeds: feeds.length })),
    groups: GROUPS,
  };
}
