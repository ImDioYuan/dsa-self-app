import { z } from "zod";
import type { ConfigEnv, UserConfig } from "./config";
import { COUNTRY_CODES, GLOBAL, nameOf, REGIONS, TOPICS } from "./topics";

/**
 * 学习用户的兴趣：
 * - App 记下每条新闻有没有点开、看了多久、有没有打开原文、👍👎（POST /news/feedback），Worker 记下深度报道
 * - 每天生成简报前，用昨天的简报和反馈给每个兴趣打分（0–100），分数决定明天每个兴趣几条：
 *   喜欢的慢慢升，不看的按固定斜率慢慢降到 0；没看新闻的日子不变
 * - 从读过的新闻里统计常看的地区，从「猜你喜欢」里发现新兴趣
 * - 每个兴趣里学「最近爱看」的小类（AI 给每条新闻标的具体游戏、公司、球队……），用户可以删、可以补
 * 都存在这个 Worker 自己的 KV 里（prefs、feedback:<日期>），不经过别人
 */

// MARK: - 参数

/** 新兴趣的初始分数 */
export const DEFAULT_LEVEL = 50;
/** 每往前一天，旧数据的权重乘这个数 */
export const DECAY = 0.8;
/** 每天最多涨、最多降几分 */
export const MAX_UP = 15;
export const MAX_DOWN = 10;
/** 分数低于这个的兴趣明天不推（再没看就继续降到 0） */
export const MIN_VISIBLE = 10;
/** 每天几条「猜你喜欢」 */
export const EXPLORE_SLOTS = 2;
/** 猜你喜欢的候选兴趣个数 */
export const CANDIDATES = 3;
/** 发现的兴趣累计到这个分数，就建议加入 */
export const DISCOVER_THRESHOLD = 3;
/** 点了「不感兴趣」之后多少天不再推荐 */
const DISMISS_DAYS = 30;
/** 常看地区最多几个 */
export const TOP_REGIONS = 3;
/** 每个兴趣「最近爱看」最多几个（不算用户自己加的） */
export const LIKED_PER_INTEREST = 3;
/** 小类累计得分到这个数才算爱看（例如读完 2 条，或者 1 条 👍） */
export const LIKED_MIN_ENGAGED = 3;
/** 每个兴趣给 AI 看几个已有的标签，让它原样复用 */
export const KNOWN_TAGS = 12;
/** 每个兴趣最多记几个小类 */
const TAGS_PER_INTEREST = 40;
/** 小类的推送次数衰减到这个数以下就忘掉（大约一周多没再出现） */
const TAG_FORGET = 0.2;

// MARK: - 反馈

export const ItemFeedback = z.object({
  open: z.number().int().min(0).optional(),
  seconds: z.number().min(0).optional(),
  link: z.number().int().min(0).optional(),
  report: z.boolean().optional(),
  vote: z.union([z.literal(-1), z.literal(0), z.literal(1)]).optional(),
});
export type ItemFeedback = z.infer<typeof ItemFeedback>;
export type DayFeedback = Record<string, ItemFeedback>;

/** 一条新闻的喜欢程度：点开 +1，看满 30 秒 +1，打开原文 +1，深度报道 +2，👍 +3，👎 −3 */
export function engagement(f: ItemFeedback | undefined): number {
  if (!f) return 0;
  let score = 0;
  if (f.open) score += 1;
  if ((f.seconds ?? 0) >= 30) score += 1;
  if (f.link) score += 1;
  if (f.report) score += 2;
  if (f.vote === 1) score += 3;
  if (f.vote === -1) score -= 3;
  return score;
}

export const FeedbackEvent = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  id: z.string().min(1).max(10),
  event: z.enum(["open", "read", "link", "vote"]),
  seconds: z.number().min(0).max(86_400).optional(),
  vote: z.union([z.literal(-1), z.literal(0), z.literal(1)]).optional(),
});
export type FeedbackEvent = z.infer<typeof FeedbackEvent>;

/** 把一次事件合进这条新闻的反馈 */
export function applyEvent(current: ItemFeedback | undefined, event: Omit<FeedbackEvent, "date" | "id"> | { event: "report" }): ItemFeedback {
  const next: ItemFeedback = { ...current };
  switch (event.event) {
    case "open":
      next.open = (next.open ?? 0) + 1;
      break;
    case "read":
      next.seconds = Math.round((next.seconds ?? 0) + ("seconds" in event ? (event.seconds ?? 0) : 0));
      break;
    case "link":
      next.link = (next.link ?? 0) + 1;
      break;
    case "vote":
      next.vote = "vote" in event ? (event.vote ?? 0) : 0;
      break;
    case "report":
      next.report = true;
      break;
  }
  return next;
}

