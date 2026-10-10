import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { structuredParams, supportsEffort } from "../src/ai/anthropic";
import { jsonSchemaOf, parseOutput, retryWithout, AIHttpError } from "../src/ai/common";
import { GeminiClient } from "../src/ai/gemini";
import { bill, supportsVision } from "../src/ai/registry";
import { ResponsesClient } from "../src/ai/responses";
import { AIError, emptyUsage } from "../src/ai/types";

/**
 * 各家适配代码的测试：请求体拼得对不对、返回值解析和用量换算对不对。
 * 返回值是照各家官方文档的格式写的示例，不真的调用 API
 */

const Schema = z.object({
  kind: z.enum(["a", "b"]).catch("a"),
  due: z.string().nullable(),
  n: z.number().int(),
});

/** 依次返回给定的响应，并记下每次请求 */
function mockFetch(...responses: { status?: number; body: unknown }[]) {
  const calls: { url: string; init: RequestInit; body: any }[] = [];
  const fn = vi.fn(async (url: string, init: RequestInit) => {
    calls.push({ url, init, body: JSON.parse(String(init.body)) });
    const next = responses.shift();
    if (!next) throw new Error("unexpected fetch");
    const status = next.status ?? 200;
    return new Response(typeof next.body === "string" ? next.body : JSON.stringify(next.body), { status });
  });
  vi.stubGlobal("fetch", fn);
  return calls;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("common", () => {
  it("jsonSchemaOf strips $schema, defaults and safe-integer bounds", () => {
    const schema = jsonSchemaOf(Schema) as any;
    expect(schema.$schema).toBeUndefined();
    expect(schema.properties.kind.default).toBeUndefined();
    expect(schema.properties.kind.enum).toEqual(["a", "b"]);
    expect(schema.properties.n).toEqual({ type: "integer" });
    expect(schema.additionalProperties).toBe(false);
    expect(schema.required).toEqual(["kind", "due", "n"]);
  });

  it("parseOutput accepts fenced JSON and reports schema problems", () => {
    expect(parseOutput('```json\n{"kind":"b","due":null,"n":2}\n```', Schema)).toEqual({ ok: true, data: { kind: "b", due: null, n: 2 } });
    expect(parseOutput("", Schema)).toMatchObject({ ok: false, error: "输出是空的" });
    expect(parseOutput("{oops", Schema)).toMatchObject({ ok: false, error: "不是合法的 JSON" });
    const bad = parseOutput('{"kind":"a","due":null,"n":"x"}', Schema);
    expect(bad.ok).toBe(false);
  });

  it("retryWithout drops a parameter named in a 400 error", async () => {
    const seen: string[][] = [];
    const result = await retryWithout(["reasoning", "schema"], async (drop) => {
      seen.push([...drop]);
      if (!drop.has("reasoning")) throw new AIHttpError("bad", 400, "Unsupported parameter: 'reasoning.effort'");
      return "ok";
    });
    expect(result).toBe("ok");
    expect(seen).toEqual([[], ["reasoning"]]);
  });

  it("retryWithout rethrows errors that name no known parameter", async () => {
    await expect(
      retryWithout(["reasoning"], async () => {
        throw new AIHttpError("bad", 400, "something else");
      }),
    ).rejects.toThrow("bad");
  });
});

describe("registry", () => {
  it("bills tokens and searches with the model's price", () => {
    const billed = bill("anthropic", "claude-sonnet-5-5", { ...emptyUsage(), input: 1_000_000, output: 100_000, cacheRead: 1_000_000, searches: 2 });
    // 2 + 1 + 0.2 + 0.02
    expect(billed.costUSD).toBeCloseTo(3.22, 6);
    expect(billed.priced).toBe(true);
  });

  it("applies the batch discount to tokens only", () => {
    const billed = bill("anthropic", "claude-sonnet-5-5", { ...emptyUsage(), output: 1_000_000, searches: 1 }, 0.5);
    expect(billed.costUSD).toBeCloseTo(5.01, 6);
  });

  it("matches dated model ids by prefix and flags unknown models", () => {
    expect(bill("openai", "gpt-6.1-sol-2026-09-01", { ...emptyUsage(), input: 1_000_000 }).costUSD).toBeCloseTo(2, 6);
    const unknown = bill("openai", "some-new-model", { ...emptyUsage(), input: 1_000_000 });
    expect(unknown).toMatchObject({ costUSD: 0, priced: false });
  });

  it("treats unknown search prices as unpriced", () => {
    expect(bill("xai", "grok-4.7", { ...emptyUsage(), searches: 1 }).priced).toBe(false);
  });

  it("knows which models cannot see images", () => {
    expect(supportsVision("deepseek", "deepseek-v4-pro")).toBe(false);
    expect(supportsVision("deepseek", "deepseek-flash")).toBe(true);
    expect(supportsVision("openai", "gpt-6-luna")).toBe(true);
  });
});

describe("anthropic", () => {
  const req = { system: "s", content: "hi", schema: Schema, name: "x", maxTokens: 100, effort: "medium" as const };

  it("sends effort only to models that support it", () => {
    expect(structuredParams("claude-sonnet-5-5", req).output_config).toMatchObject({ effort: "medium" });
    expect(structuredParams("claude-haiku-4-5", req).output_config).not.toHaveProperty("effort");
    expect(supportsEffort("claude-opus-5-5")).toBe(true);
  });
});

describe("Responses API (OpenAI / Grok)", () => {
  const message = (text: string) => ({ type: "message", content: [{ type: "output_text", text, annotations: [] }] });

  it("sends a strict JSON schema, images and effort, and maps usage", async () => {
    const calls = mockFetch({
      body: {
        status: "completed",
        output: [{ type: "reasoning" }, message('{"kind":"b","due":null,"n":3}')],
        usage: { input_tokens: 1000, input_tokens_details: { cached_tokens: 400 }, output_tokens: 50 },
      },
    });
    const client = new ResponsesClient("openai", "key", "gpt-6-luna");
    const result = await client.structured({
      system: "sys",
      content: [
        { type: "image", mediaType: "image/jpeg", data: "AAAA" },
        { type: "text", text: "read this" },
      ],
      schema: Schema,
      name: "thing",
      maxTokens: 500,
      effort: "low",
    });

    expect(calls[0].url).toBe("https://api.openai.com/v1/responses");
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe("Bearer key");
    const body = calls[0].body;
    expect(body).toMatchObject({ model: "gpt-6-luna", instructions: "sys", max_output_tokens: 500, store: false, reasoning: { effort: "low" } });
    expect(body.text.format).toMatchObject({ type: "json_schema", name: "thing", strict: true });
    expect(body.input[0].content[0]).toEqual({ type: "input_image", image_url: "data:image/jpeg;base64,AAAA" });
    expect(result.data).toEqual({ kind: "b", due: null, n: 3 });
    expect(result.usage).toMatchObject({ input: 600, cacheRead: 400, output: 50 });
    // gpt-6-luna：0.1 输入 / 0.01 缓存 / 0.5 输出
    expect(result.costUSD).toBeCloseTo((600 * 0.1 + 400 * 0.01 + 50 * 0.5) / 1_000_000, 10);
  });

  it("uses the xAI endpoint for Grok", async () => {
    const calls = mockFetch({ body: { status: "completed", output: [message('{"kind":"a","due":"x","n":1}')], usage: {} } });
    await new ResponsesClient("xai", "k", "grok-4.3").structured({ system: "s", content: "c", schema: Schema, name: "x", maxTokens: 10 });
    expect(calls[0].url).toBe("https://api.x.ai/v1/responses");
  });

  it("retries without reasoning when the model rejects it", async () => {
    const calls = mockFetch(
      { status: 400, body: { error: { message: "Unsupported parameter: 'reasoning.effort' is not supported with this model." } } },
      { body: { status: "completed", output: [message('{"kind":"a","due":null,"n":1}')], usage: {} } },
    );
    const result = await new ResponsesClient("openai", "k", "gpt-6-luna").structured({
      system: "s",
      content: "c",
      schema: Schema,
      name: "x",
      maxTokens: 10,
      effort: "medium",
    });
    expect(result.data.n).toBe(1);
    expect(calls[1].body.reasoning).toBeUndefined();
  });

  it("reports truncation with the money already spent", async () => {
    mockFetch({
      body: { status: "incomplete", incomplete_details: { reason: "max_output_tokens" }, output: [], usage: { input_tokens: 10, output_tokens: 10 } },
    });
    const err = await new ResponsesClient("openai", "k", "gpt-6-luna")
      .structured({ system: "s", content: "c", schema: Schema, name: "x", maxTokens: 10 })
      .catch((e) => e);
    expect(err).toBeInstanceOf(AIError);
    expect(err.message).toContain("max_tokens");
    expect(err.billed.costUSD).toBeGreaterThan(0);
  });

  it("maps 401 to an invalid-key error", async () => {
    mockFetch({ status: 401, body: { error: { message: "bad key" } } });
    const err = await new ResponsesClient("openai", "k", "gpt-6-luna")
      .structured({ system: "s", content: "c", schema: Schema, name: "x", maxTokens: 10 })
      .catch((e) => e);
    expect(err.message).toContain("OPENAI_API_KEY");
  });

  it("research collects citations and counts searches", async () => {
    const calls = mockFetch({
      body: {
        status: "completed",
        output: [
          { type: "web_search_call" },
          { type: "web_search_call" },
          {
            type: "message",
            content: [
              {
                type: "output_text",
                text: "报道正文",
                annotations: [{ type: "url_citation", url: "https://example.com/a", title: "Example A" }],
              },
            ],
          },
        ],
        usage: { input_tokens: 100, output_tokens: 100 },
      },
    });
    const result = await new ResponsesClient("openai", "k", "gpt-6.1-sol").research({
      system: "s",
      prompt: "p",
      urls: ["https://example.com/a"],
      maxTokens: 1000,
      maxSearches: 3,
    });
    expect(calls[0].body.tools).toEqual([{ type: "web_search" }]);
    expect(result.text).toBe("报道正文");
    expect(result.sources).toEqual([{ name: "Example A", url: "https://example.com/a" }]);
    expect(result.usage.searches).toBe(2);
  });
});

describe("Gemini", () => {
  it("sends responseJsonSchema and thinking level, skips thought parts and maps usage", async () => {
    const calls = mockFetch({
      body: {
        candidates: [
          {
            content: { parts: [{ text: "thinking…", thought: true }, { text: '{"kind":"a","due":null,"n":7}' }] },
            finishReason: "STOP",
          },
        ],
        usageMetadata: { promptTokenCount: 1000, cachedContentTokenCount: 200, candidatesTokenCount: 30, thoughtsTokenCount: 70 },
      },
    });
    const result = await new GeminiClient("gk", "gemini-3.8-flash").structured({
      system: "sys",
      content: [{ type: "image", mediaType: "image/png", data: "BBBB" }],
      schema: Schema,
      name: "x",
      maxTokens: 100,
      effort: "low",
    });
    expect(calls[0].url).toBe("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent");
    expect((calls[0].init.headers as Record<string, string>)["x-goog-api-key"]).toBe("gk");
    const body = calls[0].body;
    expect(body.generationConfig).toMatchObject({ responseMimeType: "application/json", maxOutputTokens: 100, thinkingConfig: { thinkingLevel: "low" } });
    expect(body.generationConfig.responseJsonSchema.type).toBe("object");
    expect(body.contents[0].parts[0]).toEqual({ inlineData: { mimeType: "image/png", data: "BBBB" } });
    expect(result.data.n).toBe(7);
    expect(result.usage).toMatchObject({ input: 800, cacheRead: 200, output: 100 });
  });

  it("treats a safety stop as a refusal", async () => {
    mockFetch({ body: { candidates: [{ content: { parts: [] }, finishReason: "SAFETY" }], usageMetadata: {} } });
    const err = await new GeminiClient("k", "gemini-3.8-flash")
      .structured({ system: "s", content: "c", schema: Schema, name: "x", maxTokens: 10 })
      .catch((e) => e);
    expect(err.message).toContain("拒绝");
  });

  it("research uses Google Search and reads grounding sources", async () => {
    const calls = mockFetch({
      body: {
        candidates: [
          {
            content: { parts: [{ text: "稿子" }] },
            finishReason: "STOP",
            groundingMetadata: {
              webSearchQueries: ["q1"],
              groundingChunks: [{ web: { uri: "https://news.example/1", title: "news.example" } }],
            },
          },
        ],
        usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 10 },
      },
    });
    const result = await new GeminiClient("k", "gemini-3.8-flash").research({ system: "s", prompt: "p", urls: [], maxTokens: 100, maxSearches: 3 });
    expect(calls[0].body.tools).toEqual([{ googleSearch: {} }, { urlContext: {} }]);
    expect(result.sources).toEqual([{ name: "news.example", url: "https://news.example/1" }]);
    expect(result.usage.searches).toBe(1);
  });
});
