import { AnthropicClient } from "./anthropic";
import { ChatClient } from "./chat";
import { GeminiClient } from "./gemini";
import { configuredProviders, PROVIDERS } from "./registry";
import { ResponsesClient } from "./responses";
import { AIError, type AIClient, type AIEnv, type AITask, type ProviderId } from "./types";

export * from "./types";
export { bill, configuredProviders, PROVIDERS, supportsVision } from "./registry";

export interface ModelChoice {
  provider: ProviderId;
  model: string;
}

/** 设置里选的服务商和模型；没选就用第一家配了 key 的服务商的默认模型 */
export function resolveChoice(env: AIEnv, choice: ModelChoice | null | undefined, task: AITask): ModelChoice {
  if (choice) {
    const { keyName, defaults, name } = PROVIDERS[choice.provider];
    if (!env[keyName]?.trim()) {
      throw new AIError(`${name} 还没有设置 API key：在 worker 目录运行 npx wrangler secret put ${keyName}，或者在 App 的 AI 服务里换一家`, 500);
    }
    return { provider: choice.provider, model: choice.model.trim() || defaults[task] };
  }
  const first = configuredProviders(env)[0];
  if (!first) throw new AIError("还没有设置任何 AI 服务的 API key（例如 npx wrangler secret put ANTHROPIC_API_KEY）", 500);
  return { provider: first, model: PROVIDERS[first].defaults[task] };
}

export function createClient(env: AIEnv, choice: ModelChoice): AIClient {
  const key = env[PROVIDERS[choice.provider].keyName]?.trim() ?? "";
  switch (choice.provider) {
    case "anthropic":
      return new AnthropicClient(key, choice.model);
    case "openai":
    case "xai":
      return new ResponsesClient(choice.provider, key, choice.model);
    case "gemini":
      return new GeminiClient(key, choice.model);
    case "deepseek":
      return new ChatClient(key, choice.model);
  }
}
