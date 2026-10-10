import type { AIEnv, AITask, Billed, ProviderId, TokenUsage } from "./types";

/** 美元 / 百万 token；search：每次联网搜索的价格，不知道就不填 */
export interface ModelPrice {
  input: number;
  output: number;
  cacheRead?: number;
  cacheWrite?: number;
  search?: number;
}

interface ModelInfo {
  price: ModelPrice;
  /** 能不能看图（拍小票要用），默认能 */
  vision?: boolean;
}

export interface ProviderInfo {
  id: ProviderId;
  name: string;
  keyName: keyof AIEnv;
  /** 没在设置里选模型时，三组功能各用哪个 */
  defaults: Record<AITask, string>;
  models: Record<string, ModelInfo>;
  /** 有没有原生联网搜索（没有的话深度报道只读原文） */
  webSearch: boolean;
}

/**
 * 各家模型、价格和能力。价格按 2026-10 各家官网（DeepSeek 按高峰价，Gemini 3.8 Flash 按 2026 年内的价格），
 * 会过时，花费只是估算。新模型不在表里也能用，只是花费按 0 记、App 里显示「—」
 */
export const PROVIDERS: Record<ProviderId, ProviderInfo> = {
  anthropic: {
    id: "anthropic",
    name: "Claude",
    keyName: "ANTHROPIC_API_KEY",
    defaults: { tasks: "claude-haiku-5-5", brief: "claude-sonnet-5-5", report: "claude-sonnet-5-5" },
    models: {
      "claude-fable-5-1": { price: { input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5, search: 0.01 } },
      "claude-opus-5-5": { price: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5, search: 0.01 } },
      "claude-sonnet-5-5": { price: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, search: 0.01 } },
      "claude-sonnet-5": { price: { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5, search: 0.01 } },
      "claude-haiku-5-5": { price: { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125, search: 0.01 } },
      "claude-haiku-4-5": { price: { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25, search: 0.01 } },
    },
    webSearch: true,
  },
  openai: {
    id: "openai",
    name: "OpenAI",
    keyName: "OPENAI_API_KEY",
    defaults: { tasks: "gpt-6-luna", brief: "gpt-6.1-sol", report: "gpt-6.1-sol" },
    models: {
      "gpt-6-astra": { price: { input: 10, output: 50, cacheRead: 1, search: 0.01 } },
      "gpt-6.1-sol": { price: { input: 2, output: 10, cacheRead: 0.1, search: 0.01 } },
      "gpt-6-sol": { price: { input: 2, output: 10, cacheRead: 0.2, search: 0.01 } },
      "gpt-6-luna": { price: { input: 0.1, output: 0.5, cacheRead: 0.01, search: 0.01 } },
      "gpt-5.6-sol": { price: { input: 4, output: 20, cacheRead: 0.4, search: 0.01 } },
      "gpt-5.6-terra": { price: { input: 2, output: 12, cacheRead: 0.2, search: 0.01 } },
      "gpt-5.6-luna": { price: { input: 0.2, output: 1.2, cacheRead: 0.02, search: 0.01 } },
      "gpt-5-mini": { price: { input: 0.25, output: 2, cacheRead: 0.025, search: 0.01 } },
      "gpt-5-nano": { price: { input: 0.05, output: 0.4, cacheRead: 0.005, search: 0.01 } },
    },
    webSearch: true,
  },
  gemini: {
    id: "gemini",
    name: "Gemini",
    keyName: "GEMINI_API_KEY",
    defaults: { tasks: "gemini-3.5-flash-lite", brief: "gemini-3.8-flash", report: "gemini-3.8-flash" },
    models: {
      // 2027-01-01 起涨到 $1.50 / $7.50，缓存 $0.15
      "gemini-3.8-flash": { price: { input: 0.75, output: 3.75, cacheRead: 0.075, search: 0.014 } },
      "gemini-3.5-flash-lite": { price: { input: 0.3, output: 2.5, cacheRead: 0.03, search: 0.014 } },
    },
    webSearch: true,
  },
  xai: {
    id: "xai",
    name: "Grok",
    keyName: "XAI_API_KEY",
    defaults: { tasks: "grok-4.3", brief: "grok-4.7", report: "grok-4.7" },
    // 搜索价格官网没写清楚，不计入
    models: {
      "grok-4.7": { price: { input: 2, output: 6, cacheRead: 0.5 } },
      "grok-4.6": { price: { input: 2, output: 6, cacheRead: 0.5 } },
      "grok-4.5": { price: { input: 2, output: 6, cacheRead: 0.3 } },
      "grok-4.3": { price: { input: 1.25, output: 2.5, cacheRead: 0.2 } },
    },
    webSearch: true,
  },
  deepseek: {
    id: "deepseek",
    name: "DeepSeek",
    keyName: "DEEPSEEK_API_KEY",
    defaults: { tasks: "deepseek-flash", brief: "deepseek-v4-pro", report: "deepseek-v4-pro" },
    models: {
      "deepseek-flash": { price: { input: 0.3, output: 1.2, cacheRead: 0.006 } },
      "deepseek-v4-pro": { price: { input: 1.32, output: 3.96, cacheRead: 0.044 }, vision: false },
    },
    webSearch: false,
  },
};

/** 表里的模型；带日期后缀的版本（如 gpt-6.1-sol-2026-09-01）按最长前缀匹配 */
function modelInfo(provider: ProviderId, model: string): ModelInfo | undefined {
  const models = PROVIDERS[provider].models;
  if (models[model]) return models[model];
  const prefix = Object.keys(models)
    .filter((id) => model.startsWith(id))
    .sort((a, b) => b.length - a.length)[0];
  return prefix ? models[prefix] : undefined;
}

export function supportsVision(provider: ProviderId, model: string): boolean {
  return modelInfo(provider, model)?.vision ?? true;
}

export function bill(provider: ProviderId, model: string, usage: TokenUsage, discount = 1): Billed {
  const price = modelInfo(provider, model)?.price;
  if (!price) return { usage, costUSD: 0, priced: false };
  const tokens =
    usage.input * price.input +
    usage.cacheWrite * (price.cacheWrite ?? price.input) +
    usage.cacheRead * (price.cacheRead ?? price.input) +
    usage.output * price.output;
  const searchKnown = usage.searches === 0 || price.search !== undefined;
  const cost = (tokens / 1_000_000) * discount + usage.searches * (price.search ?? 0);
  return { usage, costUSD: cost, priced: searchKnown };
}

/** 配了 key 的服务商 */
export function configuredProviders(env: AIEnv): ProviderId[] {
  return (Object.keys(PROVIDERS) as ProviderId[]).filter((id) => Boolean(env[PROVIDERS[id].keyName]?.trim()));
}
