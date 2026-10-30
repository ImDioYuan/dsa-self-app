/** 时区换算。Worker 运行在 UTC，邮件分析要按用户的时区看时间 */

// 免费版每次只有 10ms CPU：Intl.DateTimeFormat 建一次就缓存，一批 50 封邮件不用建几百次
const formatters = new Map<string, Intl.DateTimeFormat>();
function formatter(key: string, make: () => Intl.DateTimeFormat): Intl.DateTimeFormat {
  let f = formatters.get(key);
  if (!f) {
    f = make();
    formatters.set(key, f);
  }
  return f;
}

/** 用户时区里的偏移（分钟），例如悉尼夏令时 +660 */
function offsetMinutes(timezone: string, at: number): number {
  try {
    const name =
      formatter(`offset:${timezone}`, () => new Intl.DateTimeFormat("en-US", { timeZone: timezone, timeZoneName: "longOffset" }))
        .formatToParts(new Date(at))
        .find((p) => p.type === "timeZoneName")?.value ?? "GMT";
    const m = /GMT([+-])(\d{2}):(\d{2})/.exec(name);
    return m ? (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : 0;
  } catch {
    return 0;
  }
}

/**
 * UTC 时间换成用户时区的本地时间（ISO 8601，带偏移），例如 2026-10-31T09:00:00+11:00。
 * 模型按它推算「明天」「周五」；UTC 的日期常常比悉尼早一天
 */
export function localTime(iso: string, timezone: string): string {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return iso;
  try {
    const parts = Object.fromEntries(
      formatter(
        `local:${timezone}`,
        () =>
          new Intl.DateTimeFormat("en-CA", {
            timeZone: timezone,
            year: "numeric",
            month: "2-digit",
            day: "2-digit",
            hour: "2-digit",
            minute: "2-digit",
            second: "2-digit",
            hourCycle: "h23",
          }),
      )
        .formatToParts(new Date(at))
        .map((p) => [p.type, p.value]),
    );
    const offset = offsetMinutes(timezone, at);
    const sign = offset < 0 ? "-" : "+";
    const hh = String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0");
    const mm = String(Math.abs(offset) % 60).padStart(2, "0");
    return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}${sign}${hh}:${mm}`;
  } catch {
    return iso;
  }
}

/** 用户时区里那天星期几，例如 星期六。单独给模型，不拼进时间里（免得它照抄进 due） */
export function localWeekday(iso: string, timezone: string): string {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return "";
  try {
    return formatter(`weekday:${timezone}`, () => new Intl.DateTimeFormat("zh-CN", { timeZone: timezone, weekday: "long" })).format(
      new Date(at),
    );
  } catch {
    return "";
  }
}

/**
 * 模型写的截止时间统一成 App 能读的 ISO 8601（UTC）。没写偏移的按用户时区算，只有日期的算当天 23:59；
 * 后面多写的星期、括号里的说明忽略；认不出来的当作没有时间（以前原样传给 App，一个怪格式会让整批邮件解析失败）
 */
export function canonicalDue(due: string | null, timezone: string): string | null {
  const m =
    /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?(?:[\s（(].*)?$/i.exec(
      due?.trim() ?? "",
    );
  if (!m) return null;
  const [, y, mo, d, h = "23", mi = "59", s = "00", zone] = m;
  if (+mo < 1 || +mo > 12 || +d < 1 || +d > 31 || +h > 23 || +mi > 59 || +s > 59) return null;
  if (zone) {
    const offset =
      zone.toUpperCase() === "Z" ? "Z" : zone.length === 3 ? `${zone}:00` : zone.includes(":") ? zone : `${zone.slice(0, 3)}:${zone.slice(3)}`;
    const at = Date.parse(`${y}-${mo}-${d}T${h}:${mi}:${s}${offset}`);
    return Number.isNaN(at) ? null : new Date(at).toISOString();
  }
  // 当成用户时区的钟点：先按 UTC 算，再减去当时的偏移（算两次，夏令时切换那几天也对）
  const wall = Date.UTC(+y, +mo - 1, +d, +h, +mi, +s);
  const guess = wall - offsetMinutes(timezone, wall) * 60_000;
  return new Date(wall - offsetMinutes(timezone, guess) * 60_000).toISOString();
}
