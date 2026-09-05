import { useEffect, useState } from "react";
import { formatTimeLeft } from "../domain/time";
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

  return (
    <span className="dm-countdown">
      <Value>{formatTimeLeft(left)}</Value>
    </span>
  );
}
