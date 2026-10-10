import { decodeEntities, readPrefix } from "../text";

/** 读网页最多这么多字节（HTMLRewriter 解析也要花 CPU，免费版 Worker 每次只有 10ms） */
const PAGE_BYTES = 300_000;

/**
 * 没有原生联网工具的服务商（DeepSeek）用的读网页工具：抓网页，只留标题、段落和列表文字。
 * 读不到时返回说明文字而不是抛错，模型可以换一个链接
 */
export async function fetchPageText(rawURL: string, maxChars = 12_000): Promise<{ ok: boolean; title: string; text: string }> {
  let url: URL;
  try {
    url = new URL(rawURL);
  } catch {
    return { ok: false, title: "", text: "链接格式不对" };
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return { ok: false, title: "", text: "只支持 http(s) 链接" };

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; DSA-News/1.0)", Accept: "text/html,application/xhtml+xml" },
      signal: AbortSignal.timeout(15_000),
    });
  } catch (err) {
    return { ok: false, title: "", text: `打不开：${err instanceof Error ? err.message : String(err)}` };
  }
  if (!response.ok) return { ok: false, title: "", text: `打不开：HTTP ${response.status}` };
  if (!(response.headers.get("Content-Type") ?? "").includes("html")) return { ok: false, title: "", text: "不是网页" };

  const html = await readPrefix(response, PAGE_BYTES);
  let title = "";
  const blocks: string[] = [];
  let current = "";
  let skipDepth = 0;
  const flush = () => {
    const text = decodeEntities(current).replace(/\s+/g, " ").trim();
    if (text.length > 1) blocks.push(text);
    current = "";
  };

  await new HTMLRewriter()
    .on("title", { text: (t) => void (title += t.text) })
    .on("script, style, nav, footer, aside, form, noscript", {
      element: (el) => {
        skipDepth++;
        el.onEndTag(() => void skipDepth--);
      },
    })
    .on("h1, h2, h3, p, li, blockquote", {
      element: (el) => {
        flush();
        el.onEndTag(flush);
      },
      text: (t) => {
        if (skipDepth === 0) current += t.text;
      },
    })
    .transform(new Response(html, { headers: { "Content-Type": "text/html" } }))
    .arrayBuffer();
  flush();

  const text = blocks.join("\n").slice(0, maxChars);
  return { ok: text.length > 0, title: decodeEntities(title).trim(), text: text || "网页里没有读到正文（可能需要登录或有付费墙）" };
}
