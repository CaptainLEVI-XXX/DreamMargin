# Shannon fork-profile rehearsal

Generate the local rehearsal manifest without a private key, broadcast, or
testnet token balance:

```sh
FOUNDRY_PROFILE=fork forge script \
  script/RehearseShannonFork.s.sol:RehearseShannonFork -vv
```

The command writes `shannon-fork-rehearsal.json`. It first reads the real
pinned DreamDEX generation over historical RPC calls. It then deploys local
write-capable DreamDEX models and the real DreamMargin vault, oracle,
controller, and lifecycle facets. The smoke flow covers:

```text
bind dependencies -> assign roles -> register market -> mature marks
-> LP deposit -> position open -> partial repay -> close -> LP withdrawal
```

The manifest deliberately reports `provesLiveDreamDexWrites: false`. Real
DreamDEX identity, bytecode hashes, grid, expiry, backing, and top-of-book are
the source inputs; token funding and every state-changing venue call are local
models. This proves DreamMargin deployment and accounting without pretending
to prove live DreamDEX execution.

`script/verify-shannon.sh` is a future explorer-verification command template.
It is not run by this rehearsal because local EVM addresses do not exist on an
explorer.
