# Contributing to DreamMargin

Thank you for contributing to DreamMargin. This repository contains a frontend
application and security-sensitive smart contracts. Contributions should be
small, well tested, and easy to review. A reviewer should be able to hold the
whole change in their head.

## Scope

This file applies to the entire repository. More specific contribution guides
may be added inside a component directory; when they are, follow both documents
and let the closest guide govern component-specific details.

```text
DreamMargin/
├── client/       frontend application
└── contracts/    Foundry smart-contract project
```

Keep the root repository as the only Git repository. Do not create nested Git
repositories inside `client/` or `contracts/`.

## Code of Conduct

Be respectful, constructive, and professional. Focus feedback on the work, not
the person. Harassment, personal attacks, and abusive behaviour are not
acceptable.

## Getting Started

1. Fork the repository.
2. Create a focused branch from the latest `main`.
3. Install the tools required by the component you are changing.
4. Make one logical change at a time.
5. Run the relevant formatting, build, and test commands before opening a pull
   request.

Install Foundry for contract work by following the
[official installation guide](https://book.getfoundry.sh/getting-started/installation).
Then run:

```sh
cd contracts
forge fmt --check
forge build
forge test
```

If the project defines `full` or `fork` profiles, also run the relevant suites:

```sh
cd contracts
FOUNDRY_PROFILE=full forge test
FOUNDRY_PROFILE=fork forge test -vv
```

Fork tests should use pinned deployments and should not make normal unit, fuzz,
or invariant runs depend on external infrastructure. A public RPC may be the
default; use an environment variable such as `MAINNET_RPC_URL` to override it
for local reliability. Never commit provider credentials or private keys.

For frontend work, use the package manager selected by the lockfile in
`client/`. Run the formatter, linter, type checker, tests, and production build
provided by `client/package.json` before requesting review.

## Branch Naming

Use a short Conventional Commit type followed by a descriptive kebab-case
name:

```text
feat/position-risk-library
fix/debt-share-rounding
test/dreammargin-invariants
docs/contribution-guide
refactor/fee-accrual
```

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(optional-scope): <imperative summary>

optional body

optional footer
```

Allowed types are `feat`, `fix`, `test`, `docs`, `refactor`, `perf`, `chore`,
`audit`, and `ci`.

- Keep the summary under 72 characters, use imperative mood, and omit the
  trailing period.
- Add a body only when the summary cannot carry the necessary context. Wrap it
  at 72 characters.
- Describe the change. Put detailed design rationale in the pull request or
  code documentation.
- Never reference untracked notes, local documents, or inaccessible codebases.
  Every reference must be understandable from a clone of the repository.
- Leave a blank line between the summary, body, and footer.
- Keep commits single-author. Do not add `Co-Authored-By`, `Signed-off-by`, or
  other co-author trailers.
- Do not use `git commit --author` or bypass repository hooks with
  `--no-verify`.
- Keep one logical change in each commit. If a summary needs “and,” split the
  commit.
- A commit should change one production responsibility and its direct tests.
  Do not combine two lifecycle modules, repository setup with protocol logic,
  or an unrelated refactor with a feature.
- Keep the reviewable commit sequence when pushing a branch. Do not squash a
  multi-phase implementation into one large commit.
- Every commit must format, compile, and pass its relevant local tests on its
  own. Put large generated fixtures in an isolated test-only commit with their
  generator and provenance.

Examples:

```text
feat(position): add atomic leveraged opening
fix(vault): round debt-share conversions upward
test(invariant): fuzz debt and collateral conservation
audit(oracle): reject recycled DreamDEX pool generations
```

Repository hooks are part of the contribution policy. If a hook reports a
failure, fix the code or message. If a hook itself is wrong, correct it in a
separate, reviewable commit.

## Repository Layout

Keep component code inside its component directory. Shared repository files,
such as this guide and root-level automation, belong at the root.

The contract project is organised by kind, one meaningful level deep:

```text
contracts/
├── src/
│   ├── dreammargin/
│   │   ├── DreamMarginController.sol
│   │   └── base/
│   │       ├── PositionOpen.sol
│   │       ├── PositionClose.sol
│   │       ├── PositionLiquidation.sol
│   │       └── PositionSettlement.sol
│   ├── vault/
│   │   └── DreamMarginVault.sol
│   ├── oracle/
│   │   └── DreamDexMarkOracle.sol
│   ├── adapters/
│   │   └── DreamDexAdapter.sol
│   ├── interfaces/
│   │   ├── dreammargin/
│   │   └── integrations/
│   └── libs/
│       └── dreammargin/
├── test/
│   ├── dreammargin/
│   ├── vault/
│   ├── libs/
│   ├── fork/
│   ├── invariant/
│   ├── audit/
│   ├── mock/
│   ├── reference/
│   └── poc/
└── script/
```

Do not add a directory that only wraps one other directory. If a second product
is introduced, give it a parallel directory under each relevant kind.

For DreamMargin contract code, use the first matching location:

| Question | Location |
|---|---|
| A constant? | `contracts/src/libs/dreammargin/LibDreamMarginConstants.sol` |
| A reason to revert? | `contracts/src/libs/dreammargin/LibDreamMarginErrors.sol` |
| Controller, vault, or oracle state? | Its namespaced storage library under `contracts/src/libs/dreammargin/` |
| Pure position-risk logic? | `contracts/src/libs/dreammargin/LibPositionRisk.sol` |
| A DreamDEX ABI? | `contracts/src/interfaces/integrations/` |
| Venue-specific execution? | `contracts/src/adapters/DreamDexAdapter.sol` |
| Owns a lifecycle slice? | `contracts/src/dreammargin/base/*.sol` |
| An external controller entrypoint? | `contracts/src/dreammargin/DreamMarginController.sol` |

Contract dependencies should flow in this order:

```text
constants -> errors -> storage -> pure libraries -> interfaces
          -> adapters/oracles/vault -> lifecycle modules -> facade
```

## Solidity Conventions

### Style and Documentation

- Use two-space indentation and apply `forge fmt`.
- Open every Solidity file with `@title`, `@author`, and `@notice`; add `@dev`
  where rationale or safety context is useful.
- Put `@notice` on every declaration and `@param`/`@return` on every function,
  including internal functions. Document struct fields with `@param` at the
  struct level.
- State units and rounding direction in documentation.
- Use ASCII banner dividers between logical sections in longer files.

### Imports

- Import external dependencies through remappings, for example
  `solady/utils/FixedPointMathLib.sol`.
- Import internal code through full project paths, for example
  `src/libs/dreammargin/LibDreamMarginStorage.sol`.
- Do not use relative or wildcard imports.
- Separate mixins, interfaces, libraries, and external dependencies with blank
  lines.

### Storage

All persistent controller state must live in one ERC-7201 namespaced struct,
declared in the appropriate storage library and reached through its accessor.
Mixins must not declare state variables. Declare the storage-slot constant at
file level in the constants library and document both its derivation and value.

### Errors

Declare custom errors in the product's error library, revert with them directly,
and include the offending value:

```solidity
revert LibDreamMarginErrors.UnsupportedMarket(marketId, pool, nonce);
```

Do not add an assembly-based custom-revert wrapper when the configured build
produces equivalent output without it.

### Libraries

Use `Lib` as a prefix. Library functions take their subject as the first
parameter named `self`, may accept storage references, and must not declare
persistent state.

### Assembly

Assembly is allowed for storage-slot access, bit-packing, and calldata handling,
but not as a replacement for Solidity 0.8 checked arithmetic. Every block must:

- use `assembly ("memory-safe")`;
- have an adjacent `@dev` comment documenting the layout and numbered
  implementation steps; and
- identify every skipped check in a capitalised `Safety Considerations:` block
  so reviewers can verify that the caller performs it.

### Low-Level Mathematics

Prefer audited dependency primitives, such as Solady, over custom low-level
math. Know the input domain and rounding behaviour of every primitive and prove
that protocol state remains within it. Treat silent saturation or underflow as
a security issue, not merely a numerical edge case.

For example, `expWad` returns zero below its supported lower range. Code using
it must enforce a bound that prevents protocol state from entering that range.

## Testing Requirements

A pull request that changes behaviour is not reviewable without tests.

- Give pure math libraries differential tests against an independent reference
  implementation. Do not rely only on hand-computed constants.
- Give every protocol invariant a Foundry invariant test named for its
  identifier, such as `invariant_DM_I3_noNakedDebt` or
  `invariant_DM_I10_vaultAssetsReconcile`.
- Give every bug fix a permanent regression test in `contracts/test/audit/`,
  named for the behaviour it protects, such as
  `test_recycledPoolCannotMutatePosition`. Do not delete regression tests
  after the fix.
- Put resolved vulnerability reproductions in `contracts/test/poc/`.
- Keep local integration models in `contracts/test/mock/` and deployed-network
  integration tests in `contracts/test/fork/`.
- Commit gas snapshots when execution paths change and explain material gas
  regressions.
- Test revert paths, boundary values, rounding behaviour, access control, and
  adversarial call sequences—not only the happy path.

Invariant suites may be too slow for a normal pre-push hook, but they must run
before a pull request is opened.

## Pull Requests

Keep pull requests focused. Separate unrelated contract, frontend, refactoring,
and formatting changes. A good description explains why the change is needed,
identifies its risk, and describes how it was verified.

Before opening a pull request, confirm:

- [ ] The branch is current with `main` and contains one focused change.
- [ ] Relevant formatters, linters, builds, and tests pass.
- [ ] `forge build` is clean and introduces no warnings.
- [ ] The full Foundry suite, including invariants, passes when configured.
- [ ] Gas snapshots are updated when execution paths change.
- [ ] New code follows the repository layout.
- [ ] No contract state variables exist outside the namespaced storage library.
- [ ] Custom errors are namespaced and carry offending values.
- [ ] Assembly is documented, memory-safe, and justified.
- [ ] Behaviour changes and bug fixes have the required tests.
- [ ] The description explains why; the diff already shows what changed.
- [ ] No hook was bypassed with `--no-verify`.
- [ ] No credentials, private keys, generated secrets, or local environment
      files are included.

Call out security-relevant changes explicitly. Name the invariant the change
preserves or intentionally modifies, and explain any trust-boundary or storage
layout impact.

## Reporting Vulnerabilities

Do not open a public issue for a suspected vulnerability. Report it privately
to the maintainers with a minimal reproduction and, when possible, a failing
test. After the issue is resolved and disclosure is approved, preserve the
reproduction in `contracts/test/poc/`.
