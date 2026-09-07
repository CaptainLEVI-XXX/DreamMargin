import { formatUnits, mulDivDown, mulDivUp, quantizeDown } from "./amounts";

/**
 * Bounded order-book walk.
 *
 * §6.1: buying YES consumes YES asks; buying NO consumes the opposite side,
 * represented by YES bids, where the NO price is `oneCollateral - yesPrice`.
 * Every price argument sent to the venue stays in the YES convention.
 *
 * The walk is bounded by what the book actually shows. Anything beyond that is
 * reported as a shortfall rather than assumed fillable, because the ask side on
 * this deployment holds only a handful of shares.
 */

export type BookLevel = {
  /** Always a YES price, in collateral native units. */
  yesPrice: bigint;
  /** Quantity resting at this level, in share native units. */
  quantity: bigint;
};

export type Side = "yes" | "no";

export type BookQuote = {
  /** Shares the book can actually fill at or better than the limit. */
  fillable: bigint;
  /** Shares requested that the book cannot cover. */
  shortfall: bigint;
  /** Collateral needed for the fillable part, rounded up. */
  cost: bigint;
  /** Worst YES price touched, for the venue limit argument. */
  limitYesPrice: bigint;
  /** Average price paid per share, for display. */
  averagePrice: bigint;
};

export type SaleQuote = {
  /** Shares the visible book can buy. */
  fillable: bigint;
  /** Shares that cannot be sold into visible bids. */
  shortfall: bigint;
  /** Collateral returned by the visible fill, rounded down. */
  proceeds: bigint;
  /** Worst YES-denominated price touched. */
  limitYesPrice: bigint;
  /** Average selected-outcome sale price. */
  averagePrice: bigint;
};

/**
 * Walk the book for a buy.
 *
 * Levels must be supplied best-first: ascending YES price for an ask walk,
 * descending for a bid walk. Quantities are quantized down to the lot so the
 * venue cannot reject the resulting order.
 */
export function quoteBuy(input: {
  side: Side;
  levels: readonly BookLevel[];
  quantity: bigint;
  oneCollateral: bigint;
  lotSize: bigint;
}): BookQuote {
  const wanted = quantizeDown(input.quantity, input.lotSize);
  let remaining = wanted;
  let cost = 0n;
  let worstYes = 0n;

  for (const level of input.levels) {
    if (remaining === 0n) break;

    const take = level.quantity < remaining ? level.quantity : remaining;
    if (take === 0n) continue;

    // The price actually paid depends on the side; the limit stays YES-denominated.
    const paid = input.side === "yes" ? level.yesPrice : input.oneCollateral - level.yesPrice;
    cost += mulDivUp(take, paid, input.oneCollateral);
    remaining -= take;
    worstYes = level.yesPrice;
  }

  const fillable = wanted - remaining;

  return {
    fillable,
    shortfall: remaining,
    cost,
    limitYesPrice: worstYes,
    averagePrice: fillable === 0n ? 0n : mulDivUp(cost, input.oneCollateral, fillable),
  };
}

/**
 * Walk the executable exit side for one outcome.
 *
 * Selling YES consumes YES bids. Selling NO consumes YES asks because the NO
 * price is their complement. Proceeds round down to match the conservative
 * amount the owner can actually receive.
 */
export function quoteSell(input: {
  side: Side;
  levels: readonly BookLevel[];
  quantity: bigint;
  oneCollateral: bigint;
  lotSize: bigint;
}): SaleQuote {
  const wanted = quantizeDown(input.quantity, input.lotSize);
  let remaining = wanted;
  let proceeds = 0n;
  let worstYes = 0n;

  for (const level of input.levels) {
    if (remaining === 0n) break;
    const take = level.quantity < remaining ? level.quantity : remaining;
    if (take === 0n) continue;

    const received = input.side === "yes" ? level.yesPrice : input.oneCollateral - level.yesPrice;
    proceeds += mulDivDown(take, received, input.oneCollateral);
    remaining -= take;
    worstYes = level.yesPrice;
  }

  const fillable = wanted - remaining;
  return {
    fillable,
    shortfall: remaining,
    proceeds,
    limitYesPrice: worstYes,
    averagePrice: fillable === 0n ? 0n : mulDivDown(proceeds, input.oneCollateral, fillable),
  };
}

export type AcquisitionPlan = {
  /** Shares to take from the book. */
  fromBook: bigint;
  /** Complete sets to mint for the remainder. */
  fromMint: bigint;
  /** Collateral for the book leg. */
  bookCost: bigint;
  /** Collateral for the mint leg: one whole unit per set. */
  mintCost: bigint;
  limitYesPrice: bigint;
  /** Why minting is involved, when it is. */
  note?: string;
};

/**
 * Decide how to acquire `quantity` shares of one side.
 *
 * The book comes first because it is cheaper: a share costs its market price
 * there, where minting a complete set always costs one whole unit of collateral
 * and hands back the opposite outcome as well. Minting only covers what the book
 * cannot, and the caller is told so explicitly.
 */
export function planAcquisition(input: {
  side: Side;
  levels: readonly BookLevel[];
  quantity: bigint;
  oneCollateral: bigint;
  lotSize: bigint;
  allowMint: boolean;
}): AcquisitionPlan {
  const quote = quoteBuy(input);

  if (quote.shortfall === 0n || !input.allowMint) {
    return {
      fromBook: quote.fillable,
      fromMint: 0n,
      bookCost: quote.cost,
      mintCost: 0n,
      limitYesPrice: quote.limitYesPrice,
    };
  }

  const other = input.side === "yes" ? "NO" : "YES";
  // Native units are meaningless in copy; format against one whole unit.
  const decimals = String(input.oneCollateral).length - 1;
  const shown = (v: bigint) => formatUnits(v, decimals, 2);
  const wanted = quote.fillable + quote.shortfall;

  return {
    fromBook: quote.fillable,
    fromMint: quote.shortfall,
    bookCost: quote.cost,
    // A complete set costs one whole collateral unit per share, whatever the
    // market price is.
    mintCost: mulDivUp(quote.shortfall, input.oneCollateral, input.oneCollateral),
    limitYesPrice: quote.limitYesPrice,
    note:
      quote.fillable === 0n
        ? `The order book has no ${input.side.toUpperCase()} for sale. Minting ${shown(quote.shortfall)} costs the full unit price and also gives you ${shown(quote.shortfall)} ${other} shares.`
        : `The book covers ${shown(quote.fillable)} of ${shown(wanted)}. Minting the remaining ${shown(quote.shortfall)} costs the full unit price and also gives you ${shown(quote.shortfall)} ${other} shares.`,
  };
}
