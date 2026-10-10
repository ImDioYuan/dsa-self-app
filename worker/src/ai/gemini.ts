import { jsonSchemaOf, postJSON, retryWithout, schemaInstruction, structuredWithRetry, type RawTurn } from "./common";
import { bill } from "./registry";
import {
  AIError,
  emptyUsage,
  type AIClient,
  type Effort,
  type Part,
  type ResearchRequest,
  type ResearchResult,
  type StructuredRequest,
  type StructuredResult,
  type TokenUsage,
} from "./types";

/** Gemini 原生的 generateContent 接口 */
const BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models";

interface GeminiOutput {
  candidates?: {
    content?: { parts?: { text?: string; thought?: boolean }[] };
    finishReason?: string;
    groundingMetadata?: { groundingChunks?: { web?: { uri?: string; title?: string } }[]; webSearchQueries?: string[] };
    urlContextMetadata?: { urlMetadata?: { retrievedUrl?: string; urlRetrievalStatus?: string }[] };
  }[];
  promptFeedback?: { blockReason?: string };
  usageMetadata?: {
    promptTokenCount?: number;
    cachedContentTokenCount?: number;
    candidatesTokenCount?: number;
    thoughtsTokenCount?: number;
    toolUsePromptTokenCount?: number;
  };
}

/** 被安全策略拦下的结束原因 */
const BLOCKED = new Set(["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"]);

function usageOf(r: GeminiOutput): TokenUsage {
  const u = r.usageMetadata ?? {};
  const cached = u.cachedContentTokenCount ?? 0;
  const searches = r.candidates?.[0]?.groundingMetadata?.webSearchQueries?.length ?? 0;
  return {
    ...emptyUsage(),
    input: Math.max(0, (u.promptTokenCount ?? 0) - cached) + (u.toolUsePromptTokenCount ?? 0),
    cacheRead: cached,
    output: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0),
    searches,
  };
}

function textOf(r: GeminiOutput): string {
  return (r.candidates?.[0]?.content?.parts ?? [])
    .filter((p) => !p.thought)
    .map((p) => p.text ?? "")
    .join("");
}

function stopOf(r: GeminiOutput): RawTurn["stop"] {
  const reason = r.candidates?.[0]?.finishReason ?? "";
  if (r.promptFeedback?.blockReason || BLOCKED.has(reason)) return "refusal";
  return reason === "MAX_TOKENS" ? "max_tokens" : "ok";
}

function partsOf(content: string | Part[], extra: string | null) {
  const parts = typeof content === "string" ? [{ type: "text" as const, text: content }] : content;
  return [
    ...parts.map((p) => (p.type === "text" ? { text: p.text } : { inlineData: { mimeType: p.mediaType, data: p.data } })),
    ...(extra ? [{ text: extra }] : []),
  ];
}

function thinking(effort: Effort | undefined, drop: Set<string>) {
  return effort && !drop.has("thinking") ? { thinkingConfig: { thinkingLevel: effort } } : {};
}

export class GeminiClient implements AIClient {
  readonly provider = "gemini" as const;

  constructor(
    private readonly apiKey: string,
    readonly model: string,
  ) {}

  private call(body: Record<string, unknown>): Promise<GeminiOutput> {
    return postJSON(this.provider, `${BASE_URL}/${encodeURIComponent(this.model)}:generateContent`, { "x-goog-api-key": this.apiKey }, body);
  }

  structured<T>(req: StructuredRequest<T>): Promise<StructuredResult<T>> {
    return structuredWithRetry(this.provider, this.model, req.schema, (hint) =>
      // 不支持的思考档位或 schema 写法：去掉重试（schema 退回到写在提示词里）
      retryWithout(["thinking", "schema"], async (drop): Promise<RawTurn> => {
        const withSchema = !drop.has("schema");
        const r = await this.call({
          systemInstruction: { parts: [{ text: withSchema ? req.system : req.system + schemaInstruction(req.schema) }] },
          contents: [{ role: "user", parts: partsOf(req.content, hint) }],
          generationConfig: {
            responseMimeType: "application/json",
            ...(withSchema ? { responseJsonSchema: jsonSchemaOf(req.schema) } : {}),
            maxOutputTokens: req.maxTokens,
            ...thinking(req.effort, drop),
          },
        });
        return { text: textOf(r), usage: usageOf(r), stop: stopOf(r) };
      }),
    );
  }

  /** Google 搜索 + 读网址 */
  async research(req: ResearchRequest): Promise<ResearchResult> {
    const r = await retryWithout(["thinking"], (drop) =>
      this.call({
        systemInstruction: { parts: [{ text: req.system }] },
        contents: [{ role: "user", parts: [{ text: req.prompt }] }],
        tools: [{ googleSearch: {} }, { urlContext: {} }],
        generationConfig: { maxOutputTokens: req.maxTokens, ...thinking(req.effort, drop) },
      }),
    );
    const billed = bill(this.provider, this.model, usageOf(r));
    const stop = stopOf(r);
    if (stop === "refusal") throw new AIError("模型拒绝写这篇报道", 502, billed);
    if (stop === "max_tokens") throw new AIError("报道太长被截断了，请重试", 502, billed);
    const text = textOf(r);
    if (!text.trim()) throw new AIError("Gemini 没有写出报道，请重试", 502, billed);

    const candidate = r.candidates?.[0];
    const sources = new Map<string, string>();
    for (const m of candidate?.urlContextMetadata?.urlMetadata ?? []) {
      if (m.retrievedUrl && (m.urlRetrievalStatus ?? "").includes("SUCCESS")) sources.set(m.retrievedUrl, hostOf(m.retrievedUrl));
    }
    for (const chunk of candidate?.groundingMetadata?.groundingChunks ?? []) {
      if (chunk.web?.uri) sources.set(chunk.web.uri, chunk.web.title || hostOf(chunk.web.uri));
    }
    return { text, sources: [...sources].map(([url, name]) => ({ name, url })), ...billed };
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}
