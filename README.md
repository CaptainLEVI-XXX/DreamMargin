# DreamMargin

DreamMargin is a monorepo that keeps the frontend app and on-chain smart contracts in one place.

## Repository structure

```text
DreamMargin/
├── client/               # Frontend app (React / Next / Vite etc.)
├── contracts/            # Foundry Solidity project
├── .gitignore            # Repo-wide ignore rules
├── README.md             # Project overview
└── .git                  # Root repository metadata only
```

## Why this layout?

- One Git repository tracks both the client and contracts together.
- Each project lives in its own folder to keep code isolated.
- The root repo is the single source of truth for commits and PRs.
- No nested Git repo should live under `contracts/`.

## Common commands

### Contracts

```bash
cd contracts
forge build
forge test
forge fmt
```

### Client

```bash
cd client
npm install
npm run dev
```

## Notes

- Keep the root repository as the only Git repo for the project.
- Add app-specific config in their own folder instead of mixing everything together.
- Use separate branches or labels for frontend and contract work when needed.
