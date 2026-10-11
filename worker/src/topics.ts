/**
 * 新闻目录：
 * - 兴趣（TOPICS）：用户在 App 的「我的兴趣」里选，每个兴趣对应几个 RSS 源。简报的分类就是兴趣 id
 * - 地区（REGIONS）：不给用户选。AI 给每条新闻标上地区，从用户爱看的新闻里统计出「常看的地区」，
 *   生成简报时自动加上这些地区的源
 * 加新兴趣：往 TOPICS 里加一项（id 用小写英文，App 认识的 id 有专门的图标和颜色，不认识的用通用图标）。
 * 加源之前先确认能抓到（curl 一下，看有没有最近的条目）
 */

export interface Feed {
  name: string;
  url: string;
}

export interface Topic {
  id: string;
  nameZh: string;
  nameEn: string;
  /** 大类，只用来在 App 里分组显示 */
  group: string;
  /** 写进提示词，告诉模型这个兴趣包括什么 */
  hint: string;
  feeds: Feed[];
  /** 相关的兴趣：「猜你喜欢」从这里找候选 */
  related: string[];
}

export const GROUPS = [
  { id: "current", nameZh: "时事", nameEn: "Current affairs" },
  { id: "economy", nameZh: "财经", nameEn: "Business & finance" },
  { id: "tech", nameZh: "科技", nameEn: "Tech" },
  { id: "science_health", nameZh: "科学健康", nameEn: "Science & health" },
  { id: "education", nameZh: "教育职场", nameEn: "Education & careers" },
  { id: "sports_games", nameZh: "体育游戏", nameEn: "Sports & games" },
  { id: "culture", nameZh: "文化娱乐", nameEn: "Culture & entertainment" },
  { id: "life", nameZh: "生活", nameEn: "Life" },
] as const;

const guardian = (name: string, path: string): Feed => ({ name: `Guardian ${name}`, url: `https://www.theguardian.com/${path}/rss` });

const BBC_WORLD = { name: "BBC News", url: "https://feeds.bbci.co.uk/news/world/rss.xml" };
const AL_JAZEERA = { name: "Al Jazeera", url: "https://www.aljazeera.com/xml/rss/all.xml" };
const NYT_WORLD = { name: "New York Times", url: "https://rss.nytimes.com/services/xml/rss/nyt/World.xml" };
const NPR = { name: "NPR", url: "https://feeds.npr.org/1001/rss.xml" };
const NYT_US = { name: "New York Times US", url: "https://rss.nytimes.com/services/xml/rss/nyt/US.xml" };
const BBC_US = { name: "BBC US & Canada", url: "https://feeds.bbci.co.uk/news/world/us_and_canada/rss.xml" };
const ABC_AU = { name: "ABC News", url: "https://www.abc.net.au/news/feed/51120/rss.xml" };
const SMH = { name: "Sydney Morning Herald", url: "https://www.smh.com.au/rss/national/nsw.xml" };
const RNZ = { name: "RNZ", url: "https://www.rnz.co.nz/rss/national.xml" };

