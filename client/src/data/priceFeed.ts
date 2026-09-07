/**
 * Index price feed.
 *
 * Design FS-1: the builder chart plots the underlying asset price, not the YES
 * probability. The probability series carries three trades in total across both
 * pools, where this feed carries tens of ticks per minute — a candlestick of
 * three isolated prints implies a trend those prints cannot support.
 *
 * Prices arrive as fixed-point strings at the feed's declared decimals and stay
 * bigint until they are formatted or projected onto a chart axis.
 */

export const PRICE_FEED_URL = "https://price-feed.dev.oracle.somnia.host/v1/graphql";

/** Resolutions the feed actually materialises. Probed against the live feed. */
export type Resolution = "M1" | "H1" | "D1";

const CANDLE_QUERY = `
  query IndexCandles($base: String!, $quote: String!, $resolution: candleresolution!, $limit: Int!) {
    Candle(
      where: { base: { _eq: $base }, quote: { _eq: $quote }, resolution: { _eq: $resolution } }
      order_by: { bucketStart: desc }
      limit: $limit
    ) {
      bucketStart
      open
      high
      low
      close
      count
    }
    Feed(where: { base: { _eq: $base }, quote: { _eq: $quote } }) {
      decimals
      latestSpot
      latestUpdatedAtMs
    }
  }
`;

export type IndexPoint = {
  /** Bucket open, unix seconds. */
  time: bigint;
  open: bigint;
  high: bigint;
  low: bigint;
  close: bigint;
  /** Ticks aggregated into this bucket. */
  count: number;
};

export type IndexSeries = {
  points: IndexPoint[];
  decimals: number;
  /** Latest spot, or null when the feed has none. */
  spot: bigint | null;
  updatedAtMs: bigint | null;
};

type RawCandle = {
  bucketStart: string;
  open: string;
  high: string;
  low: string;
  close: string;
  count: number;
};

/**
 * Fetch an index series, oldest first so it can be drawn left to right.
 *
 * The quote is pinned by the caller: the feed holds several quotes per base and
 * matching them all double-counts buckets, which breaks any chart requiring
 * strictly ascending unique timestamps.
 */
export async function fetchIndexSeries(
  base: string,
  quote: string,
  resolution: Resolution,
  limit: number,
  fetchImpl: typeof fetch = fetch,
  url: string = PRICE_FEED_URL,
): Promise<IndexSeries> {
  const response = await fetchImpl(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      query: CANDLE_QUERY,
      variables: { base, quote, resolution, limit },
    }),
  });

  if (!response.ok) throw new Error(`price feed returned ${response.status}`);

  const body = (await response.json()) as {
    data?: {
      Candle?: RawCandle[];
      Feed?: { decimals: number; latestSpot: string | null; latestUpdatedAtMs: string | null }[];
    };
    errors?: { message: string }[];
  };

  if (body.errors !== undefined && body.errors.length > 0) {
    throw new Error(`price feed error: ${body.errors[0].message}`);
  }

  const feed = body.data?.Feed?.[0];

  return {
    // Newest-first from the query; reversed so the chart reads left to right.
    points: (body.data?.Candle ?? [])
      .map((c) => ({
        time: BigInt(c.bucketStart),
        open: BigInt(c.open),
        high: BigInt(c.high),
        low: BigInt(c.low),
        close: BigInt(c.close),
        count: c.count,
      }))
      .reverse(),
    decimals: feed?.decimals ?? 18,
    spot: feed?.latestSpot == null ? null : BigInt(feed.latestSpot),
    updatedAtMs: feed?.latestUpdatedAtMs == null ? null : BigInt(feed.latestUpdatedAtMs),
  };
}

/**
 * The strike for a "closes at or above its opening price" market: the index
 * price at the moment trading opened. Returns null when the series does not
 * reach back that far, so the chart can omit the rule rather than draw a
 * misleading one.
 */
export function strikeAt(series: IndexSeries, tradingStart: bigint): bigint | null {
  const atOrAfter = series.points.filter((p) => p.time >= tradingStart);
  if (atOrAfter.length === 0) return null;
  return atOrAfter[0].open;
}
