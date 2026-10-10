import { z } from "zod";
import { bill, PROVIDERS } from "./registry";
import {
  AIError,
  addBilled,
  emptyUsage,
  type Billed,
  type ProviderId,
  type StructuredResult,
  type TokenUsage,
} from "./types";

/** zod → JSON Schema。去掉各家不认的字段（$schema、default、zod 给整数加的安全范围） */
export function jsonSchemaOf(schema: z.ZodType): Record<string, unknown> {
  const clean = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(clean);
    if (!node || typeof node !== "object") return node;
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(node)) {
      if (key === "$schema" || key === "default") continue;
      if ((key === "minimum" || key === "maximum") && Math.abs(Number(value)) === Number.MAX_SAFE_INTEGER) continue;
      out[key] = clean(value);
    }
    return out;
  };
  return clean(z.toJSONSchema(schema)) as Record<string, unknown>;
}

/** 写进提示词的格式要求（不支持 JSON Schema 的服务商用） */
export function schemaInstruction(schema: z.ZodType): string {
  return `\n\n## 输出格式\n只输出一个 JSON 对象（json），不要有其他文字，必须符合下面的 JSON Schema：\n${JSON.stringify(jsonSchemaOf(schema))}`;
}

export function parseOutput<T>(text: string, schema: z.ZodType<T>): { ok: true; data: T } | { ok: false; error: string } {
  const trimmed = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  let raw: unknown;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    return { ok: false, error: trimmed ? "不是合法的 JSON" : "输出是空的" };
  }
  const parsed = schema.safeParse(raw);
  if (parsed.success) return { ok: true, data: parsed.data };
  const issues = parsed.error.issues.slice(0, 3).map((i) => `${i.path.join(".") || "(根)"}：${i.message}`);
  return { ok: false, error: issues.join("；") };
}

/** 一次调用的原始结果 */
export interface RawTurn {
  text: string;
  usage: TokenUsage;
  stop: "ok" | "max_tokens" | "refusal";
}

/**
 * 调用、校验，格式不对时带上错误说明重试一次。已经花掉的钱会跟着 AIError 抛出去，好记账
 */
export async function structuredWithRetry<T>(
  provider: ProviderId,
  model: string,
  schema: z.ZodType<T>,
  run: (retryHint: string | null) => Promise<RawTurn>,
): Promise<StructuredResult<T>> {
  let billed: Billed = { usage: emptyUsage(), costUSD: 0, priced: true };
  let hint: string | null = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    let turn: RawTurn;
    try {
      turn = await run(hint);
    } catch (err) {
      if (err instanceof AIError && !err.billed && billed.costUSD > 0) throw new AIError(err.message, err.status, billed);
      throw err;
    }
    billed = addBilled(billed, bill(provider, model, turn.usage));
    if (turn.stop === "refusal") throw new AIError("模型拒绝了这个请求", 502, billed);
    if (turn.stop === "max_tokens") throw new AIError("输出太长被截断了（max_tokens）", 502, billed);
    const parsed = parseOutput(turn.text, schema);
    if (parsed.ok) return { data: parsed.data, ...billed };
    console.error(`${provider} output does not match schema: ${parsed.error}`);
    hint = `上一次的输出不符合要求（${parsed.error}）。请重新输出，只输出符合 JSON Schema 的 JSON。`;
  }
  throw new AIError(`${PROVIDERS[provider].name} 返回的格式不对，请再试一次`, 502, billed);
}

/** POST JSON；HTTP 错误转成 AIError（401/403 → key 无效，429 → 太频繁） */
export async function postJSON(
  provider: ProviderId,
  url: string,
  headers: Record<string, string>,
  body: unknown,
  timeoutMs = 280_000,
): Promise<any> {
  const name = PROVIDERS[provider].name;
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    throw new AIError(`连不上 ${name}：${err instanceof Error ? err.message : String(err)}`);
  }
  if (response.ok) return response.json();
  const detail = (await response.text().catch(() => "")).slice(0, 500);
  if (response.status === 401 || response.status === 403) {
    throw new AIError(`${PROVIDERS[provider].keyName} 无效或没有权限（${response.status}）`, 500);
  }
  if (response.status === 429) throw new AIError(`${name} 请求太频繁或额度用完了，请稍后再试`, 429);
  throw new AIHttpError(`${name} API 错误 ${response.status}：${detail}`, response.status, detail);
}

/** 带原始状态码，适配代码据此判断要不要去掉某个参数重试 */
export class AIHttpError extends AIError {
  constructor(
    message: string,
    readonly httpStatus: number,
    readonly detail: string,
  ) {
    super(message, 502);
  }
}

/** 400 且错误信息提到某个参数时，去掉它重试一次（例如模型不支持 reasoning effort） */
export async function retryWithout<T>(params: string[], run: (drop: Set<string>) => Promise<T>): Promise<T> {
  const drop = new Set<string>();
  for (;;) {
    try {
      return await run(drop);
    } catch (err) {
      const next =
        err instanceof AIHttpError && err.httpStatus === 400
          ? params.find((p) => !drop.has(p) && err.detail.toLowerCase().includes(p.toLowerCase()))
          : undefined;
      if (!next) throw err;
      drop.add(next);
    }
  }
}