export const TOPICS: Topic[] = [
  // MARK: 时事
  {
    id: "conflict",
    nameZh: "战争冲突",
    nameEn: "Conflict",
    group: "current",
    hint: "战争、武装冲突和地缘政治危机",
    feeds: [BBC_WORLD, AL_JAZEERA, guardian("World", "world")],
    related: ["diplomacy", "military", "politics"],
  },
  {
    id: "diplomacy",
    nameZh: "国际关系",
    nameEn: "World affairs",
    group: "current",
    hint: "外交、峰会、国际组织和大国关系",
    feeds: [
      NYT_WORLD,
      { name: "Foreign Policy", url: "https://foreignpolicy.com/feed/" },
      { name: "The Diplomat", url: "https://thediplomat.com/feed/" },
      { name: "DW", url: "https://rss.dw.com/rdf/rss-en-world" },
    ],
    related: ["conflict", "politics", "economy"],
  },
  {
    id: "politics",
    nameZh: "政治选举",
    nameEn: "Politics",
    group: "current",
    hint: "各国政治、选举和政策",
    feeds: [
      { name: "Politico", url: "https://rss.politico.com/politics-news.xml" },
      guardian("Politics", "politics"),
      { name: "NPR Politics", url: "https://feeds.npr.org/1014/rss.xml" },
    ],
    related: ["diplomacy", "law", "society"],
  },
  {
    id: "society",
    nameZh: "社会民生",
    nameEn: "Society",
    group: "current",
    hint: "社会议题、民生、移民和公共服务",
    feeds: [guardian("Society", "society"), { name: "NPR National", url: "https://feeds.npr.org/1003/rss.xml" }],
    related: ["politics", "education", "mental_health"],
  },
  {
    id: "law",
    nameZh: "法律案件",
    nameEn: "Law & courts",
    group: "current",
    hint: "重要的司法判决、诉讼和案件",
    feeds: [guardian("Law", "law"), { name: "SCOTUSblog", url: "https://www.scotusblog.com/feed/" }],
    related: ["politics", "society", "cybersecurity"],
  },
  {
    id: "disasters",
    nameZh: "灾难事故",
    nameEn: "Disasters",
    group: "current",
    hint: "地震、台风、山火等自然灾害和重大事故",
    feeds: [
      { name: "ReliefWeb", url: "https://reliefweb.int/updates/rss.xml" },
      { name: "GDACS", url: "https://www.gdacs.org/xml/rss.xml" },
      { name: "USGS", url: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/significant_week.atom" },
    ],
    related: ["climate", "society"],
  },
  {
    id: "military",
    nameZh: "军事",
    nameEn: "Defence",
    group: "current",
    hint: "军事、国防和安全",
    feeds: [
      { name: "Defense News", url: "https://www.defensenews.com/arc/outboundfeeds/rss/" },
      { name: "Breaking Defense", url: "https://breakingdefense.com/feed/" },
      { name: "War on the Rocks", url: "https://warontherocks.com/feed/" },
    ],
    related: ["conflict", "space", "aviation"],
  },

  // MARK: 财经
  {
    id: "economy",
    nameZh: "宏观经济",
    nameEn: "Economy",
    group: "economy",
    hint: "央行、通胀、利率、就业数据和经济政策",
    feeds: [
      { name: "Financial Times", url: "https://www.ft.com/rss/home" },
      { name: "The Economist", url: "https://www.economist.com/finance-and-economics/rss.xml" },
      { name: "CNBC Economy", url: "https://www.cnbc.com/id/20910258/device/rss/rss.html" },
    ],
    related: ["markets", "personal_finance", "real_estate"],
  },
  {
    id: "markets",
    nameZh: "股市投资",
    nameEn: "Markets",
    group: "economy",
    hint: "股市、债市、大宗商品和公司财报",
    feeds: [
      { name: "CNBC", url: "https://www.cnbc.com/id/100003114/device/rss/rss.html" },
      { name: "MarketWatch", url: "https://feeds.content.dowjones.io/public/rss/mw_topstories" },
    ],
    related: ["economy", "crypto", "big_tech"],
  },
  {
    id: "crypto",
    nameZh: "加密货币",
    nameEn: "Crypto",
    group: "economy",
    hint: "比特币等加密货币、区块链和监管",
    feeds: [
      { name: "CoinDesk", url: "https://www.coindesk.com/arc/outboundfeeds/rss/" },
      { name: "Cointelegraph", url: "https://cointelegraph.com/rss" },
      { name: "Decrypt", url: "https://decrypt.co/feed" },
    ],
    related: ["markets", "startups", "cybersecurity"],
  },
  {
    id: "real_estate",
    nameZh: "房地产",
    nameEn: "Property",
    group: "economy",
    hint: "房价、租金、房贷和房地产市场",
    feeds: [guardian("Property", "money/property"), { name: "HousingWire", url: "https://www.housingwire.com/feed/" }],
    related: ["economy", "personal_finance", "home"],
  },
  {
    id: "startups",
    nameZh: "创业公司",
    nameEn: "Startups",
    group: "economy",
    hint: "创业公司、融资和风险投资",
    feeds: [
      { name: "TechCrunch Startups", url: "https://techcrunch.com/category/startups/feed/" },
      { name: "Crunchbase News", url: "https://news.crunchbase.com/feed/" },
      { name: "Sifted", url: "https://sifted.eu/feed" },
    ],
    related: ["ai", "big_tech", "crypto"],
  },
  {
    id: "personal_finance",
    nameZh: "个人理财",
    nameEn: "Personal finance",
    group: "economy",
    hint: "储蓄、税务、养老金和消费者权益",
    feeds: [
      guardian("Money", "money"),
      { name: "Kiplinger", url: "https://www.kiplinger.com/feed/all" },
      { name: "NerdWallet", url: "https://www.nerdwallet.com/blog/feed/" },
    ],
    related: ["economy", "real_estate", "careers"],
  },
  {
    id: "shipping",
    nameZh: "航运贸易",
    nameEn: "Shipping & trade",
    group: "economy",
    hint: "航运、港口、供应链和国际贸易",
    feeds: [
      { name: "gCaptain", url: "https://gcaptain.com/feed/" },
      { name: "Splash247", url: "https://splash247.com/feed/" },
      { name: "The Loadstar", url: "https://theloadstar.com/feed/" },
    ],
    related: ["economy", "energy", "diplomacy"],
  },
  {
    id: "energy",
    nameZh: "能源",
    nameEn: "Energy",
    group: "economy",
    hint: "石油天然气、电力和新能源",
    feeds: [{ name: "OilPrice", url: "https://oilprice.com/rss/main" }, guardian("Energy", "environment/energy")],
    related: ["climate", "economy", "auto"],
  },

  // MARK: 科技
  {
    id: "ai",
    nameZh: "AI",
    nameEn: "AI",
    group: "tech",
    hint: "AI 新模型、新产品和行业动态",
    feeds: [
      { name: "The Verge AI", url: "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml" },
      { name: "TechCrunch AI", url: "https://techcrunch.com/category/artificial-intelligence/feed/" },
      { name: "MIT Technology Review", url: "https://www.technologyreview.com/topic/artificial-intelligence/feed" },
      { name: "OpenAI", url: "https://openai.com/news/rss.xml" },
      { name: "Google AI", url: "https://blog.google/technology/ai/rss/" },
    ],
    related: ["big_tech", "programming", "startups"],
  },
  {
    id: "gadgets",
    nameZh: "手机数码",
    nameEn: "Gadgets",
    group: "tech",
    hint: "手机、电脑、耳机等数码产品",
    feeds: [
      { name: "The Verge", url: "https://www.theverge.com/rss/index.xml" },
      { name: "Engadget", url: "https://www.engadget.com/rss.xml" },
      { name: "9to5Mac", url: "https://9to5mac.com/feed/" },
      { name: "GSMArena", url: "https://www.gsmarena.com/rss-news-reviews.php3" },
    ],
    related: ["big_tech", "gaming", "ai"],
  },
  {
    id: "big_tech",
    nameZh: "互联网公司",
    nameEn: "Big Tech",
    group: "tech",
    hint: "科技巨头、互联网公司和平台监管",
    feeds: [
      { name: "TechCrunch", url: "https://techcrunch.com/feed/" },
      { name: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index" },
      guardian("Technology", "technology"),
    ],
    related: ["ai", "gadgets", "startups"],
  },
  {
    id: "programming",
    nameZh: "编程开发",
    nameEn: "Programming",
    group: "tech",
    hint: "编程语言、开源和软件开发",
    feeds: [
      { name: "Hacker News", url: "https://hnrss.org/frontpage?points=300" },
      { name: "GitHub Blog", url: "https://github.blog/feed/" },
      { name: "InfoQ", url: "https://feed.infoq.com/" },
      { name: "Lobsters", url: "https://lobste.rs/rss" },
    ],
    related: ["ai", "cybersecurity", "startups"],
  },
  {
    id: "cybersecurity",
    nameZh: "网络安全",
    nameEn: "Cybersecurity",
    group: "tech",
    hint: "黑客攻击、数据泄露和网络安全",
    feeds: [
      { name: "BleepingComputer", url: "https://www.bleepingcomputer.com/feed/" },
      { name: "The Hacker News", url: "https://feeds.feedburner.com/TheHackersNews" },
      { name: "Krebs on Security", url: "https://krebsonsecurity.com/feed/" },
    ],
    related: ["programming", "big_tech", "law"],
  },
  {
    id: "space",
    nameZh: "太空航天",
    nameEn: "Space",
    group: "tech",
    hint: "火箭发射、太空探索和天文",
    feeds: [
      { name: "NASA", url: "https://www.nasa.gov/news-release/feed/" },
      { name: "SpaceNews", url: "https://spacenews.com/feed/" },
      { name: "Spaceflight Now", url: "https://spaceflightnow.com/feed/" },
    ],
    related: ["science", "aviation", "military"],
  },
  {
    id: "auto",
    nameZh: "汽车电动车",
    nameEn: "Cars & EVs",
    group: "tech",
    hint: "汽车、电动车和自动驾驶",
    feeds: [
      { name: "Electrek", url: "https://electrek.co/feed/" },
      { name: "InsideEVs", url: "https://insideevs.com/rss/news/all/" },
      { name: "The Drive", url: "https://www.thedrive.com/feed" },
    ],
    related: ["energy", "gadgets", "big_tech"],
  },
  {
    id: "aviation",
    nameZh: "航空",
    nameEn: "Aviation",
    group: "tech",
    hint: "航空公司、飞机和机场",
    feeds: [
      { name: "Simple Flying", url: "https://simpleflying.com/feed/" },
      { name: "AeroTime", url: "https://www.aerotime.aero/feed" },
      { name: "FlightGlobal", url: "https://www.flightglobal.com/rss" },
    ],
    related: ["travel", "space", "military"],
  },

  // MARK: 科学健康
  {
    id: "science",
    nameZh: "科学发现",
    nameEn: "Science",
    group: "science_health",
    hint: "科学研究和新发现",
    feeds: [
      { name: "BBC Science", url: "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml" },
      { name: "Nature", url: "https://www.nature.com/nature.rss" },
      { name: "ScienceDaily", url: "https://www.sciencedaily.com/rss/top/science.xml" },
    ],
    related: ["space", "medicine", "climate"],
  },
  {
    id: "climate",
    nameZh: "气候环境",
    nameEn: "Climate",
    group: "science_health",
    hint: "气候变化、环境和生态",
    feeds: [
      guardian("Environment", "environment"),
      { name: "Carbon Brief", url: "https://www.carbonbrief.org/feed/" },
      { name: "Inside Climate News", url: "https://insideclimatenews.org/feed/" },
    ],
    related: ["energy", "disasters", "science"],
  },
  {
    id: "medicine",
    nameZh: "医学",
    nameEn: "Medicine",
    group: "science_health",
    hint: "医学研究、疾病、药物和公共卫生",
    feeds: [
      { name: "STAT", url: "https://www.statnews.com/feed/" },
      { name: "BBC Health", url: "https://feeds.bbci.co.uk/news/health/rss.xml" },
      { name: "Medical Xpress", url: "https://medicalxpress.com/rss-feed/" },
    ],
    related: ["science", "mental_health", "nutrition"],
  },
  {
    id: "mental_health",
    nameZh: "心理健康",
    nameEn: "Mental health",
    group: "science_health",
    hint: "心理健康和心理学研究",
    feeds: [{ name: "PsyPost", url: "https://www.psypost.org/feed/" }, guardian("Mental health", "society/mental-health")],
    related: ["medicine", "fitness", "society"],
  },
  {
    id: "fitness",
    nameZh: "健身",
    nameEn: "Fitness",
    group: "science_health",
    hint: "运动健身、跑步和户外",
    feeds: [
      guardian("Fitness", "lifeandstyle/fitness"),
      { name: "Runner's World", url: "https://www.runnersworld.com/rss/all.xml/" },
      { name: "Outside", url: "https://www.outsideonline.com/feed/" },
    ],
    related: ["nutrition", "sports", "mental_health"],
  },
  {
    id: "nutrition",
    nameZh: "饮食营养",
    nameEn: "Nutrition",
    group: "science_health",
    hint: "饮食、营养和健康生活",
    feeds: [
      { name: "ScienceDaily Nutrition", url: "https://www.sciencedaily.com/rss/health_medicine/nutrition.xml" },
      guardian("Health & wellbeing", "lifeandstyle/health-and-wellbeing"),
    ],
    related: ["fitness", "food", "medicine"],
  },

  // MARK: 教育职场
  {
    id: "education",
    nameZh: "教育政策",
    nameEn: "Education",
    group: "education",
    hint: "中小学和高校的教育政策",
    feeds: [
      guardian("Education", "education"),
      { name: "The Conversation", url: "https://theconversation.com/au/education/articles.atom" },
      { name: "EdSurge", url: "https://www.edsurge.com/articles_rss" },
    ],
    related: ["higher_ed", "study_abroad", "careers"],
  },
  {
    id: "study_abroad",
    nameZh: "留学移民",
    nameEn: "Study abroad & visas",
    group: "education",
    hint: "留学、签证和移民政策",
    feeds: [
      { name: "The PIE News", url: "https://thepienews.com/feed/" },
      { name: "ICEF Monitor", url: "https://monitor.icef.com/feed/" },
    ],
    related: ["education", "higher_ed", "careers"],
  },
  {
    id: "higher_ed",
    nameZh: "高校科研",
    nameEn: "Universities",
    group: "education",
    hint: "大学、科研经费和学术界",
    feeds: [{ name: "Inside Higher Ed", url: "https://www.insidehighered.com/rss.xml" }],
    related: ["education", "science", "study_abroad"],
  },
  {
    id: "careers",
    nameZh: "就业职场",
    nameEn: "Work & careers",
    group: "education",
    hint: "求职、职场、薪酬和劳动政策",
    feeds: [guardian("Work", "money/work-and-careers"), { name: "HR Dive", url: "https://www.hrdive.com/feeds/news/" }],
    related: ["education", "personal_finance", "startups"],
  },

  // MARK: 体育游戏
  {
    id: "sports",
    nameZh: "体育",
    nameEn: "Sports",
    group: "sports_games",
    hint: "重要的体育赛事和体坛新闻",
    feeds: [
      { name: "BBC Sport", url: "https://feeds.bbci.co.uk/sport/rss.xml" },
      { name: "ESPN", url: "https://www.espn.com/espn/rss/news" },
      guardian("Sport", "sport"),
    ],
    related: ["esports", "fitness"],
  },
  {
    id: "gaming",
    nameZh: "电子游戏",
    nameEn: "Gaming",
    group: "sports_games",
    hint: "游戏新作、主机和游戏行业",
    feeds: [
      { name: "IGN", url: "https://feeds.ign.com/ign/all" },
      { name: "Eurogamer", url: "https://www.eurogamer.net/feed" },
      { name: "PC Gamer", url: "https://www.pcgamer.com/rss/" },
      { name: "GamesIndustry.biz", url: "https://www.gamesindustry.biz/feed" },
    ],
    related: ["esports", "anime", "gadgets"],
  },
  {
    id: "esports",
    nameZh: "电竞",
    nameEn: "Esports",
    group: "sports_games",
    hint: "电子竞技赛事和战队",
    feeds: [
      { name: "Dexerto", url: "https://www.dexerto.com/feed/" },
      { name: "Esports Insider", url: "https://esportsinsider.com/feed" },
      { name: "HLTV", url: "https://www.hltv.org/rss/news" },
    ],
    related: ["gaming", "sports"],
  },

  // MARK: 文化娱乐
  {
    id: "film_tv",
    nameZh: "电影电视",
    nameEn: "Film & TV",
    group: "culture",
    hint: "电影、剧集和流媒体",
    feeds: [
      { name: "Variety", url: "https://variety.com/feed/" },
      { name: "The Hollywood Reporter", url: "https://www.hollywoodreporter.com/feed/" },
      { name: "Deadline", url: "https://deadline.com/feed/" },
    ],
    related: ["celebrity", "music", "books", "anime"],
  },
  {
    id: "music",
    nameZh: "音乐",
    nameEn: "Music",
    group: "culture",
    hint: "新歌新专辑、演唱会和音乐行业",
    feeds: [
      { name: "Pitchfork", url: "https://pitchfork.com/feed/feed-news/rss" },
      { name: "Billboard", url: "https://www.billboard.com/feed/" },
      { name: "Rolling Stone", url: "https://www.rollingstone.com/music/feed/" },
    ],
    related: ["film_tv", "celebrity"],
  },
  {
    id: "anime",
    nameZh: "动漫",
    nameEn: "Anime & manga",
    group: "culture",
    hint: "动画、漫画和二次元",
    feeds: [
      { name: "Anime News Network", url: "https://www.animenewsnetwork.com/all/rss.xml" },
      { name: "Crunchyroll News", url: "https://cr-news-api-service.prd.crunchyrollsvc.com/v1/en-US/rss" },
    ],
    related: ["gaming", "film_tv"],
  },
  {
    id: "celebrity",
    nameZh: "明星八卦",
    nameEn: "Celebrity",
    group: "culture",
    hint: "明星和娱乐圈新闻",
    feeds: [
      { name: "E! News", url: "https://www.eonline.com/syndication/feeds/rssfeeds/topstories.xml" },
      { name: "Page Six", url: "https://pagesix.com/feed/" },
    ],
    related: ["film_tv", "music", "fashion"],
  },
  {
    id: "books",
    nameZh: "读书",
    nameEn: "Books",
    group: "culture",
    hint: "新书、作家和出版",
    feeds: [guardian("Books", "books"), { name: "Literary Hub", url: "https://lithub.com/feed/" }],
    related: ["history", "film_tv", "art_design"],
  },
  {
    id: "art_design",
    nameZh: "艺术设计",
    nameEn: "Art & design",
    group: "culture",
    hint: "艺术、设计和建筑",
    feeds: [
      { name: "Dezeen", url: "https://www.dezeen.com/feed/" },
      { name: "Colossal", url: "https://www.thisiscolossal.com/feed/" },
      guardian("Art & design", "artanddesign"),
    ],
    related: ["home", "fashion", "books"],
  },
  {
    id: "history",
    nameZh: "历史文化",
    nameEn: "History & ideas",
    group: "culture",
    hint: "历史、考古和人文思想",
    feeds: [
      { name: "Smithsonian", url: "https://www.smithsonianmag.com/rss/latest_articles/" },
      { name: "Aeon", url: "https://aeon.co/feed.rss" },
    ],
    related: ["books", "diplomacy"],
  },

  // MARK: 生活
  {
    id: "food",
    nameZh: "美食",
    nameEn: "Food",
    group: "life",
    hint: "餐厅、菜谱和饮食文化",
    feeds: [{ name: "Eater", url: "https://www.eater.com/rss/index.xml" }, guardian("Food", "food")],
    related: ["travel", "nutrition"],
  },
  {
    id: "travel",
    nameZh: "旅行",
    nameEn: "Travel",
    group: "life",
    hint: "旅游目的地、机票酒店和出行",
    feeds: [
      guardian("Travel", "travel"),
      { name: "Skift", url: "https://skift.com/feed/" },
      { name: "The Points Guy", url: "https://thepointsguy.com/feed/" },
    ],
    related: ["aviation", "food"],
  },
  {
    id: "fashion",
    nameZh: "时尚",
    nameEn: "Fashion",
    group: "life",
    hint: "时装、品牌和潮流",
    feeds: [{ name: "Vogue", url: "https://www.vogue.com/feed/rss" }, { name: "Hypebeast", url: "https://hypebeast.com/feed" }],
    related: ["celebrity", "art_design"],
  },
  {
    id: "home",
    nameZh: "家居",
    nameEn: "Home",
    group: "life",
    hint: "家居、装修和收纳",
    feeds: [{ name: "Apartment Therapy", url: "https://www.apartmenttherapy.com/main.rss" }, guardian("Homes", "lifeandstyle/homes")],
    related: ["real_estate", "art_design"],
  },
  {
    id: "pets",
    nameZh: "宠物",
    nameEn: "Pets",
    group: "life",
    hint: "猫狗等宠物",
    feeds: [guardian("Pets", "lifeandstyle/pets")],
    related: ["home", "parenting"],
  },
  {
    id: "parenting",
    nameZh: "育儿",
    nameEn: "Parenting",
    group: "life",
    hint: "育儿、家庭和亲子",
    feeds: [guardian("Family", "lifeandstyle/family"), guardian("Parents", "lifeandstyle/parents-and-parenting")],
    related: ["education", "home"],
  },
];

/** 新用户默认的兴趣 */
export const DEFAULT_TOPICS = ["conflict", "ai", "markets", "science"];

/** 旧版话题 id → 新的兴趣（旧的地区话题不再是兴趣，地区改成从阅读里推断） */
export const LEGACY_TOPICS: Record<string, string[]> = {
  conflict: ["conflict"],
  international: ["diplomacy"],
  tech_ai: ["ai"],
  finance: ["markets", "economy"],
  education: ["education"],
  shipping: ["shipping"],
  science: ["science"],
  health: ["medicine"],
  sports: ["sports"],
  culture: ["film_tv"],
};

// MARK: - 地区（AI 给新闻标的地区；常看的地区自动加上对应的源）

export interface Region {
  id: string;
  nameZh: string;
  nameEn: string;
  /** 国家所在的洲（洲本身没有） */
  continent?: string;
  /** 这个地区的源；国家没有自己的源时用所在洲的 */
  feeds: Feed[];
}

export const GLOBAL = "global";

const CONTINENTS: Region[] = [
  {
    id: "asia",
    nameZh: "亚洲",
    nameEn: "Asia",
    feeds: [
      { name: "BBC Asia", url: "https://feeds.bbci.co.uk/news/world/asia/rss.xml" },
      { name: "Nikkei Asia", url: "https://asia.nikkei.com/rss/feed/nar" },
    ],
  },
  {
    id: "europe",
    nameZh: "欧洲",
    nameEn: "Europe",
    feeds: [
      { name: "BBC Europe", url: "https://feeds.bbci.co.uk/news/world/europe/rss.xml" },
      guardian("Europe", "world/europe-news"),
    ],
  },
  { id: "north_america", nameZh: "北美", nameEn: "North America", feeds: [BBC_US, NPR] },
  {
    id: "latin_america",
    nameZh: "拉美",
    nameEn: "Latin America",
    feeds: [
      { name: "BBC Latin America", url: "https://feeds.bbci.co.uk/news/world/latin_america/rss.xml" },
      guardian("Americas", "world/americas"),
    ],
  },
  {
    id: "middle_east",
    nameZh: "中东",
    nameEn: "Middle East",
    feeds: [
      { name: "BBC Middle East", url: "https://feeds.bbci.co.uk/news/world/middle_east/rss.xml" },
      guardian("Middle East", "world/middleeast"),
    ],
  },
  {
    id: "africa",
    nameZh: "非洲",
    nameEn: "Africa",
    feeds: [{ name: "BBC Africa", url: "https://feeds.bbci.co.uk/news/world/africa/rss.xml" }, guardian("Africa", "world/africa")],
  },
  { id: "oceania", nameZh: "大洋洲", nameEn: "Oceania", feeds: [ABC_AU, RNZ] },
];

const COUNTRIES: Region[] = [
  {
    id: "china",
    nameZh: "中国",
    nameEn: "China",
    continent: "asia",
    feeds: [
      { name: "BBC 中文", url: "https://feeds.bbci.co.uk/zhongwen/simp/rss.xml" },
      { name: "SCMP", url: "https://www.scmp.com/rss/4/feed" },
      { name: "DW 中文", url: "https://rss.dw.com/rdf/rss-chi-all" },
      { name: "CGTN", url: "https://www.cgtn.com/subscribe/rss/section/china.xml" },
    ],
  },
  {
    id: "japan",
    nameZh: "日本",
    nameEn: "Japan",
    continent: "asia",
    feeds: [{ name: "Japan Times", url: "https://www.japantimes.co.jp/feed/" }],
  },
  { id: "south_korea", nameZh: "韩国", nameEn: "South Korea", continent: "asia", feeds: [] },
  {
    id: "india",
    nameZh: "印度",
    nameEn: "India",
    continent: "asia",
    feeds: [
      { name: "The Hindu", url: "https://www.thehindu.com/news/national/feeder/default.rss" },
      { name: "Indian Express", url: "https://indianexpress.com/section/india/feed/" },
    ],
  },
  {
    id: "singapore",
    nameZh: "新加坡",
    nameEn: "Singapore",
    continent: "asia",
    feeds: [
      { name: "CNA", url: "https://www.channelnewsasia.com/api/v1/rss-outbound-feed?_format=xml&category=10416" },
      { name: "The Straits Times", url: "https://www.straitstimes.com/news/singapore/rss.xml" },
    ],
  },
  { id: "australia", nameZh: "澳洲", nameEn: "Australia", continent: "oceania", feeds: [ABC_AU, SMH, guardian("Australia", "australia-news")] },
  {
    id: "new_zealand",
    nameZh: "新西兰",
    nameEn: "New Zealand",
    continent: "oceania",
    feeds: [RNZ, { name: "NZ Herald", url: "https://www.nzherald.co.nz/arc/outboundfeeds/rss/curated/78/?outputType=xml" }],
  },
  { id: "us", nameZh: "美国", nameEn: "United States", continent: "north_america", feeds: [NPR, NYT_US] },
  {
    id: "canada",
    nameZh: "加拿大",
    nameEn: "Canada",
    continent: "north_america",
    feeds: [{ name: "CBC", url: "https://www.cbc.ca/webfeed/rss/rss-canada" }, { name: "Global News", url: "https://globalnews.ca/feed/" }],
  },
  {
    id: "uk",
    nameZh: "英国",
    nameEn: "United Kingdom",
    continent: "europe",
    feeds: [{ name: "BBC UK", url: "https://feeds.bbci.co.uk/news/uk/rss.xml" }, guardian("UK", "uk-news")],
  },
  { id: "germany", nameZh: "德国", nameEn: "Germany", continent: "europe", feeds: [] },
  { id: "france", nameZh: "法国", nameEn: "France", continent: "europe", feeds: [] },
  { id: "russia", nameZh: "俄罗斯", nameEn: "Russia", continent: "europe", feeds: [] },
  { id: "ukraine", nameZh: "乌克兰", nameEn: "Ukraine", continent: "europe", feeds: [] },
  { id: "israel", nameZh: "以色列", nameEn: "Israel", continent: "middle_east", feeds: [] },
  { id: "iran", nameZh: "伊朗", nameEn: "Iran", continent: "middle_east", feeds: [] },
  { id: "brazil", nameZh: "巴西", nameEn: "Brazil", continent: "latin_america", feeds: [] },
];

export const REGIONS: Region[] = [...COUNTRIES, ...CONTINENTS];

/** 地区的源：国家没有自己的源就用所在洲的，最多两个 */
export function regionFeeds(id: string): Feed[] {
  const region = REGIONS.find((r) => r.id === id);
  if (!region) return [];
  const feeds = region.feeds.length ? region.feeds : (CONTINENTS.find((c) => c.id === region.continent)?.feeds ?? []);
  return feeds.slice(0, 2);
}

/** 关注的城市的国家代码 → 地区 id（第一次还没有阅读数据时，用来猜常看的地区） */
export const COUNTRY_CODES: Record<string, string> = {
  CN: "china",
  HK: "china",
  JP: "japan",
  KR: "south_korea",
  IN: "india",
  SG: "singapore",
  AU: "australia",
  NZ: "new_zealand",
  US: "us",
  CA: "canada",
  GB: "uk",
  DE: "germany",
  FR: "france",
  RU: "russia",
  UA: "ukraine",
  IL: "israel",
  IR: "iran",
  BR: "brazil",
};

export function nameOf(id: string): { nameZh: string; nameEn: string } | undefined {
  const found = TOPICS.find((t) => t.id === id) ?? REGIONS.find((r) => r.id === id);
  if (found) return { nameZh: found.nameZh, nameEn: found.nameEn };
  if (id === GLOBAL) return { nameZh: "全球", nameEn: "Global" };
  if (id === "weather") return { nameZh: "天气", nameEn: "Weather" };
  if (id === "other") return { nameZh: "其他", nameEn: "Other" };
  return undefined;
}

// MARK: - 取源

/** 一次最多抓这么多个源（免费版 Worker 每次只有 10ms CPU，解析 RSS 要省着用） */
export const MAX_FEEDS = 40;

export interface TaggedFeed extends Feed {
  /** 来源标签，写在标题前给模型参考：topic/ai、region/china、explore/music、custom */
  tag: string;
}

export interface FeedPlan {
  /** 每个兴趣明天几条（0 的不取源） */
  allocation: Record<string, number>;
  /** 常看的地区 */
  regions: string[];
  /** 猜你喜欢的候选兴趣 */
  candidates: string[];
  /** 按关键词搜新闻（兴趣里最近爱看的小类） */
  searches?: { interest: string; query: string }[];
  custom: Feed[];
}

/** 按关键词搜的源最多几个 */
export const MAX_SEARCHES = 4;

/** Bing 新闻按关键词搜索，最新的在前 */
export function searchFeed(query: string): Feed {
  const q = encodeURIComponent(/\s/.test(query) ? `"${query}"` : query);
  return { name: `Bing 新闻：${query}`, url: `https://www.bing.com/news/search?q=${q}&qft=sortbydate%3d%221%22&format=rss` };
}

/**
 * 要抓的源（去重，最多 40 个）：条数越多的兴趣取越多源；加上常看地区和猜你喜欢候选的源。
 * 各部分、各兴趣轮流取，这样到上限时每个兴趣都至少有一个源
 */
export function feedsFor(plan: FeedPlan): TaggedFeed[] {
  const tagged = (feeds: Feed[], tag: string) => feeds.map((f) => ({ ...f, tag }));
  const topics = Object.entries(plan.allocation)
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([id, n]) => {
      const feeds = TOPICS.find((t) => t.id === id)?.feeds ?? [];
      return tagged(feeds.slice(0, Math.max(1, n)), `topic/${id}`);
    });
  const regions = plan.regions.map((id) => tagged(regionFeeds(id), `region/${id}`));
  const explore = plan.candidates.map((id) => tagged((TOPICS.find((t) => t.id === id)?.feeds ?? []).slice(0, 2), `explore/${id}`));
  const searches = (plan.searches ?? []).slice(0, MAX_SEARCHES).map((s) => ({ ...searchFeed(s.query), tag: `topic/${s.interest}` }));

  const seen = new Set<string>();
  const feeds: TaggedFeed[] = [];
  for (const feed of interleave([interleave(topics), searches, interleave(regions), interleave(explore), tagged(plan.custom, "custom")])) {
    if (feeds.length >= MAX_FEEDS) break;
    if (seen.has(feed.url)) continue;
    seen.add(feed.url);
    feeds.push(feed);
  }
  return feeds;
}

/** [[a1, a2], [b1], [c1, c2]] → [a1, b1, c1, a2, c2] */
function interleave<T>(lists: T[][]): T[] {
  const out: T[] = [];
  const longest = Math.max(0, ...lists.map((l) => l.length));
  for (let i = 0; i < longest; i++) {
    for (const list of lists) if (i < list.length) out.push(list[i]);
  }
  return out;
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