// MARK: - 分数

/** 小类的名字（AI 标的或者用户加的） */
export const TagName = z.object({ zh: z.string(), en: z.string() });
export type TagName = z.infer<typeof TagName>;

const TagStat = z.object({
  interest: z.string(),
  zh: z.string(),
  en: z.string(),
  /** 衰减累计的推送条数和喜欢程度，和兴趣的 stats 一样算 */
  shown: z.number(),
  engaged: z.number(),
  /** 用户自己加的：一直算爱看，直到删掉 */
  pinned: z.boolean().optional(),
});
type TagStat = z.infer<typeof TagStat>;

export const Prefs = z.object({
  /** 每个兴趣的分数 0–100；没有的按 DEFAULT_LEVEL */
  levels: z.record(z.string(), z.number()).catch({}),
  /** 上一次打分前的分数（App 显示涨跌） */
  previous: z.record(z.string(), z.number()).catch({}),
  /** 每个兴趣衰减累计的推送条数和喜欢程度 */
  stats: z.record(z.string(), z.object({ shown: z.number(), engaged: z.number() })).catch({}),
  /** 常看地区的分数 */
  regions: z.record(z.string(), z.number()).catch({}),
  /** 猜你喜欢里发现的兴趣的分数 */
  discover: z.record(z.string(), z.number()).catch({}),
  /** 点了「不感兴趣」的兴趣和日期 */
  dismissed: z.record(z.string(), z.string()).catch({}),
  /** 每个兴趣里的小类（具体的游戏、公司、球队……），键是 tagKey(兴趣, 英文名) */
  tags: z.record(z.string(), TagStat).catch({}),
  /** 用户从「最近爱看」里删掉的小类和日期，DISMISS_DAYS 天内不再学 */
  mutedTags: z.record(z.string(), z.string()).catch({}),
  /** 打分打到哪一天的简报 */
  scoredThrough: z.string().catch(""),
});
export type Prefs = z.infer<typeof Prefs>;

export function emptyPrefs(seedRegions: string[] = []): Prefs {
  return {
    levels: {},
    previous: {},
    stats: {},
    regions: Object.fromEntries(seedRegions.map((id) => [id, 1])),
    discover: {},
    dismissed: {},
    tags: {},
    mutedTags: {},
    scoredThrough: "",
  };
}

export function levelOf(prefs: Prefs, id: string): number {
  return prefs.levels[id] ?? DEFAULT_LEVEL;
}

/** 简报里打分要用的字段 */
export interface ShownItem {
  id: string;
  category: string;
  region?: string;
  explore?: boolean;
  tags?: TagName[];
}

const clamp = (n: number, min: number, max: number) => Math.min(max, Math.max(min, n));

/**
 * 用一天的简报和反馈更新分数。这一天一条反馈都没有（没看新闻）就原样返回。
 * 只调整这一天推过、或者分数还没降到 0 但没推的兴趣；降到 0 的不动，等用户拖回来
 */
