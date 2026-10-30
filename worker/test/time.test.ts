import { describe, expect, it } from "vitest";
import { canonicalDue, localTime, localWeekday } from "../src/time";

const sydney = "Australia/Sydney";

describe("email analysis times", () => {
  it("shows times in the user's time zone, with the weekday separately", () => {
    // UTC 还是周五，悉尼已经是周六早上
    expect(localTime("2026-10-30T22:00:00Z", sydney)).toBe("2026-10-31T09:00:00+11:00");
    expect(localWeekday("2026-10-30T22:00:00Z", sydney)).toBe("星期六");
    expect(localTime("2026-10-30T22:00:00Z", "Asia/Kathmandu")).toBe("2026-10-31T03:45:00+05:45");
    expect(localTime("not a date", sydney)).toBe("not a date");
    expect(localWeekday("not a date", sydney)).toBe("");
  });

  it("turns every due format the model writes into one the app can read", () => {
    expect(canonicalDue("2026-11-02T23:59:00+11:00", sydney)).toBe("2026-11-02T12:59:00.000Z");
    expect(canonicalDue("2026-11-02T23:59+11:00", sydney)).toBe("2026-11-02T12:59:00.000Z");
    expect(canonicalDue("2026-11-02T23:59:00+1100", sydney)).toBe("2026-11-02T12:59:00.000Z");
    expect(canonicalDue("2026-11-02T23:59:00+11", sydney)).toBe("2026-11-02T12:59:00.000Z");
    expect(canonicalDue("2026-11-02T12:59:00Z", sydney)).toBe("2026-11-02T12:59:00.000Z");
    // 后面多写了星期、括号说明
    expect(canonicalDue("2026-11-06T17:00:00+11:00 星期五", sydney)).toBe("2026-11-06T06:00:00.000Z");
    expect(canonicalDue("2026-11-06T17:00:00（悉尼时间）", sydney)).toBe("2026-11-06T06:00:00.000Z");
    // 没写偏移：按用户时区；只有日期：当天 23:59
    expect(canonicalDue("2026-11-02T17:00:00", sydney)).toBe("2026-11-02T06:00:00.000Z");
    expect(canonicalDue("2026-11-02 17:00", sydney)).toBe("2026-11-02T06:00:00.000Z");
    expect(canonicalDue("2026-11-02", sydney)).toBe("2026-11-02T12:59:00.000Z");
    expect(canonicalDue("2026-11-02 星期一", sydney)).toBe("2026-11-02T12:59:00.000Z");
    // 夏令时开始那天（10 月 4 日 2 点起 +11）和前一天
    expect(canonicalDue("2026-10-04T12:00:00", sydney)).toBe("2026-10-04T01:00:00.000Z");
    expect(canonicalDue("2026-10-03T12:00:00", sydney)).toBe("2026-10-03T02:00:00.000Z");
    expect(canonicalDue("next Friday", sydney)).toBeNull();
    expect(canonicalDue("2026-13-02", sydney)).toBeNull();
    expect(canonicalDue(null, sydney)).toBeNull();
  });
});
