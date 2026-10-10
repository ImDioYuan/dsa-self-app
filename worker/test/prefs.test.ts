import { describe, expect, it } from "vitest";
import { UserConfig } from "../src/config";
import { planBrief, totalOf } from "../src/news";
import {
  allocate,
  applyEvent,
  DEFAULT_LEVEL,
  describePrefs,
  emptyPrefs,
  engagement,
  exploreCandidates,
  MAX_DOWN,
  MAX_UP,
  previousDate,
  scoreDay,
  suggestions,
  topRegions,
  type DayFeedback,
  type ShownItem,
} from "../src/prefs";

/** 一天的简报：每个兴趣 n 条 */
function day(counts: Record<string, number>, region = "us"): ShownItem[] {
  let id = 0;
  return Object.entries(counts).flatMap(([category, n]) =>
    Array.from({ length: n }, () => ({ id: String(++id), category, region })),
  );
}

/** 读了哪些新闻：每个兴趣的前 k 条点开并看满 30 秒 */
function read(items: ShownItem[], perTopic: Record<string, number>): DayFeedback {
  const seen: Record<string, number> = {};
  const feedback: DayFeedback = {};
  for (const item of items) {
    seen[item.category] = (seen[item.category] ?? 0) + 1;
    if (seen[item.category] <= (perTopic[item.category] ?? 0)) feedback[item.id] = { open: 1, seconds: 45 };
  }
  return feedback;
}

describe("engagement", () => {
  it("weights each signal", () => {
    expect(engagement(undefined)).toBe(0);
    expect(engagement({ open: 1 })).toBe(1);
    expect(engagement({ open: 1, seconds: 40, link: 1 })).toBe(3);
    expect(engagement({ open: 1, report: true, vote: 1 })).toBe(6);
    expect(engagement({ open: 1, vote: -1 })).toBe(-2);
  });

  it("merges events", () => {
    let f = applyEvent(undefined, { event: "open" });
    f = applyEvent(f, { event: "read", seconds: 20 });
    f = applyEvent(f, { event: "read", seconds: 15 });
    f = applyEvent(f, { event: "vote", vote: 1 });
    f = applyEvent(f, { event: "report" });
    expect(f).toEqual({ open: 1, seconds: 35, vote: 1, report: true });
  });
});

describe("scoring", () => {
  const topics = ["ai", "sports", "music"];

  it("does nothing on days without any feedback", () => {
    const prefs = emptyPrefs();
    expect(scoreDay(prefs, topics, day({ ai: 3, sports: 3, music: 3 }), {})).toBe(prefs);
  });

  it("moves at most MAX_UP / MAX_DOWN per day and fades ignored interests to 0", () => {
    let prefs = emptyPrefs();
    prefs.levels = { ai: 50, sports: 50, music: 50 };
    const history: Record<string, number>[] = [];
    for (let d = 0; d < 8; d++) {
      const counts = allocate(topics.map((id) => ({ id, level: prefs.levels[id] ?? DEFAULT_LEVEL })), 20);
      const items = day(counts);
      // 只看 AI，体育看一半，音乐从来不看
      prefs = scoreDay(prefs, topics, items, read(items, { ai: 99, sports: Math.ceil((counts.sports ?? 0) / 2), music: 0 }));
      history.push({ ...prefs.levels, musicCount: counts.music });
    }
    // 每天的变化不超过斜率
    let last = { ai: 50, sports: 50, music: 50 } as Record<string, number>;
    for (const h of history) {
      for (const id of topics) {
        expect(h[id] - last[id]).toBeLessThanOrEqual(MAX_UP);
        expect(last[id] - h[id]).toBeLessThanOrEqual(MAX_DOWN);
      }
      last = h;
    }
    expect(history.at(-1)!.ai).toBe(100);
    expect(history.at(-1)!.music).toBe(0);
    // 音乐是一天天降下去的：40, 30, 20, 10, 0
    expect(history.slice(0, 5).map((h) => h.music)).toEqual([40, 30, 20, 10, 0]);
    expect(history.at(-1)!.sports).toBeGreaterThan(0);
    expect(history.at(-1)!.sports).toBeLessThan(100);
  });

  it("leaves faded interests at 0 and keeps manual levels as the new starting point", () => {
    const prefs = emptyPrefs();
    prefs.levels = { ai: 80, sports: 0, music: 30 };
    const items = day({ ai: 5, music: 2 });
    const next = scoreDay(prefs, topics, items, read(items, { ai: 5, music: 2 }));
    expect(next.levels.sports).toBe(0);
    // 用户把音乐拖到 30，看得多就从 30 往上升
    expect(next.levels.music).toBe(30 + MAX_UP);
    expect(next.previous).toEqual({ ai: 80, sports: 0, music: 30 });
  });

  it("a thumbs down pushes an interest down", () => {
    const prefs = emptyPrefs();
    const items = day({ ai: 2, sports: 2 });
    const next = scoreDay(prefs, topics, items, { "1": { open: 1, seconds: 60 }, "3": { open: 1, vote: -1 } });
    expect(next.levels.ai).toBe(DEFAULT_LEVEL + MAX_UP);
    expect(next.levels.sports).toBe(DEFAULT_LEVEL - MAX_DOWN);
  });

  it("learns regions and discoveries from what was read", () => {
    let prefs = emptyPrefs(["australia"]);
    const items: ShownItem[] = [
      { id: "1", category: "ai", region: "china" },
      { id: "2", category: "ai", region: "us" },
      { id: "3", category: "gaming", region: "japan", explore: true },
    ];
    for (let d = 0; d < 3; d++) {
      prefs = scoreDay(prefs, ["ai"], items, { "1": { open: 1, seconds: 60 }, "3": { open: 1, vote: 1 } });
    }
    expect(topRegions(prefs)[0]).toBe("china");
    expect(topRegions(prefs)).toContain("australia");
    expect(prefs.regions.us).toBeUndefined();
    expect(suggestions(prefs, ["ai"], "2026-10-12")).toEqual(["gaming"]);
    // 不感兴趣的不再建议，也不再当候选
    prefs.dismissed.gaming = "2026-10-12";
    expect(suggestions(prefs, ["ai"], "2026-10-13")).toEqual([]);
    expect(exploreCandidates(prefs, ["ai"], "2026-10-13")).not.toContain("gaming");
  });
});

