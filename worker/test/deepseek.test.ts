import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";

// 读网页用到 Workers 才有的 HTMLRewriter，测试里换成假的
vi.mock("../src/ai/fetchPage", () => ({
  fetchPageText: vi.fn(async (url: string) => ({ ok: true, title: `Title of ${url}`, text: "正文" })),
}));

const { ChatClient } = await import("../src/ai/chat");

const Schema = z.object({ n: z.number().int() });

function mockFetch(...responses: unknown[]) {
  const calls: any[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_url: string, init: RequestInit) => {
      calls.push(JSON.parse(String(init.body)));
      return new Response(JSON.stringify(responses.shift()));
    }),
  );
  return calls;
}

afterEach(() => vi.unstubAllGlobals());

describe("DeepSeek (Chat Completions)", () => {
  it("uses JSON mode with the schema in the prompt and retries once on bad output", async () => {
    const calls = mockFetch(
      {
        choices: [{ message: { role: "assistant", content: "not json" }, finish_reason: "stop" }],
        usage: { prompt_cache_hit_tokens: 100, prompt_cache_miss_tokens: 900, completion_tokens: 10 },
      },
      {
        choices: [{ message: { role: "assistant", content: '{"n": 5}' }, finish_reason: "stop" }],
        usage: { prompt_cache_hit_tokens: 900, prompt_cache_miss_tokens: 100, completion_tokens: 10 },
      },
    );
    const result = await new ChatClient("k", "deepseek-flash").structured({
      system: "sys",
      content: "c",
      schema: Schema,
      name: "x",
      maxTokens: 100,
    });
    expect(calls[0].response_format).toEqual({ type: "json_object" });
    expect(calls[0].messages[0].content).toContain("JSON Schema");
    expect(calls[1].messages[1].content).toContain("上一次的输出不符合要求");
    expect(result.data).toEqual({ n: 5 });
    // 两次的用量都算进去
    expect(result.usage).toMatchObject({ input: 1000, cacheRead: 1000, output: 20 });
  });

  it("research reads pages through the fetch_url tool", async () => {
    const calls = mockFetch(
      {
        choices: [
          {
            message: {
              role: "assistant",
              content: "",
              tool_calls: [{ id: "c1", type: "function", function: { name: "fetch_url", arguments: '{"url":"https://example.com/story"}' } }],
            },
            finish_reason: "tool_calls",
          },
        ],
        usage: { prompt_cache_miss_tokens: 100, completion_tokens: 10 },
      },
      {
        choices: [{ message: { role: "assistant", content: "写好的稿子" }, finish_reason: "stop" }],
        usage: { prompt_cache_miss_tokens: 200, completion_tokens: 300 },
      },
    );
    const result = await new ChatClient("k", "deepseek-v4-pro").research({
      system: "s",
      prompt: "p",
      urls: ["https://example.com/story"],
      maxTokens: 1000,
      maxSearches: 3,
    });
    expect(calls[0].tools[0].function.name).toBe("fetch_url");
    expect(calls[1].messages.at(-1)).toMatchObject({ role: "tool", tool_call_id: "c1" });
    expect(result.text).toBe("写好的稿子");
    expect(result.sources).toEqual([{ name: "Title of https://example.com/story", url: "https://example.com/story" }]);
    expect(result.usage.fetches).toBe(1);
  });
});
