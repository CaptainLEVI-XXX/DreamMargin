# DreamMargin

DreamMargin is an isolated leverage and credit layer for DreamDEX binary event
markets on Somnia. Traders use tUSDC and vault credit to acquire a larger YES
or NO position, while liquidity providers supply the collateral that funds the
credit.

The protocol does not create a separate synthetic market or decide the result
of an event. Trading, outcome tokens, market expiry, and resolution remain on
DreamDEX. DreamMargin adds bounded borrowing, position accounting, risk checks,
liquidation, and lender accounting around those existing markets.

The current deployment is an experimental Shannon testnet release. Its tUSDC,
markets, prices, and returns have no mainnet value. The contracts have not been
approved for production deposits.

## What the Product Does

A DreamDEX binary market has two outcome shares: YES and NO. Under normal
resolution, a winning share is redeemable through DreamDEX for one unit of the
market collateral and a losing share is worth zero; DreamDEX applies the
market's configured policy if the event is void. Before resolution, either
share can be traded through the market's order book.

DreamMargin lets a trader take one exact outcome and market generation as
collateral for an isolated loan. The borrowed tUSDC is used immediately to buy
more of that same outcome. The acquired shares stay in controller custody and
secure only that position's debt.

Isolation is important: one position does not borrow against another position,
the trader's whole wallet, or a portfolio-level health balance. Each position
has its own outcome shares, debt, market identity, health checks, and settlement
path.

Liquidity providers deposit tUSDC into the DreamMargin vault. The vault lends
only through the bound controller and records each loan as a receivable.
Financing charged on outstanding debt increases vault assets, while realized
losses reduce them.

## How Leverage Is Created

The primary opening path is `openFromCollateral`. The trader chooses the market,
YES or NO, a final share quantity, and a leverage tier. The controller then:

1. verifies the exact DreamDEX market, pool nonce, outcome token, outcome ID,
   collateral token, and registered risk policy;
2. refreshes the oracle when a new observation is due and obtains a mature,
   non-stale conservative mark;
3. calculates how much of the bounded purchase cost may come from vault debt
   and how much must come from the trader;
4. pulls only the required trader tUSDC and borrows the bounded remainder from
   the vault;
5. submits a fill-or-kill DreamDEX order for the exact requested shares;
6. returns unused borrowing, refunds unused trader collateral, and records only
   actual token and debt deltas; and
7. checks the completed position against leverage, loan-to-value, depth, market,
   utilization, and global exposure limits.

The transaction either opens the complete bounded position or reverts. A
partial order cannot leave the trader with an unintended leveraged position.

The resulting leverage is economic exposure divided by the trader's remaining
equity. For example, a 2x position targets roughly twice the conservative
outcome exposure of the trader-funded equity, subject to the actual execution
price and every configured risk cap. It is not a promise that any requested
size can be borrowed: available vault cash, certified exit depth, price limits,
and health checks can all reduce or reject the trade.

An additional `openPosition` path accepts outcome shares the trader already
owns as initial collateral, then borrows and buys more of the same outcome. The
client's default flow uses `openFromCollateral` so a trader can open directly
from tUSDC without manually buying and approving outcome shares first.

## Position Lifecycle

Debt is represented by debt shares against a global interest index. The amount
owed therefore increases with the configured financing rate. Conversions round
conservatively so the vault does not lose receivables through integer rounding.

An active position supports the following operations:

- **Add collateral:** transfer more of the position's exact YES or NO outcome
  ID into controller custody. A different outcome, pool generation, or token
  cannot be substituted.
- **Repay:** pay tUSDC to reduce debt without selling position shares. Anyone
  may repay, although the client uses the connected wallet.
- **Withdraw collateral:** remove debt-free or demonstrably excess outcome
  shares when the remaining position still passes its health checks.
- **Deleverage:** sell a bounded quantity of the held outcome through DreamDEX
  and apply the actual collateral proceeds to debt before returning any surplus
  to the owner.
- **Close into outcome:** repay all remaining debt and withdraw the remaining
  YES or NO shares.
- **Close into collateral:** sell the full outcome position, repay debt first,
  and return only the residual tUSDC.

The client calculates a debt-clearing deleverage size from current executable
book depth. It uses a fill-or-kill order and a short-lived price bound so a
fixed percentage sale cannot leave an invalid debt remainder.

If a position becomes unhealthy, liquidation can repay debt in exchange for
outcome collateral or sell collateral through DreamDEX. Liquidation is bounded
by the configured incentive, execution limits, and the position's actual
collateral. It is a recovery mechanism, not a guarantee that the vault cannot
lose money.

## Resolution and Loss Allocation

DreamDEX remains the source of market truth and resolves the event. Once the
outcome is terminal, DreamMargin redeems the position through the configured
DreamDEX integration and applies recovered collateral in a fixed order:

1. collectible debt is repaid;
2. genuine surplus is returned to the position owner;
3. attributable protocol fees are waived before funded protection is used;
4. the locked reserve absorbs the next part of a shortfall; and
5. any remaining shortfall becomes realized bad debt in the vault.

This ordering prevents owner value from being paid ahead of debt and prevents a
loss from being counted more than once. It also makes the LP risk explicit:
vault depositors earn financing when loans perform, but their share value can
fall when recovery and the reserve do not cover borrower losses.

