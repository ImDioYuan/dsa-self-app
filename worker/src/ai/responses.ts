import { jsonSchemaOf, postJSON, retryWithout, schemaInstruction, structuredWithRetry, type RawTurn } from "./common";
import { bill, PROVIDERS } from "./registry";
import {
  AIError,
  emptyUsage,
  type AIClient,
  type Part,
  type ResearchRequest,
  type ResearchResult,
  type StructuredRequest,
  type StructuredResult,
  type TokenUsage,
} from "./types";

/** OpenAI 和 Grok（xAI）都提供 Responses 接口，格式一样，只是地址和 key 不同 */
const BASE_URL = { openai: "https://api.openai.com/v1", xai: "https://api.x.ai/v1" } as const;

interface ResponsesOutput {
  status?: string;
  incomplete_details?: { reason?: string } | null;
  output?: {
    type: string;
    content?: { type: string; text?: string; refusal?: string; annotations?: { type: string; url?: string; title?: string }[] }[];
  }[];
  usage?: { input_tokens?: number; input_tokens_details?: { cached_tokens?: number }; output_tokens?: number };
  /** Grok 另外给的引用链接 */
  citations?: unknown[];
}

function usageOf(r: ResponsesOutput): TokenUsage {
  const cached = r.usage?.input_tokens_details?.cached_tokens ?? 0;
  return {
    ...emptyUsage(),
    input: Math.max(0, (r.usage?.input_tokens ?? 0) - cached),
    cacheRead: cached,
    output: r.usage?.output_tokens ?? 0,
    searches: (r.output ?? []).filter((o) => o.type === "web_search_call").length,
  };
}

function textOf(r: ResponsesOutput): { text: string; refused: boolean } {
  let text = "";
  let refused = false;
  for (const item of r.output ?? []) {
    if (item.type !== "message") continue;
    for (const part of item.content ?? []) {
      if (part.type === "output_text") text += part.text ?? "";
      if (part.type === "refusal") refused = true;
    }
  }
  return { text, refused };
}

function inputOf(content: string | Part[], extra: string | null) {
  const parts = typeof content === "string" ? [{ type: "text" as const, text: content }] : content;
  return [
    {
      role: "user",
      content: [
        ...parts.map((p) =>
          p.type === "text"
            ? { type: "input_text", text: p.text }
            : { type: "input_image", image_url: `data:${p.mediaType};base64,${p.data}` },
        ),
        ...(extra ? [{ type: "input_text", text: extra }] : []),
      ],
    },
  ];
}

export class ResponsesClient implements AIClient {
  constructor(
    readonly provider: "openai" | "xai",
    private readonly apiKey: string,
    readonly model: string,
  ) {}

  private call(body: Record<string, unknown>): Promise<ResponsesOutput> {
    return postJSON(this.provider, `${BASE_URL[this.provider]}/responses`, { Authorization: `Bearer ${this.apiKey}` }, {
      ...body,
      model: this.model,
      store: false,
    });
  }

  structured<T>(req: StructuredRequest<T>): Promise<StructuredResult<T>> {
    return structuredWithRetry(this.provider, this.model, req.schema, (hint) =>
      // 模型不支持 reasoning 或严格 schema 时，去掉重试（严格 schema 退回 JSON 模式 + 提示词里写 schema）
      retryWithout(["reasoning", "schema"], async (drop): Promise<RawTurn> => {
        const strict = !drop.has("schema");
        const r = await this.call({
          instructions: strict ? req.system : req.system + schemaInstruction(req.schema),
          input: inputOf(req.content, hint),
          max_output_tokens: req.maxTokens,
          text: {
            format: strict
              ? { type: "json_schema", name: req.name, schema: jsonSchemaOf(req.schema), strict: true }
              : { type: "json_object" },
          },
          ...(req.effort && !drop.has("reasoning") ? { reasoning: { effort: req.effort } } : {}),
        });
        const { text, refused } = textOf(r);
        const reason = r.incomplete_details?.reason;
        return {
          text,
          usage: usageOf(r),
          stop: refused || reason === "content_filter" ? "refusal" : r.status === "incomplete" ? "max_tokens" : "ok",
        };
      }),
    );
  }

  async research(req: ResearchRequest): Promise<ResearchResult> {
    const r = await retryWithout(["reasoning", "max_tool_calls"], (drop) =>
      this.call({
        instructions: req.system,
        input: req.prompt,
        tools: [{ type: "web_search" }],
        max_output_tokens: req.maxTokens,
        ...(drop.has("max_tool_calls") ? {} : { max_tool_calls: req.maxSearches + req.urls.length }),
        ...(req.effort && !drop.has("reasoning") ? { reasoning: { effort: req.effort } } : {}),
      }),
    );
    const billed = bill(this.provider, this.model, usageOf(r));
    const { text, refused } = textOf(r);
    if (refused) throw new AIError("模型拒绝写这篇报道", 502, billed);
    if (!text.trim()) throw new AIError(`${PROVIDERS[this.provider].name} 没有写出报道，请重试`, 502, billed);

    const sources = new Map<string, string>();
    for (const item of r.output ?? []) {
      for (const part of item.content ?? []) {
        for (const a of part.annotations ?? []) {
          if (a.type === "url_citation" && a.url) sources.set(a.url, a.title || safeHost(a.url));
        }
      }
    }
    for (const c of r.citations ?? []) {
      const url = typeof c === "string" ? c : (c as { url?: string })?.url;
      if (url && !sources.has(url)) sources.set(url, safeHost(url));
    }
    return { text, sources: [...sources].map(([url, name]) => ({ name, url })), ...billed };
  }
}

function safeHost(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}
