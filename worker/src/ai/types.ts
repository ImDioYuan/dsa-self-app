import type { z } from "zod";

/** 支持的 AI 服务商 */
export const PROVIDER_IDS = ["anthropic", "openai", "gemini", "xai", "deepseek"] as const;
export type ProviderId = (typeof PROVIDER_IDS)[number];

/** 三组功能各自选服务商和模型 */
export const AI_TASKS = ["tasks", "brief", "report"] as const;
export type AITask = (typeof AI_TASKS)[number];

export type Effort = "low" | "medium" | "high";

/** 各家的 API key，都用 `wrangler secret put` 设置 */
export interface AIEnv {
  ANTHROPIC_API_KEY?: string;
  OPENAI_API_KEY?: string;
  GEMINI_API_KEY?: string;
  XAI_API_KEY?: string;
  DEEPSEEK_API_KEY?: string;
}

/** 一段输入：文字或图片（base64） */
export type Part = { type: "text"; text: string } | { type: "image"; mediaType: string; data: string };

export interface StructuredRequest<T> {
  system: string;
  content: string | Part[];
  schema: z.ZodType<T>;
  /** schema 的名字（OpenAI / Grok 要求） */
  name: string;
  maxTokens: number;
  effort?: Effort;
}

/** 各家用量换算成统一格式 */
export interface TokenUsage {
  /** 没命中缓存的输入 */
  input: number;
  cacheWrite: number;
  cacheRead: number;
  /** 输出，含思考 */
  output: number;
  searches: number;
  fetches: number;
}

export interface Billed {
  usage: TokenUsage;
  costUSD: number;
  /** 价格表里没有这个模型时为 false，花费只能按 0 记 */
  priced: boolean;
}

export interface StructuredResult<T> extends Billed {
  data: T;
}

/** 查资料、写稿（非 Claude 的深度报道第一步） */
export interface ResearchRequest {
  system: string;
  prompt: string;
  /** 原文链接，没有原生搜索的服务商只能读这些 */
  urls: string[];
  maxTokens: number;
  effort?: Effort;
  /** 最多搜索几次（有原生搜索时） */
  maxSearches: number;
}

export interface ResearchResult extends Billed {
  text: string;
  sources: { name: string; url: string }[];
}

export interface AIClient {
  readonly provider: ProviderId;
  readonly model: string;
  structured<T>(req: StructuredRequest<T>): Promise<StructuredResult<T>>;
  /** Claude 的深度报道有单独的实现，不用这个 */
  research?(req: ResearchRequest): Promise<ResearchResult>;
}

/** 调用失败。cost：失败前已经花掉的钱（格式不对、被截断时也要记账） */
export class AIError extends Error {
  constructor(
    message: string,
    readonly status = 502,
    readonly billed: Billed | null = null,
  ) {
    super(message);
  }
}

export function emptyUsage(): TokenUsage {
  return { input: 0, cacheWrite: 0, cacheRead: 0, output: 0, searches: 0, fetches: 0 };
}

export function addUsage(a: TokenUsage, b: TokenUsage): TokenUsage {
  return {
    input: a.input + b.input,
    cacheWrite: a.cacheWrite + b.cacheWrite,
    cacheRead: a.cacheRead + b.cacheRead,
    output: a.output + b.output,
    searches: a.searches + b.searches,
    fetches: a.fetches + b.fetches,
  };
}

export function addBilled(a: Billed, b: Billed): Billed {
  return { usage: addUsage(a.usage, b.usage), costUSD: a.costUSD + b.costUSD, priced: a.priced && b.priced };
}
