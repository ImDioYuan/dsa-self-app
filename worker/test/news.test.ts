import { describe, expect, it } from "vitest";
import { UserConfig } from "../src/config";
import { briefPrompt, briefSchema, localNow, parseFeed, repairReport, toArea, toCategory, toCity, toRegion, unwrapLink, type BriefPlan } from "../src/news";
import { feedsFor, GROUPS, MAX_FEEDS, REGIONS, regionFeeds, TOPICS } from "../src/topics";

describe("config", () => {
  it("fills every field with a default", () => {
    const config = UserConfig.parse({});
    expect(config.name).toBe("");
    expect(config.timezone).toBe("UTC");
    expect(config.news.count).toBe(20);
    expect(config.news.topics.length).toBeGreaterThan(0);
    expect(config.news.interests.length).toBeGreaterThan(0);
    expect(config.ai).toEqual({ tasks: null, brief: null, report: null });
  });

  it("drops bad values instead of failing", () => {
    const config = UserConfig.parse({
      timezone: "Mars/Olympus",
      news: { count: 999, topics: ["ai", "nope", "ai"], briefTime: "25:00", fxPairs: ["aud/cny"] },
      ai: { tasks: { provider: "someone", model: "x" }, brief: { provider: "openai", model: "gpt-6.1-sol" } },
    });
    expect(config.timezone).toBe("UTC");
    expect(config.news.count).toBe(20);
    expect(config.news.topics).toEqual(["ai"]);
    expect(config.news.briefTime).toBe("08:00");
    expect(config.news.fxPairs).toEqual([]);
    expect(config.ai.tasks).toBeNull();
    expect(config.ai.brief).toEqual({ provider: "openai", model: "gpt-6.1-sol" });
  });

  it("drops only the bad items of a list", () => {
    const config = UserConfig.parse({
      watchRules: ["keep me", "", "  "],
      news: {
        fxPairs: ["AUD/CNY", "bad"],
        interests: [{ id: "ok", nameZh: "好", nameEn: "OK", hint: "" }, { id: "Bad Id", nameZh: "坏" }],
        customFeeds: [{ name: "Blog", url: "https://example.com/rss" }, { name: "", url: "https://x.example" }],
      },
    });
    expect(config.watchRules).toEqual(["keep me"]);
    expect(config.news.fxPairs).toEqual(["AUD/CNY"]);
    expect(config.news.interests.map((i) => i.id)).toEqual(["ok"]);
    expect(config.news.customFeeds).toHaveLength(1);
    // 一个都不剩时用默认的几方面
    expect(UserConfig.parse({ news: { interests: [] } }).news.interests.length).toBeGreaterThan(0);
  });

  it("keeps a full config unchanged", () => {
    const input = {
      name: "Alex",
      about: "student",
      timezone: "Europe/London",
      watchRules: ["job emails"],
      news: {
        topics: ["science", "gaming"],
        customFeeds: [{ name: "Blog", url: "https://example.com/feed.xml" }],
        count: 12,
        places: [{ id: "london", nameZh: "伦敦", nameEn: "London", lat: 51.5, lon: -0.12, country: "GB", admin1: "England" }],
        fxPairs: ["GBP/EUR"],
        interests: [{ id: "career", nameZh: "工作", nameEn: "Career", hint: "" }],
        briefTime: "07:30",
      },
      ai: { tasks: null, brief: null, report: { provider: "gemini", model: "" } },
      updatedAt: "",
    };
    expect(UserConfig.parse(input)).toEqual(input);
  });
});