describe("allocation", () => {
  it("splits evenly on the first day and always adds up", () => {
    const counts = allocate(["ai", "sports", "music", "science"].map((id) => ({ id, level: DEFAULT_LEVEL })), 20);
    expect(Object.values(counts)).toEqual([5, 5, 4, 4]);
    for (const total of [5, 12, 20, 30]) {
      const c = allocate([{ id: "a", level: 100 }, { id: "b", level: 37 }, { id: "c", level: 12 }], total);
      expect(Object.values(c).reduce((x, y) => x + y, 0)).toBe(total - 2);
      expect(c.c).toBeGreaterThanOrEqual(1);
    }
  });

  it("gives nothing to faded interests, and splits evenly when everything faded", () => {
    expect(allocate([{ id: "a", level: 90 }, { id: "b", level: 5 }], 12)).toEqual({ a: 10, b: 0 });
    expect(allocate([{ id: "a", level: 0 }, { id: "b", level: 0 }], 12)).toEqual({ a: 5, b: 5 });
  });
});

describe("plan and candidates", () => {
  const config = UserConfig.parse({ news: { topics: ["ai", "conflict"], count: 20 } });

  it("plans the brief from the scores", () => {
    const prefs = emptyPrefs(["china"]);
    prefs.levels = { ai: 100, conflict: 50 };
    const plan = planBrief(config, prefs, "2026-10-12");
    expect(totalOf(plan)).toBe(20);
    expect(plan.allocation.ai).toBeGreaterThan(plan.allocation.conflict);
    expect(plan.regions).toEqual(["china"]);
    expect(plan.candidates).toHaveLength(3);
    expect(plan.candidates).not.toContain("ai");
  });

  it("candidates favour related interests and rotate by day", () => {
    const prefs = emptyPrefs();
    prefs.levels = { ai: 100, conflict: 10 };
    const days = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"].map((d) => exploreCandidates(prefs, ["ai", "conflict"], d));
    // 和 AI 最相关的总在第一个
    for (const picks of days) expect(["big_tech", "programming", "startups"]).toContain(picks[0]);
    expect(new Set(days.map((p) => p.join())).size).toBeGreaterThan(1);
  });

  it("describes prefs for the app", () => {
    const prefs = emptyPrefs(["australia", "china"]);
    prefs.levels = { ai: 70 };
    prefs.previous = { ai: 60 };
    const view = describePrefs(prefs, config, "2026-10-12");
    expect(view.interests[0]).toMatchObject({ id: "ai", level: 70, previous: 60 });
    expect(view.interests.reduce((a, i) => a + i.count, 0)).toBe(18);
    expect(view.regions.map((r) => r.id).sort()).toEqual(["australia", "china"]);
    expect(view.regions[0].nameZh).toBeTruthy();
  });

  it("previousDate", () => {
    expect(previousDate("2026-03-01")).toBe("2026-02-28");
    expect(previousDate("2026-10-12", 3)).toBe("2026-10-09");
  });
});

describe("allocation parity with the app", () => {
  // 和 DSATests/NewsTests.swift 的 allocationMatchesWorker 用同样的输入
  it("matches the Swift version", () => {
    expect(allocate([{ id: "a", level: 100 }, { id: "b", level: 37 }, { id: "c", level: 12 }], 20)).toEqual({ a: 12, b: 5, c: 1 });
  });
});
