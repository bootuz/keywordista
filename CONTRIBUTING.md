# Contributing to Keywordista

Thanks for opening Keywordista's source — issues and PRs are welcome.

## Quick start

```bash
git clone https://github.com/bootuz/keywordista.git
cd keywordista
make open-mac-app          # or: ./keywordista (headless, foreground)
```

The first build takes ~30s for Swift + ~1s for the SPA. Subsequent incremental builds are fast.

## Project layout

See the [README](README.md#project-layout). Briefly: the server is `Sources/App/`, the SPA is `web/`, the menubar app is `mac/`.

## Running the test suite

```bash
swift test                 # the 20-test Swift Testing suite
cd web && npm run check    # SPA type-check + Svelte sanity
cd mac && swift build      # menubar app
```

CI runs all three on every push and PR — see [`.github/workflows/ci.yml`](.github/workflows/ci.yml). A green CI is required before merging.

## What we welcome

- **Bug reports** with reproduction steps and (where possible) a `~/Library/Logs/Keywordista/service.{stdout,stderr}.log` snippet.
- **ASO scoring heuristic improvements.** The current `difficulty` / `entryBarrier` formulas in `Sources/App/Services/KeywordScorer.swift` are documented best-effort; sharper math with citations is great.
- **Test coverage.** Especially around `RefreshService` edge cases and the SPA's `reconcile()` polling loop.
- **macOS UX polish** in the menubar app — icon variants, About panel, login-item ergonomics.
- **Documentation fixes** — the README is the front door.

## What we're not chasing right now

- Multi-tenant / cloud-deployed variants. Keywordista is single-user, single-machine on purpose.
- Server-side rendering / SvelteKit. The dashboard is small enough that a vanilla Svelte SPA is the right tool.
- Database alternatives. SQLite is plenty for the scale; queue/storage swaps would be a much larger architectural shift, not a casual PR.

## Code style

- **Swift**: match the surrounding code. The server is structured around `protocol`-fronted services and Fluent repositories — controllers stay slim and call into them. Tests use Swift Testing with in-memory repo fakes (see `Tests/AppTests/Support/InMemoryRepositories.swift`).
- **TypeScript / Svelte**: strict mode is on. Run `npm run check` before pushing.
- **Comments**: explain *why*, not *what*. The existing code is comment-dense in places where the reasoning isn't obvious from the code alone (search for "Why" — that's the bar).

## Commit messages

Conventional Commits aren't required, but please:
- Keep the subject line under 72 chars and in imperative mood.
- Write a body when the change isn't self-explanatory.
- Avoid mentioning AI assistants in commit messages (see Anthropic's [usage guidance](https://docs.anthropic.com/en/release-notes/claude-code)).

## Pull request workflow

1. Open an issue first for anything bigger than a one-file change — saves both of us rework.
2. Branch from `main`, push, open a PR.
3. CI runs automatically. Fix anything red before requesting review.
4. Squash-merge is the default.

## License

By submitting a contribution, you agree it's licensed under [Apache 2.0](LICENSE) (the project's license).