export function scoreDay(prefs: Prefs, topics: string[], items: ShownItem[], feedback: DayFeedback, date = ""): Prefs {
  if (!Object.keys(feedback).length) return prefs;
  const next: Prefs = structuredClone(prefs);
  next.previous = Object.fromEntries(topics.map((id) => [id, levelOf(prefs, id)]));

  // 旧数据衰减
  for (const stat of Object.values(next.stats)) {
    stat.shown *= DECAY;
    stat.engaged *= DECAY;
  }
  for (const map of [next.regions, next.discover]) {
    for (const id of Object.keys(map)) map[id] *= DECAY;
  }
  for (const tag of Object.values(next.tags)) {
    tag.shown *= DECAY;
    tag.engaged *= DECAY;
  }
  for (const [key, at] of Object.entries(next.mutedTags)) {
    if (date && daysBetween(at, date) >= DISMISS_DAYS) delete next.mutedTags[key];
  }
  const index = tagIndex(next);

  const shownToday = new Set<string>();
  for (const item of items) {
    const score = engagement(feedback[item.id]);
    if (item.explore) {
      next.discover[item.category] = Math.max(0, (next.discover[item.category] ?? 0) + score);
      continue;
    }
    if (topics.includes(item.category)) {
      const stat = (next.stats[item.category] ??= { shown: 0, engaged: 0 });
      stat.shown += 1;
      stat.engaged += score;
      shownToday.add(item.category);
      learnTags(next, index, item.category, item.tags ?? [], score);
    }
    if (score > 0 && item.region && item.region !== GLOBAL) {
      next.regions[item.region] = (next.regions[item.region] ?? 0) + score;
    }
  }

  // 目标分数 = 喜欢程度 ÷ 最喜欢的那个 × 100
  const rate = (id: string) => {
    const stat = next.stats[id];
    return stat && stat.shown > 0 ? Math.max(0, stat.engaged / stat.shown) : 0;
  };
  const best = Math.max(0, ...topics.filter((id) => shownToday.has(id)).map(rate));
  for (const id of topics) {
    const level = levelOf(prefs, id);
    let target: number;
    if (shownToday.has(id)) target = best > 0 ? (rate(id) / best) * 100 : 0;
    else if (level > 0 && level < MIN_VISIBLE) target = 0; // 分数太低今天没推：继续降
    else continue;
    next.levels[id] = Math.round(clamp(level + clamp(target - level, -MAX_DOWN, MAX_UP), 0, 100));
  }

  // 太小的去掉，免得越存越多
  for (const map of [next.regions, next.discover]) {
    for (const [id, value] of Object.entries(map)) if (value < 0.05) delete map[id];
  }
  forgetTags(next);
  return next;
}

// MARK: - 小类

const CJK = /[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]/;
const normalize = (name: string) => name.trim().toLowerCase().replace(/\s+/g, " ");

/** 小类的键：兴趣 + 英文名（没有英文名就用中文名），小写 */
export function tagKey(interest: string, name: string): string {
  return `${interest}:${normalize(name)}`;
}

/** 把模型给的标签整理一下：去空、去重、最多 3 个、每个最多 40 字 */
export function cleanTags(raw: TagName[] | undefined): TagName[] {
  const seen = new Set<string>();
  const out: TagName[] = [];
  for (const t of raw ?? []) {
    const zh = t.zh.trim().slice(0, 40);
    const en = t.en.trim().slice(0, 40);
    const id = normalize(en || zh);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({ zh: zh || en, en: en || zh });
    if (out.length >= 3) break;
  }
  return out;
}

/** 按兴趣 + 英文名或中文名找已有的小类：手动加的「原神」能对上 AI 写的「原神 / Genshin Impact」 */
function tagIndex(prefs: Prefs) {
  const index = new Map<string, string>();
  const add = (key: string) => {
    const tag = prefs.tags[key];
    for (const name of [tag.en, tag.zh]) if (name.trim()) index.set(tagKey(tag.interest, name), key);
  };
  for (const key of Object.keys(prefs.tags)) add(key);
  const find = (interest: string, name: TagName): string | undefined => {
    for (const n of [name.en, name.zh]) {
      const key = n.trim() ? index.get(tagKey(interest, n)) : undefined;
      if (key && prefs.tags[key]) return key;
    }
    return undefined;
  };
  return { find, add };
}

function isMuted(prefs: Prefs, interest: string, name: TagName): boolean {
  return [name.en, name.zh].some((n) => n.trim() && prefs.mutedTags[tagKey(interest, n)] !== undefined);
}

/** 一条新闻的得分记到它的每个小类上 */
function learnTags(prefs: Prefs, index: ReturnType<typeof tagIndex>, interest: string, names: TagName[], score: number): void {
  const done = new Set<string>();
  for (const name of cleanTags(names)) {
    let key = index.find(interest, name);
    // 删掉的不再学；删了又手动加回来的（已经有了）照常学
    if (!key && isMuted(prefs, interest, name)) continue;
    if (key) {
      // 手动加的只有一种写法：补上英文名，或者把英文写的中文名换成中文
      const tag = prefs.tags[key];
      if (!tag.en.trim()) tag.en = name.en;
      if (!CJK.test(tag.zh) && CJK.test(name.zh)) tag.zh = name.zh;
    } else {
      key = tagKey(interest, name.en || name.zh);
      prefs.tags[key] = { interest, zh: name.zh, en: name.en, shown: 0, engaged: 0 };
    }
    index.add(key);
    if (done.has(key)) continue;
    done.add(key);
    prefs.tags[key].shown += 1;
    prefs.tags[key].engaged += score;
  }
}

