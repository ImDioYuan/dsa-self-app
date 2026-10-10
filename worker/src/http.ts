import Anthropic from "@anthropic-ai/sdk";
import { AIError } from "./ai/types";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

/** 错误转成给 app 看的响应 */
export function aiErrorResponse(err: unknown): Response {
  if (err instanceof AIError) return json({ error: err.message }, err.status);
  if (err instanceof Anthropic.RateLimitError) {
    return json({ error: "Claude 请求太频繁，请稍后再试" }, 429);
  }
  if (err instanceof Anthropic.AuthenticationError) {
    return json({ error: "ANTHROPIC_API_KEY 无效" }, 500);
  }
  if (err instanceof Anthropic.APIError) {
    return json({ error: `Claude API 错误 ${err.status}：${err.message}` }, 502);
  }
  console.error(err);
  return json({ error: err instanceof Error ? err.message : String(err) }, 500);
}
