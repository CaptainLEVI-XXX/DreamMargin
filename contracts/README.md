# DreamMargin Contracts

DreamMargin is an isolated credit layer for DreamDEX binary Event Contracts on
Somnia. The contracts let a trader custody one exact outcome-token generation,
borrow bounded vault liquidity, and atomically acquire more of that outcome.

The current release target is the Shannon testnet. It is experimental and is
not approved for production deposits.

## Toolchain

The repository pins:

- Foundry `1.8.1`;
- Solidity `0.8.34`;
- the Prague EVM target;
- optimizer runs `200` with `via_ir = true`;
- forge-std `1.16.2`; and
- Solady `0.1.26`.

Initialize dependencies from the repository root:

```sh
git submodule update --init --recursive
```

Install and verify the expected Foundry release:

```sh
foundryup -v 1.8.1
forge --version
```

## Local Verification

The contract project has no CI/CD pipeline. Contributors run verification
locally:

```sh
cd contracts
forge fmt --check
forge build --sizes
forge lint
forge test
FOUNDRY_PROFILE=full forge test -vvv
forge snapshot --check
```

The deterministic local suite never depends on a public RPC. Run deployed
DreamDEX integration tests separately:

```sh
FOUNDRY_PROFILE=fork forge test -vv
```

The public Shannon RPC is the default. Override it locally when necessary; do
not commit provider credentials or deployment keys.

## Shannon Frontend Deployment

The integration target is two dedicated DreamDEX markets, BTC and ETH, both
expiring on 19 October 2026. Each has a static 0.45/0.55 two-sided bootstrap
book, and the DreamMargin vault retains 500 tUSDC of immediately available
liquidity. The complete machine-readable address and generation map is:

```text
deployments/shannon-frontend.json
```

The deployment does not require a backend keeper. Somnia native Reactivity
subscribes directly to each pool and invokes `DreamMarginReactiveObserver` when
that pool changes. A user's normal DreamDEX trade therefore refreshes both
outcome marks before the subsequent leverage transaction. Quiet books are
allowed to become stale rather than pretending an old value is current; the
frontend should detect `generationState().ring.newestTimestamp + staleAfter`
and expose a permissionless `observe(generationKey)` refresh if the user already
holds shares and has not just traded.

The reproducible one-time setup is:

```sh
./script/deploy-demo-markets.sh create
./script/deploy-demo-markets.sh schedule
./script/deploy-demo-markets.sh execute
./script/seed-demo-markets.sh
./script/setup-demo-reactivity.sh
./script/bootstrap-demo-oracle.sh
```

Run the complete live lifecycle check against the dedicated markets with:

```sh
SELECTION=deployments/shannon-demo-selected-markets.json \
CONFIGURATION=deployments/shannon-demo-markets.json \
SMOKE_OUTPUT=deployments/shannon-demo-smoke.json \
./script/smoke-shannon.sh
```

That check has exercised deposit, outcome funding, leveraged open, partial
repayment, full close, debt-free accounting, and synchronous LP redemption on
both markets. `seed-demo-markets.sh` is idempotent and restores the retained
frontend vault target without duplicating an existing two-sided book.

Reusable series policies remain available for future products. They remove
per-roll governance, but a newly rolled generation must still be activated
permissionlessly and its oracle window bootstrapped before leverage opens.

## Repository Layout

```text
src/
  dreammargin/          controller facade and lifecycle modules
  vault/                isolated lender accounting
  oracle/               bounded DreamDEX mark observations
  adapters/             venue-specific execution
  interfaces/           protocol and integration interfaces
  libs/dreammargin/     constants, errors, storage, and risk math
test/
  dreammargin/          controller and lifecycle behavior
  vault/                lender accounting
  libs/                 pure and storage libraries
  audit/                permanent security regressions
  fork/                 pinned deployed integrations
  invariant/            stateful protocol properties
  mock/                 adversarial local integrations
  reference/            independent differential fixtures
script/                 deployment and rehearsal scripts
```

Use full internal import paths, two-space indentation, ERC-7201 namespaced
storage, and direct namespaced custom errors. Every production change includes
its direct unit and fuzz tests. Security properties receive numbered stateful
invariants, and every fixed bug receives a permanent regression test.

## Contribution Rules

Enable the local hooks once per clone:

```sh
git config core.hooksPath .githooks
```

Keep commits single-author and independently buildable. One commit changes one
production responsibility and its direct tests; do not squash a reviewable
implementation sequence into one large commit.
