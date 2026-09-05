import { describe, expect, it } from "vitest";
import { formatTimeLeft } from "./time";

describe("formatTimeLeft", () => {
  it("shows long markets as days, hours, and minutes without understating time left", () => {
    expect(formatTimeLeft(15n * 86_400n + 12n * 3_600n + 10n * 60n)).toBe("15d : 12h : 10m");
    expect(formatTimeLeft(1n)).toBe("0d : 00h : 01m");
  });
});
