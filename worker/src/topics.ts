/**
 * 新闻话题目录：每个话题对应几个 RSS 源。用户在 App 里勾选话题，简报的分类就是这些话题。
 * 加新话题：往 TOPICS 里加一项（id 用小写英文，App 认识的 id 有专门的图标和颜色，不认识的用通用图标）
 */

export interface Feed {
  name: string;
  url: string;
}

export interface Topic {
  id: string;
  nameZh: string;
  nameEn: string;
  /** 写进提示词，告诉模型这个话题包括什么 */
  hint: string;
  feeds: Feed[];
}

const BBC_WORLD = { name: "BBC News", url: "https://feeds.bbci.co.uk/news/world/rss.xml" };
const AL_JAZEERA = { name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml" };
const GUARDIAN_WORLD = { name: "The Guardian", url: "https://www.theguardian.com/world/rss" };

export const TOPICS: Topic[] = [
  {
    id: "conflict",
    nameZh: "战争冲突",
    nameEn: "Conflict",
    hint: "全球战争和冲突、地缘政治危机",
    feeds: [BBC_WORLD, AL_JAZEERA, GUARDIAN_WORLD],
  },
  {
    id: "international",
    nameZh: "国际",
    nameEn: "World",
    hint: "国际大事",
    feeds: [BBC_WORLD, AL_JAZEERA, GUARDIAN_WORLD, { name: "New York Times", url: "https://rss.nytimes.com/services/xml/rss/nyt/World.xml" }],
  },
  {
    id: "tech_ai",
    nameZh: "科技 AI",
    nameEn: "Tech & AI",
    hint: "科技和 AI（新模型、新产品、行业动态）",
    feeds: [
      { name: "The Verge", url: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml" },
      { name: "TechCrunch", url: "https://techcrunch.com/category/artificial-intelligence/feed/" },
      { name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index" },
      { name: "OpenAI", url: "https://openai.com/news/rss.xml" },
      { name: "Google AI", url: "https://blog.google/technology/ai/rss/" },
      { name: "Hacker News", url: "https://hnrss.org/frontpage?points=300" },
    ],
  },
  {
    id: "finance",
    nameZh: "财经",
    nameEn: "Finance",
    hint: "财经、市场、央行和宏观政策",
    feeds: [
      { name: "CNBC", url: "https://www.cnbc.com/id/100003114/device/rss/rss.html" },
      { name: "Financial Times", url: "https://www.ft.com/rss/home" },
      { name: "MarketWatch", url: "https://feeds.content.dowjones.io/public/rss/mw_topstories" },
    ],
  },
  {
    id: "education",
    nameZh: "教育",
    nameEn: "Education",
    hint: "教育、高校和留学政策",
    feeds: [
      { name: "Guardian Education", url: "https://www.theguardian.com/education/rss" },
      { name: "The Conversation", url: "https://theconversation.com/au/education/articles.atom" },
    ],
  },
  {
    id: "australia",
    nameZh: "澳洲",
    nameEn: "Australia",
    hint: "澳洲本地新闻",
    feeds: [
      { name: "ABC News", url: "https://www.abc.net.au/news/feed/51120/rss.xml" },
      { name: "Sydney Morning Herald", url: "https://www.smh.com.au/rss/national/nsw.xml" },
      { name: "Guardian Australia", url: "https://www.theguardian.com/australia-news/rss" },
      { name: "ABC Business", url: "https://www.abc.net.au/news/feed/51892/rss.xml" },
    ],
  },
  {
    id: "china",
    nameZh: "中国",
    nameEn: "China",
    hint: "中国新闻",
    feeds: [
      { name: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml" },
      { name: "DW 中文", url: "https://rss.dw.com/rdf/rss-chi-all" },
      { name: "SCMP", url: "https://www.scmp.com/rss/4/feed" },
      { name: "CGTN", url: "https://www.cgtn.com/subscribe/rss/section/china.xml" },
    ],
  },
  {
    id: "us",
    nameZh: "美国",
    nameEn: "United States",
    hint: "美国新闻",
    feeds: [
      { name: "NPR", url: "https://feeds.npr.org/1001/rss.xml" },
      { name: "New York Times US", url: "https://rss.nytimes.com/services/xml/rss/nyt/US.xml" },
      { name: "BBC US & Canada", url: "https://feeds.bbci.co.uk/news/world/us_and_canada/rss.xml" },
    ],
  },
  {
    id: "europe",
    nameZh: "欧洲",
    nameEn: "Europe",
    hint: "欧洲新闻",
    feeds: [
      { name: "BBC Europe", url: "https://feeds.bbci.co.uk/news/world/europe/rss.xml" },
      { name: "Guardian Europe", url: "https://www.theguardian.com/world/europe-news/rss" },
      { name: "DW Europe", url: "https://rss.dw.com/rdf/rss-en-eu" },
    ],
  },
  {
    id: "asia",
    nameZh: "亚太",
    nameEn: "Asia-Pacific",
    hint: "亚太地区新闻",
    feeds: [
      { name: "BBC Asia", url: "https://feeds.bbci.co.uk/news/world/asia/rss.xml" },
      { name: "Guardian Asia-Pacific", url: "https://www.theguardian.com/world/asia-pacific/rss" },
    ],
  },
  {
    id: "shipping",
    nameZh: "航运贸易",
    nameEn: "Shipping & Trade",
    hint: "航运、港口、供应链和国际贸易",
    feeds: [
      { name: "gCaptain", url: "https://gcaptain.com/feed/" },
      { name: "Splash247", url: "https://splash247.com/feed/" },
      { name: "The Loadstar", url: "https://theloadstar.com/feed/" },
    ],
  },
  {
    id: "science",
    nameZh: "科学",
    nameEn: "Science",
    hint: "科学发现、太空、气候和环境",
    feeds: [
      { name: "BBC Science", url: "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml" },
      { name: "Nature", url: "https://www.nature.com/nature.rss" },
      { name: "ScienceDaily", url: "https://www.sciencedaily.com/rss/top/science.xml" },
    ],
  },
  {
    id: "health",
    nameZh: "健康",
    nameEn: "Health",
    hint: "健康、医学和公共卫生",
    feeds: [
      { name: "BBC Health", url: "https://feeds.bbci.co.uk/news/health/rss.xml" },
      { name: "Guardian Health", url: "https://www.theguardian.com/society/health/rss" },
    ],
  },
  {
    id: "sports",
    nameZh: "体育",
    nameEn: "Sports",
    hint: "重要的体育赛事",
    feeds: [{ name: "BBC Sport", url: "https://feeds.bbci.co.uk/sport/rss.xml" }],
  },
  {
    id: "culture",
    nameZh: "文化娱乐",
    nameEn: "Culture",
    hint: "文化、艺术和娱乐",
    feeds: [{ name: "BBC Entertainment", url: "https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml" }],
  },
];

/** 新用户默认的话题 */
export const DEFAULT_TOPICS = ["international", "tech_ai", "finance", "science"];

/** 一次最多抓这么多个源（免费版 Worker 每次只有 10ms CPU，解析 RSS 要省着用） */
export const MAX_FEEDS = 40;

/** 选中话题的源（去重）。每个源带上它第一个所属的话题，作为给模型的提示 */
export function feedsFor(topicIds: string[], custom: Feed[]): (Feed & { topic: string })[] {
  const seen = new Set<string>();
  const feeds: (Feed & { topic: string })[] = [];
  const add = (feed: Feed, topic: string) => {
    if (seen.has(feed.url) || feeds.length >= MAX_FEEDS) return;
    seen.add(feed.url);
    feeds.push({ ...feed, topic });
  };
  for (const id of topicIds) {
    const topic = TOPICS.find((t) => t.id === id);
    topic?.feeds.forEach((f) => add(f, topic.id));
  }
  custom.forEach((f) => add(f, "custom"));
  return feeds;
}

/** 澳洲气象局各州的天气警告（用地名搜索给的 admin1 匹配） */
export const BOM_WARNINGS: Record<string, string> = {
  "New South Wales": "https://www.bom.gov.au/fwo/IDZ00054.warnings_nsw.xml",
  "Australian Capital Territory": "https://www.bom.gov.au/fwo/IDZ00054.warnings_nsw.xml",
  "Northern Territory": "https://www.bom.gov.au/fwo/IDZ00055.warnings_nt.xml",
  Queensland: "https://www.bom.gov.au/fwo/IDZ00056.warnings_qld.xml",
  "South Australia": "https://www.bom.gov.au/fwo/IDZ00057.warnings_sa.xml",
  Tasmania: "https://www.bom.gov.au/fwo/IDZ00058.warnings_tas.xml",
  Victoria: "https://www.bom.gov.au/fwo/IDZ00059.warnings_vic.xml",
  "Western Australia": "https://www.bom.gov.au/fwo/IDZ00060.warnings_wa.xml",
};
