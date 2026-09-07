import { mulDivDown, mulDivUp, quantizeDown } from "./amounts";
import { quoteBuy, type BookLevel, type Side } from "./bookQuote";
import { effectiveLeverageBps } from "./leverageTiers";

const BPS = 10_000n;

export type PayFirstQuote = {
  shares: bigint;
  entryCost: bigint;
  walletPayment: bigint;
  riskLeverageBps: bigint;
  effectiveLeverageBps: bigint;
  maximumCost: bigint;
  maximumWalletSpend: bigint;
  targetDebt: bigint;
  blocked?: string;
};

type Input = {
  side: Side;
  levels: readonly BookLevel[];
  walletBudget: bigint;
  /** Cash-on-cash leverage. Omit to use the contract's maximum risk setting. */
  targetLeverageBps?: bigint;
  maxRiskLeverageBps: bigint;
  riskMark: bigint;
  oneCollateral: bigint;
  lotSize: bigint;
  maximumShares: bigint;
  /** Headroom used by the write when its in-transaction oracle refresh changes the mark. */
  authorizationBufferBps: bigint;
};

type Candidate = Omit<PayFirstQuote, "riskLeverageBps" | "effectiveLeverageBps" | "blocked">;

function empty(blocked: string): PayFirstQuote {
  return {
    shares: 0n,
    entryCost: 0n,
    walletPayment: 0n,
    riskLeverageBps: BPS,
    effectiveLeverageBps: BPS,
    maximumCost: 0n,
    maximumWalletSpend: 0n,
    targetDebt: 0n,
    blocked,
  };
}

function availableShares(input: Input): bigint {
  const depth = input.levels.reduce((total, level) => total + level.quantity, 0n);
  return quantizeDown(depth < input.maximumShares ? depth : input.maximumShares, input.lotSize);
}

function costAt(input: Input, shares: bigint) {
  return quoteBuy({
    side: input.side,
    levels: input.levels,
    quantity: shares,
    oneCollateral: input.oneCollateral,
    lotSize: input.lotSize,
  });
}

function riskCandidate(input: Input, shares: bigint, riskLeverageBps: bigint): Candidate {
  const book = costAt(input, shares);
  const sidePrice =
    input.side === "yes" ? book.limitYesPrice : input.oneCollateral - book.limitYesPrice;
  const maximumCost = mulDivUp(shares, sidePrice, input.oneCollateral);
  const grossValue = mulDivDown(shares, input.riskMark, input.oneCollateral);
  const valueEquity = mulDivUp(grossValue, BPS, riskLeverageBps);
  const costEquity = mulDivUp(maximumCost, BPS, riskLeverageBps);
  const valueDebt = grossValue > valueEquity ? grossValue - valueEquity : 0n;
  const costDebt = maximumCost > costEquity ? maximumCost - costEquity : 0n;
  const targetDebt = valueDebt < costDebt ? valueDebt : costDebt;
  const unusedAtQuotedBook = maximumCost - book.cost;
  const finalDebt = targetDebt > unusedAtQuotedBook ? targetDebt - unusedAtQuotedBook : 0n;
  const walletPayment = book.cost - finalDebt;
  const ownerAssetsRequired = maximumCost - targetDebt;
  const authorizationBuffer = mulDivUp(maximumCost, input.authorizationBufferBps, BPS);
  const maximumWalletSpend =
    ownerAssetsRequired + authorizationBuffer < maximumCost
      ? ownerAssetsRequired + authorizationBuffer
      : maximumCost;

  return {
    shares,
    entryCost: book.cost,
    walletPayment,
    maximumCost,
    maximumWalletSpend,
    targetDebt,
  };
}

function largestQuantity(input: Input, accepts: (shares: bigint) => boolean): bigint {
  let low = 0n;
  let high = availableShares(input) / input.lotSize;

  while (low < high) {
    const middle = (low + high + 1n) / 2n;
    if (accepts(middle * input.lotSize)) low = middle;
    else high = middle - 1n;
  }

  return low * input.lotSize;
}

function riskForWalletLimit(input: Input, shares: bigint, walletLimit: bigint): bigint | null {
  const maximum = riskCandidate(input, shares, input.maxRiskLeverageBps);
  const debtNeeded = maximum.maximumCost > walletLimit ? maximum.maximumCost - walletLimit : 0n;
  if (debtNeeded === 0n) return BPS;
  if (maximum.targetDebt < debtNeeded) return null;

  let low = BPS + 1n;
  let high = input.maxRiskLeverageBps;
  while (low < high) {
    const middle = (low + high) / 2n;
    if (riskCandidate(input, shares, middle).targetDebt >= debtNeeded) high = middle;
    else low = middle + 1n;
  }
  return low;
}

/**
 * Converts a wallet budget and a user-facing leverage target into the exact
 * share quantity and conservative leverage value accepted by the controller.
 */
export function quotePayFirst(input: Input): PayFirstQuote {
  if (input.walletBudget === 0n) return empty("Enter an amount to continue");
  if (input.levels.length === 0) return empty("The order book has no liquidity on this side");

  if (input.targetLeverageBps === BPS || input.maxRiskLeverageBps <= BPS) {
    const shares = largestQuantity(
      input,
      (quantity) => costAt(input, quantity).cost <= input.walletBudget,
    );
    if (shares === 0n) return empty("The amount is below the market's minimum order");
    const book = costAt(input, shares);
    return {
      shares,
      entryCost: book.cost,
      walletPayment: book.cost,
      riskLeverageBps: BPS,
      effectiveLeverageBps: BPS,
      maximumCost: book.cost,
      maximumWalletSpend: book.cost,
      targetDebt: 0n,
    };
  }

  if (input.targetLeverageBps === undefined) {
    const shares = largestQuantity(input, (quantity) => {
      const candidate = riskCandidate(input, quantity, input.maxRiskLeverageBps);
      return candidate.maximumWalletSpend <= input.walletBudget;
    });
    if (shares === 0n) return empty("The amount is below the market's minimum order");
    const candidate = riskCandidate(input, shares, input.maxRiskLeverageBps);
    return {
      ...candidate,
      riskLeverageBps: input.maxRiskLeverageBps,
      effectiveLeverageBps: effectiveLeverageBps(candidate.entryCost, candidate.walletPayment),
    };
  }

  const targetLeverageBps = input.targetLeverageBps;
  const candidateForTarget = (quantity: bigint) => {
    const entryCost = costAt(input, quantity).cost;
    const targetWalletPayment = mulDivDown(entryCost, BPS, targetLeverageBps);
    const riskLeverageBps = riskForWalletLimit(input, quantity, targetWalletPayment);
    if (riskLeverageBps === null) return null;
    return { candidate: riskCandidate(input, quantity, riskLeverageBps), riskLeverageBps };
  };
  const shares = largestQuantity(input, (quantity) => {
    const quoted = candidateForTarget(quantity);
    return quoted !== null && quoted.candidate.maximumWalletSpend <= input.walletBudget;
  });
  if (shares === 0n) {
    if (availableShares(input) >= input.lotSize && candidateForTarget(input.lotSize) === null) {
      return empty("This leverage is not available at the current price and risk mark");
    }
    return empty("The amount is below the market's minimum order");
  }

  const quoted = candidateForTarget(shares);
  if (quoted === null) {
    return empty("This leverage is not available at the current price and risk mark");
  }
  return {
    ...quoted.candidate,
    riskLeverageBps: quoted.riskLeverageBps,
    effectiveLeverageBps: effectiveLeverageBps(
      quoted.candidate.entryCost,
      quoted.candidate.walletPayment,
    ),
  };
}
