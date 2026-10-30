import { afterEach, describe, expect, it, vi } from "vitest";
import { handleConfig, type ConfigEnv } from "../src/config";

/** 只实现用到的 get / put */
function memoryKV(): KVNamespace {
  const store = new Map<string, string>();
  return {
    async get(key: string, type?: string) {
      const value = store.get(key);
      if (value === undefined) return null;
      return type === "json" ? JSON.parse(value) : value;
    },
    async put(key: string, value: string) {
      store.set(key, value);
    },
  } as unknown as KVNamespace;
}

describe("PUT /config", () => {
  afterEach(() => vi.useRealTimers());

  const put = (env: ConfigEnv, body: object, base?: string) =>
    handleConfig(
      new Request("https://worker.test/config", {
        method: "PUT",
        body: JSON.stringify(body),
        headers: base ? { "If-Match": base } : {},
      }),
      env,
    );

  it("refuses a save based on a version another device has replaced", async () => {
    vi.useFakeTimers();
    const env = { NEWS: memoryKV() } as unknown as ConfigEnv;

    vi.setSystemTime(new Date("2026-10-30T01:00:00Z"));
    const loaded = ((await (await put(env, { name: "Dio" })).json()) as { config: { updatedAt: string } }).config;
    expect(loaded.updatedAt).toBe("2026-10-30T01:00:00.000Z");

    // iPad 在读到的版本上改了，存得进去
    vi.setSystemTime(new Date("2026-10-30T01:05:00Z"));
    expect((await put(env, { ...loaded, about: "iPad 上改的" }, loaded.updatedAt)).status).toBe(200);

    // iPhone 还拿着旧版本：不能直接覆盖
    vi.setSystemTime(new Date("2026-10-30T01:10:00Z"));
    const stale = await put(env, { ...loaded, name: "iPhone 上改的" }, loaded.updatedAt);
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({ error: "conflict" });

    // 版本比存着的还新（KV 刚写完还读到旧的）不算冲突；旧版 App 不带 If-Match，照旧直接存
    expect((await put(env, { name: "新的" }, "2026-10-30T02:00:00.000Z")).status).toBe(200);
    expect((await put(env, { name: "旧版 App" })).status).toBe(200);
  });
});