## The Liquidity Vault

`DreamMarginVault` is ERC-4626 compatible. Depositors receive transferable
vault shares representing a claim on vault cash plus performing controller
receivables. Virtual assets and virtual shares protect the initial exchange
rate from first-deposit inflation attacks.

Withdrawals are cash limited. A depositor may withdraw only the smaller of the
assets represented by their shares and the vault's immediately available cash.
Liquidity currently lent to positions remains part of `totalAssets`, but it
cannot be withdrawn until borrowers repay or positions settle. DreamMargin
therefore offers exit whenever economically available; it does not promise
unconditional instant redemption while the same cash is actively borrowed.

The protocol reserve is separate from ordinary redeemable LP shares. It cannot
be removed as if it were free operating cash. Reserve withdrawal requires the
protocol to be paused, debt free, and to pass the configured delayed governance
process.

## Risk Controls

DreamMargin treats a quoted market price and a safe lending value as different
things. Position health uses a conservative mark constrained by retained oracle
observations and executable recovery routes. A favorable last trade cannot by
itself create extra borrowing capacity.

Opening is constrained by:

- exact market-generation identity, including the current pool nonce and
  outcome ID;
- approved creator, venue, operator, collateral, and minimum market duration;
- oracle maturity and freshness;
- opening and reduction cutoffs before expiry;
- maximum leverage and maintenance loan-to-value;
- certified executable depth and per-position exposure;
- per-outcome, per-market, global, utilization, and available-cash caps; and
- lot size, tick size, price, quantity, deadline, and fill requirements.

The controller can enter more restrictive operating modes without blocking
risk-reducing repayment. Governance changes use committed identifiers and a
delay, while emergency restrictions can be applied immediately. Persistent
state uses ERC-7201 namespaces, token movement is reconciled from actual balance
deltas, and external lifecycle calls use a transient reentrancy guard.

These controls reduce risk; they do not remove market, liquidity, oracle,
smart-contract, or collateral risk.

## Oracle Operation Without a Backend

The dedicated Shannon markets do not require a DreamMargin keeper server.
Somnia Reactivity subscribes to the configured DreamDEX pools and calls the
reactive observer when those pools change. Normal market activity therefore
feeds the retained oracle observations.

Opening also refreshes an observation when one is due. If a quiet market has no
recent activity, the protocol reports the mark as stale instead of treating old
data as current. The oracle's `observe` function is permissionless, so the
client can offer a refresh transaction without relying on a privileged backend.

## Current Shannon Deployment

The frontend is bound to dedicated long-lived BTC and ETH DreamDEX markets on
Somnia Shannon. Both markets expire on 19 October 2026 and have seeded two-sided
test liquidity. Deployment addresses, exact market generations, policy IDs,
and transaction provenance are machine readable in the
[`Shannon frontend manifest`](contracts/deployments/shannon-frontend.json).

The repository also contains reproducible deployment, market creation,
liquidity seeding, oracle bootstrap, and smoke-test scripts under
[`contracts/script/`](contracts/script/). Never commit a deployment private key
or RPC credential.

## Repository Contents

- [`client/`](client/) contains the React and Vite application. It reads public
  chain state directly, builds bounded transaction intents, simulates writes
  before signing, and does not require a DreamMargin application backend.
- [`contracts/`](contracts/) contains the Foundry project, DreamDEX adapter,
  controller lifecycle modules, ERC-4626 vault, oracle, tests, and deployment
  scripts.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) defines repository-wide development,
  testing, security, and commit requirements.

## Run the Client

Install the client dependencies and start the local application:

```sh
cd client
npm install
npm run dev
```

The wallet must be connected to Somnia Shannon, chain ID `50312`. Contract and
market bindings are generated from the tracked deployment manifests. Regenerate
them after an ABI change or redeployment rather than editing them by hand:

```sh
cd client
npm run generate
```

Before contributing a client change, run:

```sh
npm run format
npm run typecheck
npm run lint
npm test -- --run
npm run build
```

## Build and Test the Contracts

Initialize the pinned dependencies from the repository root, then run the local
contract checks:

```sh
git submodule update --init --recursive
cd contracts
forge fmt --check
forge build --sizes
forge lint
forge test
FOUNDRY_PROFILE=full forge test -vvv
forge snapshot --check
```

The deterministic suite does not require a public RPC. Deployed DreamDEX
integration tests use the separate fork profile:

```sh
FOUNDRY_PROFILE=fork forge test -vv
```

The contract toolchain is pinned to Foundry `1.8.1`, Solidity `0.8.34`, the
Prague EVM target, optimizer runs `200`, and `via_ir = true`. See
[`contracts/README.md`](contracts/README.md) for deployment-specific commands
and [`client/README.md`](client/README.md) for frontend conventions.

## Contributing and Security

Enable the repository hooks once per clone:

```sh
git config core.hooksPath .githooks
```

Keep each commit single-author, focused, formatted, and independently tested.
Do not bypass hooks. Follow [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a
pull request.

Do not report suspected vulnerabilities in a public issue. Contact the
maintainers privately with a minimal reproduction and, when possible, a failing
test.
