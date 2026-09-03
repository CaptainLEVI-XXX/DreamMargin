/**
 * Decimal-safe money arithmetic. Every token amount, price, and ratio in the
 * client is a bigint in native units until the moment it is formatted for
 * display. Nothing here may use JavaScript floating-point numbers.
 */

const DIGITS = /^[0-9]*$/;

/**
 * Parse a user-entered decimal string into native token units.
 * Throws rather than silently truncating when the input carries more precision
 * than the token can represent.
 */
export function parseUnitsStrict(value: string, decimals: number): bigint {
  const trimmed = value.trim();
  if (trimmed === "" || trimmed === ".") throw new Error(`invalid amount: ${value}`);

  const parts = trimmed.split(".");
  if (parts.length > 2) throw new Error(`invalid amount: ${value}`);

  const [whole = "", fraction = ""] = parts;
  if (!DIGITS.test(whole) || !DIGITS.test(fraction)) throw new Error(`invalid amount: ${value}`);
  if (fraction.length > decimals) {
    throw new Error(`too much precision for ${decimals} decimals: ${value}`);
  }

  const padded = fraction.padEnd(decimals, "0");
  return BigInt(`${whole === "" ? "0" : whole}${padded}`);
}

/** Format native units for display, truncating (never rounding) extra digits. */
export function formatUnits(value: bigint, decimals: number, maxFractionDigits?: number): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  let fraction = (abs % base).toString().padStart(decimals, "0");

  if (maxFractionDigits !== undefined) fraction = fraction.slice(0, maxFractionDigits);
  fraction = fraction.replace(/0+$/, "");

  const sign = negative ? "-" : "";
  return fraction === "" ? `${sign}${whole}` : `${sign}${whole}.${fraction}`;
}

/** Multiply then divide, rounding toward zero. Mirrors the Solidity helper. */
export function mulDivDown(x: bigint, y: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error("zero denominator");
  return (x * y) / d;
}

/** Multiply then divide, rounding away from zero. Mirrors the Solidity helper. */
export function mulDivUp(x: bigint, y: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error("zero denominator");
  if (x === 0n || y === 0n) return 0n;
  return (x * y + d - 1n) / d;
}

/** Round down to a whole multiple of `quantum`, as a venue lot requires. */
export function quantizeDown(value: bigint, quantum: bigint): bigint {
  if (quantum === 0n) throw new Error("zero quantum");
  return value - (value % quantum);
}

/** Round up to a whole multiple of `quantum`. */
export function quantizeUp(value: bigint, quantum: bigint): bigint {
  if (quantum === 0n) throw new Error("zero quantum");
  const remainder = value % quantum;
  return remainder === 0n ? value : value + (quantum - remainder);
}

/** Render basis points as a percentage string, trimming trailing zeros. */
export function formatBps(bps: bigint): string {
  return `${formatUnits(bps, 2)}%`;
}

/**
 * Render an outcome price in cents. `oneCollateral` is one whole unit of the
 * market's collateral, so the ratio is scaled to a 0-100 range.
 */
export function formatCents(price: bigint, oneCollateral: bigint): string {
  if (oneCollateral === 0n) throw new Error("zero denominator");
  const scaled = (price * 10_000n) / oneCollateral;
  return `${formatUnits(scaled, 2)}¢`;
}