describe("catalog", () => {
  it("migrates old topic ids and drops the old region topics", () => {
    const config = UserConfig.parse({
      news: { topics: ["conflict", "international", "tech_ai", "finance", "education", "australia", "china", "shipping"] },
    });
    expect(config.news.topics).toEqual(["conflict", "diplomacy", "ai", "markets", "economy", "education", "shipping"]);
    // 只剩地区话题时用默认兴趣
    expect(UserConfig.parse({ news: { topics: ["china"] } }).news.topics.length).toBeGreaterThan(0);
  });

  it("ids, groups and related interests are consistent", () => {
    const ids = TOPICS.map((t) => t.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const topic of TOPICS) {
      expect(GROUPS.some((g) => g.id === topic.group)).toBe(true);
      expect(topic.feeds.length).toBeGreaterThan(0);
      for (const related of topic.related) expect(ids).toContain(related);
    }
    // 每个大类都有兴趣，同一个大类的兴趣在目录里挨在一起
    for (const group of GROUPS) expect(TOPICS.some((t) => t.group === group.id)).toBe(true);
    const order = TOPICS.map((t) => t.group).filter((g, i, all) => g !== all[i - 1]);
    expect(order).toEqual(GROUPS.map((g) => g.id));
    const regionIds = REGIONS.map((r) => r.id);
    expect(new Set(regionIds).size).toBe(regionIds.length);
    // 没有自己的源的国家用所在洲的
    expect(regionFeeds("germany").length).toBeGreaterThan(0);
  });

  it("takes more feeds for interests with more stories, plus regions and candidates, up to the cap", () => {
    const feeds = feedsFor({ allocation: { ai: 4, sports: 1, music: 0 }, regions: ["china"], candidates: ["gaming"], custom: [] });
    const tags = feeds.map((f) => f.tag);
    expect(tags.filter((t) => t === "topic/ai")).toHaveLength(4);
    expect(tags.filter((t) => t === "topic/sports")).toHaveLength(1);
    expect(tags).not.toContain("topic/music");
    expect(tags).toContain("region/china");
    expect(tags).toContain("explore/gaming");

    const all = Object.fromEntries(TOPICS.map((t) => [t.id, 3]));
    const many = feedsFor({ allocation: all, regions: ["us"], candidates: ["pets"], custom: [{ name: "x", url: "https://x.example/rss" }] });
    expect(many.length).toBe(MAX_FEEDS);
    expect(new Set(many.map((f) => f.url)).size).toBe(many.length);
    // 地区、猜你喜欢、自定义源不会被兴趣挤掉
    expect(many.some((f) => f.tag === "region/us")).toBe(true);
    expect(many.some((f) => f.tag === "explore/pets")).toBe(true);
    expect(many.some((f) => f.tag === "custom")).toBe(true);
  });

  it("adds a Bing keyword search per liked sub-interest, still under the cap", () => {
    const feeds = feedsFor({
      allocation: { gaming: 3 },
      regions: [],
      candidates: [],
      searches: [{ interest: "gaming", query: "The Legend of Zelda" }],
      custom: [],
    });
    const search = feeds.find((f) => f.url.includes("bing.com"));
    expect(search?.tag).toBe("topic/gaming");
    expect(search?.url).toContain("q=%22The%20Legend%20of%20Zelda%22");
    expect(search?.url).toContain("format=rss");

    const all = Object.fromEntries(TOPICS.map((t) => [t.id, 3]));
    const searches = ["a", "b", "c", "d", "e", "f"].map((q) => ({ interest: "gaming", query: q }));
    const many = feedsFor({ allocation: all, regions: ["us"], candidates: ["pets"], searches, custom: [] });
    expect(many.length).toBe(MAX_FEEDS);
    expect(many.filter((f) => f.url.includes("bing.com"))).toHaveLength(4);
  });
});

describe("normalizers", () => {
  it("maps stray categories onto the allowed ones", () => {
    expect(toCategory("tech", ["ai", "markets"])).toBe("ai");
    expect(toCategory("topic/markets", ["ai", "markets"])).toBe("markets");
    expect(toCategory("finance", ["ai", "markets"])).toBe("markets");
    expect(toCategory("whatever", ["science", "medicine"])).toBe("science");
    expect(toCategory("custom", ["science", "other"])).toBe("other");
  });

  it("maps regions", () => {
    expect(toRegion("China")).toBe("china");
    expect(toRegion("Hong Kong")).toBe("china");
    expect(toRegion("USA")).toBe("us");
    expect(toRegion("region/middle east")).toBe("middle_east");
    expect(toRegion("Atlantis")).toBe("global");
  });

  it("maps impact areas", () => {
    expect(toArea("finance", ["markets", "life"])).toBe("markets");
    expect(toArea("unknown", ["career", "life"])).toBe("life");
    expect(toArea("unknown", ["career"])).toBe("career");
  });

  it("matches cities by id or name", () => {
    const places = [
      { id: "sydney", nameZh: "悉尼", nameEn: "Sydney", lat: 0, lon: 0, country: "AU", admin1: "" },
      { id: "tokyo", nameZh: "东京", nameEn: "Tokyo", lat: 0, lon: 0, country: "CN", admin1: "" },
    ];
    expect(toCity("tokyo", places)).toBe("tokyo");
    expect(toCity("东京都", places)).toBe("tokyo");
    expect(toCity("Sydney, AU", places)).toBe("sydney");
  });

  it("computes the local date and minutes in the user's timezone", () => {
    const at = new Date("2026-10-09T21:30:00Z");
    expect(localNow("Australia/Sydney", at)).toMatchObject({ date: "2026-10-10", minutes: 8 * 60 + 30 });
    expect(localNow("UTC", at)).toMatchObject({ date: "2026-10-09", minutes: 21 * 60 + 30 });
  });
});

