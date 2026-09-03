# Somnia Shannon deployment

The live workflow deploys DreamMargin against DreamDEX's current BTC and ETH
daily markets. Those pools are recyclable, so discovery pins the exact market
ID, pool, nonce, token IDs, venue, and expiry before governance registration.

Copy `.env.example` to the ignored `.env`, fund the derived wallet with at least
3 STT for the full contract suite and setup transactions, and run a
non-broadcasting deployment estimate first:

```sh
./script/setup-shannon.sh plan
```

The complete one-shot testnet setup is:

```sh
./script/setup-shannon.sh all
```

It performs this sequence:

```text
discover live BTC/ETH daily generations
-> deploy and bind facets, vault, oracle, and controller
-> schedule four exact outcome registrations
-> wait for delayed governance and execute them
-> record two permissionless oracle rounds
-> faucet tUSDC and deposit ERC-4626 liquidity
-> open, partially repay, and close one position per market
-> redeem all LP shares while the vault is debt-free
```

Each stage can also be run separately with `discover`, `deploy`, `schedule`,
`execute`, `observe`, `smoke`, or `verify`. Never rerun discovery between
`schedule` and `execute`: the selected JSON file is the exact governance
commitment. The `all` mode verifies contracts only when `VERIFY_CONTRACTS=1`.

Shannon's public RPC supports direct deployment and calls but does not expose
the state-proof methods required by a Foundry remote fork. The live shell entry
point therefore uses signed `forge create` and `cast send` transactions. It
writes `shannon-deployment-progress.json` after every component, verifies the
wallet nonce before resuming, and refuses to guess if any unrelated transaction
has changed that nonce.

Generated files are machine-readable:

- `shannon-selected-markets.json` records the two indexer selections.
- `shannon-deployment.json` records addresses, code hashes, roles, and encoded
  constructor arguments without the private key.
- `shannon-deployment-progress.json` makes a partial component deployment
  safely resumable without changing the predicted controller binding.
- `shannon-market-configuration.json` records all four registered generations.
- `shannon-oracle-observation.json` records ring cardinalities.
- `shannon-smoke.json` records actual position IDs and the debt-free vault exit.

## Fork rehearsal

The credential-free rehearsal remains available:

```sh
FOUNDRY_PROFILE=fork forge script \
  script/RehearseShannonFork.s.sol:RehearseShannonFork -vv
```

It reads the real pinned DreamDEX source but mirrors state-changing venue calls
locally, so its manifest deliberately reports `provesLiveDreamDexWrites: false`.