/** 很久没出现的小类忘掉；每个兴趣最多留 TAGS_PER_INTEREST 个（用户加的不删） */
function forgetTags(prefs: Prefs): void {
  const byInterest = new Map<string, [string, TagStat][]>();
  for (const [key, tag] of Object.entries(prefs.tags)) {
    if (tag.pinned) continue;
    if (tag.shown < TAG_FORGET) {
      delete prefs.tags[key];
      continue;
    }
    byInterest.set(tag.interest, [...(byInterest.get(tag.interest) ?? []), [key, tag]]);
  }
  for (const entries of byInterest.values()) {
    entries.sort((a, b) => b[1].shown - a[1].shown);
    for (const [key] of entries.slice(TAGS_PER_INTEREST)) delete prefs.tags[key];
  }
}

/**
 * 这个兴趣「最近爱看」的小类：用户加的排最前面，再加上学到的前 LIKED_PER_INTEREST 个。
 * 学到的要累计得分 ≥ LIKED_MIN_ENGAGED，并且看它不比看这个兴趣里别的新闻少（得分率不低于兴趣的平均），
 * 按累计得分从高到低。不再看了，数据衰减，自然就掉出去
 */
export function likedTags(prefs: Prefs, interest: string): string[] {
  const stat = prefs.stats[interest];
  const average = stat && stat.shown > 0 ? Math.max(0, stat.engaged / stat.shown) : 0;
  const entries = Object.entries(prefs.tags).filter(([, t]) => t.interest === interest);
  const pinned = entries.filter(([, t]) => t.pinned).sort((a, b) => b[1].engaged - a[1].engaged);
  const learned = entries
    .filter(([, t]) => !t.pinned && t.engaged >= LIKED_MIN_ENGAGED && t.engaged >= average * t.shown)
    .sort((a, b) => b[1].engaged - a[1].engaged || a[0].localeCompare(b[0]))
    .slice(0, LIKED_PER_INTEREST);
  return [...pinned, ...learned].map(([key]) => key);
}

/** 这个兴趣已有的标签（给 AI 原样复用）：用户加的和常出现的在前 */
export function knownTags(prefs: Prefs, interest: string, n = KNOWN_TAGS): TagName[] {
  return Object.values(prefs.tags)
    .filter((t) => t.interest === interest)
    .sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned) || b.shown - a.shown)
    .slice(0, n)
    .map(({ zh, en }) => ({ zh, en }));
}

/** 用户手动加一个爱看的小类；已经有了就标成用户加的 */
export function addTag(prefs: Prefs, interest: string, rawName: string): void {
  const name = rawName.trim().replace(/\s+/g, " ").slice(0, 40);
  if (!name) return;
  const tagName = CJK.test(name) ? { zh: name, en: "" } : { zh: name, en: name };
  delete prefs.mutedTags[tagKey(interest, name)];
  const key = tagIndex(prefs).find(interest, tagName);
  if (key) prefs.tags[key].pinned = true;
  else prefs.tags[tagKey(interest, name)] = { interest, ...tagName, shown: 0, engaged: 0, pinned: true };
}

/** 用户删掉一个小类：清空数据，DISMISS_DAYS 天内不再学 */
export function removeTag(prefs: Prefs, key: string, today: string): void {
  const tag = prefs.tags[key];
  prefs.mutedTags[key] = today;
  if (!tag) return;
  for (const n of [tag.en, tag.zh]) if (n.trim()) prefs.mutedTags[tagKey(tag.interest, n)] = today;
  delete prefs.tags[key];
}

// MARK: - 条数分配

/**
 * 明天每个兴趣几条：总条数里留 EXPLORE_SLOTS 条给猜你喜欢，其余按分数成比例分（最大余数法）。
 * 分数低于 MIN_VISIBLE 的不分；分得到的兴趣至少 1 条（条数够的话）。
 * 所有兴趣都降没了，就当作分数一样平均分
 */