describe("feeds and reports", () => {
  it("parses RSS and Atom", () => {
    const rss = `<rss><channel><item><title><![CDATA[Hello &amp; world]]></title><link>https://a.example/1</link><pubDate>Fri, 09 Oct 2026 10:00:00 GMT</pubDate><description>&lt;p&gt;Body&lt;/p&gt;</description></item></channel></rss>`;
    expect(parseFeed(rss)[0]).toMatchObject({ title: "Hello & world", link: "https://a.example/1", summary: "Body" });
    const atom = `<feed><entry><title>Atom</title><link rel="alternate" href="https://b.example/2"/><updated>2026-10-09T10:00:00Z</updated></entry></feed>`;
    expect(parseFeed(atom)[0]).toMatchObject({ title: "Atom", link: "https://b.example/2" });
  });

  it("unwraps Bing redirect links to the original article", () => {
    const bing = "http://www.bing.com/news/apiclick.aspx?ref=FexRss&amp;aid=&amp;url=https%3a%2f%2fwww.example.com%2fgaming%2fzelda&amp;c=1&amp;mkt=en-au";
    const rss = `<rss><channel><item><title>Zelda</title><link>${bing}</link></item></channel></rss>`;
    expect(parseFeed(rss)[0].link).toBe("https://www.example.com/gaming/zelda");
    expect(unwrapLink("https://a.example/1")).toBe("https://a.example/1");
    expect(unwrapLink("http://www.bing.com/news/apiclick.aspx?url=javascript%3aalert(1)")).toBe("http://www.bing.com/news/apiclick.aspx?url=javascript%3aalert(1)");
  });

  it("asks for sub-interest tags and tolerates their absence", () => {
    const config = UserConfig.parse({ news: { topics: ["gaming"], count: 10 } });
    const zelda = { zh: "塞尔达传说", en: "The Legend of Zelda" };
    const plan: BriefPlan = {
      allocation: { gaming: 8 },
      regions: [],
      candidates: [],
      levels: { gaming: 72 },
      tags: { gaming: { liked: [zelda], known: [zelda, { zh: "Nintendo", en: "Nintendo" }] } },
    };
    const prompt = briefPrompt(config, plan, ["gaming"], false);
    expect(prompt).toContain("（喜欢程度 72/100）。最近爱看：塞尔达传说（The Legend of Zelda）——名额里可以比平时多放一条");
    expect(prompt).toContain("  - 电子游戏：塞尔达传说（The Legend of Zelda）、Nintendo");
    // 旧版排队的安排：没有分数和小类
    const old = briefPrompt(config, { allocation: { gaming: 8 }, regions: [], candidates: [] }, ["gaming"], false);
    expect(old).not.toContain("喜欢程度");
    expect(old).not.toContain("已有的标签");

    // 部署前排队的批处理输出没有 tags
    const item = {
      category: "gaming",
      region: "global",
      explore: false,
      reasonZh: "",
      reasonEn: "",
      importance: 3,
      titleZh: "t",
      titleEn: "t",
      summaryZh: "s",
      summaryEn: "s",
      headlineIds: ["n1"],
      affectsMe: false,
    };
    const parsed = briefSchema(["gaming"], config, plan).parse({ items: [item], impact: { overviewZh: "", overviewEn: "", points: [] }, weather: [] });
    expect(parsed.items[0].tags).toEqual([]);
  });

  it("repairs leaked impactEn and literal newlines", () => {
    const fixed = repairReport({
      titleZh: "t",
      titleEn: "t",
      sections: [{ headingZh: "h", headingEn: "h", bodyZh: "a\\n\\nb", bodyEn: "c" }],
      impactZh: '对你的影响","impactEn":"Impact on you"}',
      impactEn: "placeholder",
      sources: [],
    });
    expect(fixed.sections[0].bodyZh).toBe("a\n\nb");
    expect(fixed.impactZh).toBe("对你的影响");
    expect(fixed.impactEn).toBe("Impact on you");
  });
});
