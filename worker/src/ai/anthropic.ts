import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import type { z } from "zod";
import { parseOutput } from "./common";
import { bill } from "./registry";
import { AIError, type AIClient, type Billed, type Part, type StructuredRequest, type StructuredResult, type TokenUsage } from "./types";

/** 不支持 output_config.effort 的老模型（传了会报 400） */
const NO_EFFORT = ["claude-haiku-4", "claude-sonnet-4-5", "claude-sonnet-4-2", "claude-opus-4-1", "claude-opus-4-2", "claude-3"];

export function supportsEffort(model: string): boolean {
  return !NO_EFFORT.some((prefix) => model.startsWith(prefix));
}

export function usageOf(usage: Anthropic.Usage): TokenUsage {
  return {
    input: usage.input_tokens,
    cacheWrite: usage.cache_creation_input_tokens ?? 0,
    cacheRead: usage.cache_read_input_tokens ?? 0,
    output: usage.output_tokens,
    searches: usage.server_tool_use?.web_search_requests ?? 0,
    fetches: usage.server_tool_use?.web_fetch_requests ?? 0,
  };
}

function contentOf(content: string | Part[]): string | Anthropic.ContentBlockParam[] {
  if (typeof content === "string") return content;
  return content.map((p) =>
    p.type === "text"
      ? { type: "text", text: p.text }
      : {
          type: "image",
          source: { type: "base64", media_type: p.mediaType as Anthropic.Base64ImageSource["media_type"], data: p.data },
        },
  );
}

/** 同步调用和批处理用同一份请求参数（只取 format 的 type 和 schema，批处理的参数要能原样序列化） */
export function structuredParams<T>(model: string, req: StructuredRequest<T>): Anthropic.MessageCreateParamsNonStreaming {
  const { type, schema } = zodOutputFormat(req.schema);
  return {
    model,
    max_tokens: req.maxTokens,
    system: req.system,
    messages: [{ role: "user", content: contentOf(req.content) }],
    output_config: {
      format: { type, schema },
      ...(req.effort && supportsEffort(model) ? { effort: req.effort } : {}),
    },
  };
}

/** 从回复里取出 JSON 并校验；拒绝、被截断或者格式不对就抛错（带上已经花掉的钱） */
export function parseStructured<T>(model: string, message: Anthropic.Message, schema: z.ZodType<T>, discount = 1): StructuredResult<T> {
  const billed: Billed = bill("anthropic", model, usageOf(message.usage), discount);
  if (message.stop_reason === "refusal") throw new AIError("模型拒绝了这个请求", 502, billed);
  if (message.stop_reason === "max_tokens") throw new AIError("输出太长被截断了（max_tokens）", 502, billed);
  const text = message.content.find((b): b is Anthropic.TextBlock => b.type === "text")?.text ?? "";
  const parsed = parseOutput(text, schema);
  if (!parsed.ok) {
    console.error("Claude output does not match schema:", parsed.error);
    throw new AIError("Claude 返回的格式不对，请再试一次", 502, billed);
  }
  return { data: parsed.data, ...billed };
}

/** Claude API 的错误转成 AIError */
export function fromAnthropicError(err: unknown): never {
  if (err instanceof Anthropic.RateLimitError) throw new AIError("Claude 请求太频繁，请稍后再试", 429);
  if (err instanceof Anthropic.AuthenticationError) throw new AIError("ANTHROPIC_API_KEY 无效", 500);
  if (err instanceof Anthropic.APIError) throw new AIError(`Claude API 错误 ${err.status}：${err.message}`, 502);
  throw err;
}

export class AnthropicClient implements AIClient {
  readonly provider = "anthropic" as const;
  readonly client: Anthropic;

  constructor(
    apiKey: string,
    readonly model: string,
  ) {
    this.client = new Anthropic({ apiKey });
  }

  async structured<T>(req: StructuredRequest<T>): Promise<StructuredResult<T>> {
    let message: Anthropic.Message;
    try {
      message = await this.client.messages.create(structuredParams(this.model, req));
    } catch (err) {
      fromAnthropicError(err);
    }
    return parseStructured(this.model, message, req.schema);
  }

  // 深度报道用 Claude 自己的网页搜索 / 读取工具，单独实现（见 news.ts），不走 research
}
