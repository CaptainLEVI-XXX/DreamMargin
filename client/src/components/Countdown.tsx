import { useEffect, useState } from "react";
import { Value } from "./Value";

/**
 * Time until a market stops trading.
 *
 * Markets roll on a fixed interval, so "ends in" is the number that decides
 * whether a position has room to be opened at all — the opening cutoff is 20
 * minutes before expiry. It ticks because a static timestamp goes stale on
 * screen, and stops at zero rather than counting negative.
 */
export function Countdown({ expiry }: { expiry: bigint }) {
  const [now, setNow] = useState(() => BigInt(Math.floor(Date.now() / 1000)));

  useEffect(() => {
    const id = window.setInterval(() => setNow(BigInt(Math.floor(Date.now() / 1000))), 1_000);
    return () => window.clearInterval(id);
  }, []);

  const left = expiry > now ? expiry - now : 0n;
  if (left === 0n) return <span className="dm-countdown">Trading closed</span>;

  // One format at a constant width, so a row's columns never shift as it ticks.
  const totalHours = left / 3_600n;
  const m = (left % 3_600n) / 60n;
  const s = left % 60n;
  const pad = (v: bigint) => String(v).padStart(2, "0");

  return (
    <span className="dm-countdown">
      <Value>{`${pad(totalHours)}:${pad(m)}:${pad(s)}`}</Value>
    </span>
  );
}
