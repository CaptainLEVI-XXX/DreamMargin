import { describe, expect, it } from "vitest";
import {
  formatBps,
  formatCents,
  formatUnits,
  mulDivDown,
  mulDivUp,
  parseUnitsStrict,
  quantizeDown,
  quantizeUp,
} from "./amounts";

describe("parseUnitsStrict", () => {
  it("parses a whole number", () => {
    expect(parseUnitsStrict("100", 6)).toBe(100_000_000n);
  });

  it("parses a fractional value", () => {
    expect(parseUnitsStrict("1.5", 6)).toBe(1_500_000n);
  });

  it("pads a short fraction", () => {
    expect(parseUnitsStrict("0.5", 6)).toBe(500_000n);
  });

  it("accepts exactly `decimals` fraction digits", () => {
    expect(parseUnitsStrict("0.123456", 6)).toBe(123_456n);
  });

  it("rejects more precision than the token has", () => {
    expect(() => parseUnitsStrict("0.1234567", 6)).toThrow(/precision/i);
  });

  it("rejects a non-numeric string", () => {
    expect(() => parseUnitsStrict("abc", 6)).toThrow(/invalid/i);
  });

  it("rejects a negative amount", () => {
    expect(() => parseUnitsStrict("-1", 6)).toThrow(/invalid/i);
  });

  it("rejects the empty string", () => {
    expect(() => parseUnitsStrict("", 6)).toThrow(/invalid/i);
  });

  it("treats a bare dot-prefixed value as valid", () => {
    expect(parseUnitsStrict(".25", 6)).toBe(250_000n);
  });
});

describe("formatUnits", () => {
  it("formats a whole number", () => {
    expect(formatUnits(100_000_000n, 6)).toBe("100");
  });

  it("formats a fraction and trims trailing zeros", () => {
    expect(formatUnits(1_500_000n, 6)).toBe("1.5");
  });

  it("formats zero", () => {
    expect(formatUnits(0n, 6)).toBe("0");
  });

  it("truncates rather than rounds at the digit limit", () => {
    expect(formatUnits(1_239_999n, 6, 2)).toBe("1.23");
  });

  it("round-trips with parseUnitsStrict", () => {
    expect(formatUnits(parseUnitsStrict("1234.5678", 6), 6)).toBe("1234.5678");
  });
});

describe("mulDiv", () => {
  it("rounds down", () => {
    expect(mulDivDown(7n, 3n, 2n)).toBe(10n);
  });

  it("rounds up", () => {
    expect(mulDivUp(7n, 3n, 2n)).toBe(11n);
  });

  it("rounds up exactly when there is no remainder", () => {
    expect(mulDivUp(6n, 2n, 3n)).toBe(4n);
  });

  it("returns zero from mulDivUp when a factor is zero", () => {
    expect(mulDivUp(0n, 5n, 3n)).toBe(0n);
  });

  it("throws on a zero denominator", () => {
    expect(() => mulDivDown(1n, 1n, 0n)).toThrow(/denominator/i);
    expect(() => mulDivUp(1n, 1n, 0n)).toThrow(/denominator/i);
  });
});

describe("quantize", () => {
  it("floors to the lot", () => {
    expect(quantizeDown(1050n, 100n)).toBe(1000n);
  });

  it("ceils to the lot", () => {
    expect(quantizeUp(1050n, 100n)).toBe(1100n);
  });

  it("leaves an exact multiple untouched", () => {
    expect(quantizeDown(1000n, 100n)).toBe(1000n);
    expect(quantizeUp(1000n, 100n)).toBe(1000n);
  });
});

describe("display helpers", () => {
  it("formats basis points as a percentage", () => {
    expect(formatBps(2400n)).toBe("24%");
  });

  it("keeps one decimal for a fractional percentage", () => {
    expect(formatBps(1125n)).toBe("11.25%");
  });

  it("formats a price as cents", () => {
    expect(formatCents(620_000n, 1_000_000n)).toBe("62¢");
  });

  it("formats a fractional cent price", () => {
    expect(formatCents(625_000n, 1_000_000n)).toBe("62.5¢");
  });
});