export function allocate(levels: { id: string; level: number }[], total: number, exploreSlots = EXPLORE_SLOTS): Record<string, number> {
  const slots = Math.max(0, total - exploreSlots);
  const result: Record<string, number> = Object.fromEntries(levels.map((l) => [l.id, 0]));
  let active = levels.filter((l) => l.level >= MIN_VISIBLE);
  if (!active.length) active = levels.map((l) => ({ ...l, level: DEFAULT_LEVEL }));
  if (!active.length || !slots) return result;

  const sum = active.reduce((a, l) => a + l.level, 0);
  const raw = active.map((l) => ({ ...l, exact: (slots * l.level) / sum }));
  for (const r of raw) result[r.id] = Math.floor(r.exact);
  let left = slots - raw.reduce((a, r) => a + Math.floor(r.exact), 0);
  const byRemainder = [...raw].sort((a, b) => b.exact - Math.floor(b.exact) - (a.exact - Math.floor(a.exact)) || b.level - a.level);
  for (const r of byRemainder) {
    if (left <= 0) break;
    result[r.id] += 1;
    left -= 1;
  }

  // 分得到的兴趣至少 1 条：从条数最多的那里挪
  const ordered = [...active].sort((a, b) => b.level - a.level);
  for (const l of ordered) {
    if (result[l.id] > 0) continue;
    const donor = ordered.filter((d) => result[d.id] > 1).sort((a, b) => result[b.id] - result[a.id])[0];
    if (!donor) break;
    result[donor.id] -= 1;
    result[l.id] = 1;
  }
  return result;
}

// MARK: - 猜你喜欢

function hash(text: string): number {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
  return h >>> 0;
}

function daysBetween(from: string, to: string): number {
  return (Date.parse(to) - Date.parse(from)) / 86_400_000;
}

function dismissedRecently(prefs: Prefs, id: string, today: string): boolean {
  const at = prefs.dismissed[id];
  if (!at) return false;
  return daysBetween(at, today) < DISMISS_DAYS;
}

/**
 * 明天猜你喜欢的候选兴趣（没选过、最近没点「不感兴趣」）：
 * 1. 和你分数高的兴趣最相关的那个（发现过的加分）
 * 2. 相关兴趣里按日期轮换一个
 * 3. 所有没选的兴趣里按日期随机一个，保证有新意
 */
export function exploreCandidates(prefs: Prefs, topics: string[], today: string, n = CANDIDATES): string[] {
  const open = TOPICS.map((t) => t.id).filter((id) => !topics.includes(id) && !dismissedRecently(prefs, id, today));
  if (!open.length) return [];
  const score: Record<string, number> = {};
  for (const id of topics) {
    const level = levelOf(prefs, id);
    for (const related of TOPICS.find((t) => t.id === id)?.related ?? []) {
      if (open.includes(related)) score[related] = (score[related] ?? 0) + level;
    }
  }
  for (const [id, value] of Object.entries(prefs.discover)) {
    if (open.includes(id)) score[id] = (score[id] ?? 0) + value * 20;
  }
  const related = Object.keys(score).sort((a, b) => score[b] - score[a] || a.localeCompare(b));

  const picks: string[] = [];
  const add = (id: string | undefined) => {
    if (id && !picks.includes(id) && picks.length < n) picks.push(id);
  };
  add(related[0]);
  if (related.length > 1) add(related[1 + (hash(today) % (related.length - 1))]);
  const rest = open.filter((id) => !picks.includes(id));
  if (rest.length) add(rest[hash(`${today}#explore`) % rest.length]);
  for (const id of [...related, ...open]) add(id);
  return picks;
}

/** 值得建议加入的兴趣：猜你喜欢里常看的 */
export function suggestions(prefs: Prefs, topics: string[], today: string): string[] {
  return Object.entries(prefs.discover)
    .filter(([id, value]) => value >= DISCOVER_THRESHOLD && !topics.includes(id) && !dismissedRecently(prefs, id, today))
    .sort((a, b) => b[1] - a[1])
    .map(([id]) => id);
}

/** 常看的地区（分数从高到低） */
export function topRegions(prefs: Prefs, n = TOP_REGIONS): string[] {
  return Object.entries(prefs.regions)
    .filter(([id, value]) => value > 0 && REGIONS.some((r) => r.id === id))
    .sort((a, b) => b[1] - a[1])
    .slice(0, n)
    .map(([id]) => id);
}

// MARK: - 存储

