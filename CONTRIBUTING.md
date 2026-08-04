# Contributing to Worldloom

Thanks for helping improve the weave. Worldloom favors small, reviewable changes that
preserve its public-safety, persistence, accessibility, and deterministic-rendering
guarantees.

## Set up

Install the versions in `.tool-versions`, PostgreSQL 14 or newer, and Chromium for
Playwright. Then run:

```bash
mix setup
npm ci
npx playwright install chromium
```

Use deterministic, feed-free data while developing visual or interaction changes:

```bash
WORLDLOOM_FEEDS_ENABLED=false mix worldloom.seed_demo
WORLDLOOM_FEEDS_ENABLED=false mix phx.server
```

## Make a change

1. Open an issue for behavior or architecture that would materially change the public
   experience.
2. Keep each branch focused. Include a failing regression test before a behavior fix.
3. Preserve the persist-before-broadcast invariant and all documented bounds.
4. Keep upstream payloads, identities, IP addresses, cookies, cursors, and ETags out
   of HTML and logs.
5. Give pointer interactions equivalent keyboard and touch paths, and test reduced
   motion when animation changes.
6. Update public documentation when behavior, configuration, or data handling changes.

Elixir code is formatted with `mix format`. JavaScript is ESM and keeps geometry and
renderer state testable without a browser. Avoid pixel snapshots when deterministic
drawing-command assertions express the behavior more clearly.

## Run the gates

```bash
mix precommit
npm test
npm run test:e2e
```

The Playwright suite resets only its dedicated `worldloom_e2e` database. If your
change affects a production release, also run:

```bash
mix assets.deploy
MIX_ENV=prod mix release --overwrite
```

Production configuration requires the environment variables listed in
[docs/operations.md](docs/operations.md).

## Pull requests

Describe the user-visible outcome, the failure mode covered, and the commands you ran.
Screenshots or a short recording are welcome for visual changes, but do not include
credentials, terminal output, browser extensions, or personal data.

By contributing, you agree that your contribution is licensed under the repository's
[MIT License](LICENSE). Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md).
