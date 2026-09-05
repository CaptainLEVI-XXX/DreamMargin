/** Compact long-market duration, rounded up so an open market never reads zero. */
export function formatTimeLeft(seconds: bigint): string {
  const totalMinutes = (seconds + 59n) / 60n;
  const days = totalMinutes / 1_440n;
  const hours = (totalMinutes % 1_440n) / 60n;
  const minutes = totalMinutes % 60n;
  const pad = (value: bigint) => String(value).padStart(2, "0");
  return `${days}d : ${pad(hours)}h : ${pad(minutes)}m`;
}
