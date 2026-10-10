import { describe, expect, it } from "vitest";
import { UserConfig } from "../src/config";
import { localNow, parseFeed, repairReport, toArea, toCategory, toCity } from "../src/news";
import { feedsFor, MAX_FEEDS, TOPICS } from "../src/topics";

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
      news: { count: 999, topics: ["tech_ai", "nope", "tech_ai"], briefTime: "25:00", fxPairs: ["aud/cny"] },
      ai: { tasks: { provider: "someone", model: "x" }, brief: { provider: "openai", model: "gpt-6.1-sol" } },
    });
    expect(config.timezone).toBe("UTC");
    expect(config.news.count).toBe(20);
    expect(config.news.topics).toEqual(["tech_ai"]);
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
        topics: ["science", "europe"],
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

describe("topics", () => {
  it("dedupes feeds shared by several topics and caps the total", () => {
    const feeds = feedsFor(["conflict", "international"], []);
    const urls = feeds.map((f) => f.url);
    expect(new Set(urls).size).toBe(urls.length);
    expect(feeds.find((f) => f.name === "BBC News")?.topic).toBe("conflict");
    expect(feedsFor(TOPICS.map((t) => t.id), [{ name: "x", url: "https://x.example/rss" }]).length).toBeLessThanOrEqual(MAX_FEEDS);
  });

  it("topic ids are unique", () => {
    const ids = TOPICS.map((t) => t.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe("normalizers", () => {
  it("maps stray categories onto the allowed ones", () => {
    expect(toCategory("tech", ["tech_ai", "finance"])).toBe("tech_ai");
    expect(toCategory("world", ["international"])).toBe("international");
    expect(toCategory("whatever", ["science", "health"])).toBe("science");
    expect(toCategory("custom", ["science", "other"])).toBe("other");
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
