import { postJSON, retryWithout, schemaInstruction, structuredWithRetry, type RawTurn } from "./common";
import { fetchPageText } from "./fetchPage";
import { bill } from "./registry";
import {
  AIError,
  addBilled,
  emptyUsage,
  type AIClient,
  type Billed,
  type Part,
  type ResearchRequest,
  type ResearchResult,
  type StructuredRequest,
  type StructuredResult,
  type TokenUsage,
} from "./types";

/** DeepSeek：OpenAI 兼容的 Chat Completions 接口。只有 JSON 模式（没有 JSON Schema），也没有联网搜索 */
const BASE_URL = "https://api.deepseek.com";
/** 深度报道最多读几个网页 */
const MAX_FETCHES = 4;

interface ChatMessage {
  role: string;
  content: string | null;
  reasoning_content?: string | null;
  tool_calls?: { id: string; type: string; function: { name: string; arguments: string } }[];
}

interface ChatOutput {
  choices?: { message?: ChatMessage; finish_reason?: string }[];
  usage?: { prompt_tokens?: number; prompt_cache_hit_tokens?: number; prompt_cache_miss_tokens?: number; completion_tokens?: number };
}

function usageOf(r: ChatOutput): TokenUsage {
  const hit = r.usage?.prompt_cache_hit_tokens ?? 0;
  return {
    ...emptyUsage(),
    input: r.usage?.prompt_cache_miss_tokens ?? Math.max(0, (r.usage?.prompt_tokens ?? 0) - hit),
    cacheRead: hit,
    output: r.usage?.completion_tokens ?? 0,
  };
}

function userContent(content: string | Part[], extra: string | null) {
  if (typeof content === "string") return extra ? `${content}\n\n${extra}` : content;
  return [
    ...content.map((p) =>
      p.type === "text"
        ? { type: "text", text: p.text }
        : { type: "image_url", image_url: { url: `data:${p.mediaType};base64,${p.data}` } },
    ),
    ...(extra ? [{ type: "text", text: extra }] : []),
  ];
}

const FETCH_TOOL = {
  type: "function",
  function: {
    name: "fetch_url",
    description: "读取一个网页的正文。只能读新闻原文链接或可信的新闻网站。",
    parameters: {
      type: "object",
      properties: { url: { type: "string", description: "完整的 http(s) 链接" } },
      required: ["url"],
      additionalProperties: false,
    },
  },
};

export class ChatClient implements AIClient {
  readonly provider = "deepseek" as const;

  constructor(
    private readonly apiKey: string,
    readonly model: string,
  ) {}

  private call(body: Record<string, unknown>): Promise<ChatOutput> {
    return postJSON(this.provider, `${BASE_URL}/chat/completions`, { Authorization: `Bearer ${this.apiKey}` }, {
      ...body,
      model: this.model,
    });
  }

  structured<T>(req: StructuredRequest<T>): Promise<StructuredResult<T>> {
    return structuredWithRetry(this.provider, this.model, req.schema, async (hint): Promise<RawTurn> => {
      const r = await this.call({
        messages: [
          { role: "system", content: req.system + schemaInstruction(req.schema) },
          { role: "user", content: userContent(req.content, hint) },
        ],
        response_format: { type: "json_object" },
        max_tokens: req.maxTokens,
      });
      const choice = r.choices?.[0];
      return {
        text: choice?.message?.content ?? "",
        usage: usageOf(r),
        stop: choice?.finish_reason === "length" ? "max_tokens" : choice?.finish_reason === "content_filter" ? "refusal" : "ok",
      };
    });
  }

  /** 没有搜索：给模型一个读网页的工具，只读原文链接 */
  async research(req: ResearchRequest): Promise<ResearchResult> {
    const messages: Record<string, unknown>[] = [
      {
        role: "system",
        content: `${req.system}\n\n你没有搜索工具，只能用 fetch_url 读原文链接（最多 ${MAX_FETCHES} 次）。读不到时依据给出的摘要写，并说明信息有限。`,
      },
      { role: "user", content: req.prompt },
    ];
    let billed: Billed = { usage: emptyUsage(), costUSD: 0, priced: true };
    const sources = new Map<string, string>();
    let fetches = 0;

    for (let turn = 0; turn < MAX_FETCHES + 2; turn++) {
      let r: ChatOutput;
      try {
        // 思考模式下，同一轮里调工具时要不要带回 reasoning_content 各版本不一样：报错就去掉
        r = await retryWithout(["reasoning_content"], (drop) =>
          this.call({
            messages: drop.has("reasoning_content") ? messages.map(({ reasoning_content: _, ...m }) => m) : messages,
            tools: fetches < MAX_FETCHES ? [FETCH_TOOL] : undefined,
            max_tokens: req.maxTokens,
          }),
        );
      } catch (err) {
        if (err instanceof AIError && billed.costUSD > 0) throw new AIError(err.message, err.status, billed);
        throw err;
      }
      billed = addBilled(billed, bill(this.provider, this.model, usageOf(r)));
      const message = r.choices?.[0]?.message;
      const calls = message?.tool_calls ?? [];

      if (calls.length === 0) {
        const text = message?.content ?? "";
        if (!text.trim()) throw new AIError("DeepSeek 没有写出报道，请重试", 502, billed);
        return {
          text,
          sources: [...sources].map(([url, name]) => ({ name, url })),
          ...billed,
          usage: { ...billed.usage, fetches },
        };
      }

      messages.push({ role: "assistant", content: message?.content ?? "", reasoning_content: message?.reasoning_content, tool_calls: calls });
      for (const call of calls) {
        let url = "";
        try {
          url = String(JSON.parse(call.function.arguments).url ?? "");
        } catch {
          // 参数不是合法 JSON，下面按读取失败处理
        }
        const page = fetches < MAX_FETCHES ? await fetchPageText(url) : { ok: false, title: "", text: "读取次数用完了，请直接写报道" };
        fetches++;
        if (page.ok) sources.set(url, page.title || new URL(url).hostname);
        messages.push({ role: "tool", tool_call_id: call.id, content: page.ok ? `${page.title}\n\n${page.text}` : page.text });
      }
    }
    throw new AIError("DeepSeek 没能写完报道，请重试", 502, { ...billed, usage: { ...billed.usage, fetches } });
  }
}