const PREFS_KEY = "prefs";
/** 反馈留 14 天（打分只用前一天的，多留几天方便补打） */
const FEEDBACK_TTL = 14 * 86_400;

const feedbackKey = (date: string) => `feedback:${date}`;

/** 读取分数；第一次用关注的城市所在的国家当作常看的地区 */
export async function loadPrefs(env: ConfigEnv, config: UserConfig): Promise<Prefs> {
  const raw = await env.NEWS.get(PREFS_KEY, "json").catch(() => null);
  if (raw) return Prefs.parse(raw);
  const seeds = [...new Set(config.news.places.flatMap((p) => COUNTRY_CODES[p.country.toUpperCase()] ?? []))];
  return emptyPrefs(seeds);
}

export async function savePrefs(env: ConfigEnv, prefs: Prefs): Promise<void> {
  await env.NEWS.put(PREFS_KEY, JSON.stringify(prefs));
}

export async function recordFeedback(
  env: ConfigEnv,
  date: string,
  id: string,
  event: Omit<FeedbackEvent, "date" | "id"> | { event: "report" },
): Promise<void> {
  const key = feedbackKey(date);
  const day = ((await env.NEWS.get(key, "json").catch(() => null)) ?? {}) as DayFeedback;
  day[id] = applyEvent(day[id], event);
  await env.NEWS.put(key, JSON.stringify(day), { expirationTtl: FEEDBACK_TTL });
}

/** 前一天（YYYY-MM-DD） */
export function previousDate(date: string, days = 1): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) - days * 86_400_000).toISOString().slice(0, 10);
}

/**
 * 把还没打分的前几天的简报打完分（一般只有昨天一份；最多回看 3 天）。
 * 读简报和反馈各一次，纯计算，不调用 AI
 */
export async function ensureScored(env: ConfigEnv, config: UserConfig, today: string): Promise<Prefs> {
  let prefs = await loadPrefs(env, config);
  const yesterday = previousDate(today);
  if (prefs.scoredThrough >= yesterday) return prefs;

  for (let back = 3; back >= 1; back--) {
    const date = previousDate(today, back);
    if (date <= prefs.scoredThrough) continue;
    const [brief, feedback] = await Promise.all([
      env.NEWS.get<{ items: ShownItem[] }>(`brief:${date}`, "json"),
      env.NEWS.get<DayFeedback>(feedbackKey(date), "json"),
    ]);
    if (brief) prefs = scoreDay(prefs, config.news.topics, brief.items, feedback ?? {}, date);
  }
  prefs.scoredThrough = yesterday;
  await savePrefs(env, prefs);
  return prefs;
}

// MARK: - App 用的视图

/** GET /news/prefs 的返回：每个兴趣的分数、涨跌、明天几条、最近爱看；常看的地区；建议加入的兴趣 */
export function describePrefs(prefs: Prefs, config: UserConfig, today: string) {
  const levels = config.news.topics.map((id) => ({ id, level: levelOf(prefs, id) }));
  const counts = allocate(levels, config.news.count);
  const regionTotal = Object.values(prefs.regions).reduce((a, b) => a + b, 0) || 1;
  return {
    interests: levels.map(({ id, level }) => ({
      id,
      level,
      previous: prefs.previous[id] ?? level,
      count: counts[id] ?? 0,
      liked: likedTags(prefs, id).map((key) => {
        const tag = prefs.tags[key];
        return { key, nameZh: tag.zh || tag.en, nameEn: tag.en || tag.zh, pinned: !!tag.pinned };
      }),
    })),
    exploreCount: EXPLORE_SLOTS,
    regions: topRegions(prefs, 5).map((id) => ({ id, ...nameOf(id)!, share: Math.round((prefs.regions[id] / regionTotal) * 100) / 100 })),
    suggestions: suggestions(prefs, config.news.topics, today).map((id) => ({ id, ...nameOf(id)! })),
  };
}

export const PrefsUpdate = z.object({
  /** 用户拖过的长条 */
  levels: z.record(z.string(), z.number().min(0).max(100)).optional(),
  /** 不想再被推荐的兴趣 */
  dismiss: z.string().optional(),
  /** 手动加一个「最近爱看」的小类 */
  addTag: z.object({ interest: z.string(), name: z.string().min(1).max(40) }).optional(),
  /** 删掉一个小类（tagKey） */
  removeTag: z.string().max(100).optional(),
});
