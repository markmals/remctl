# Releasing RemCTL

Every version bump should produce a git tag, a GitHub Release on `markmals/remctl`,
and a fresh Homebrew bottle in `markmals/homebrew-tap`. This is automated.

## The pipeline

```text
bump remctlVersion → push → tag vX.Y.Z          (you)
        │
        ▼
.github/workflows/release.yml  (source repo)
   • verifies the tag matches remctlVersion
   • creates the GitHub Release
   • computes the source-tarball sha256
   • opens a bottle-bump PR on markmals/homebrew-tap
        │
        ▼
tap .github/workflows/tests.yml  (brew test-bot)
   • builds bottles on macos-15 (Sequoia) + macos-26 (Tahoe)
        │
        ▼   add the `pr-pull` label to the green PR     (you, one click)
        │
        ▼
tap .github/workflows/publish.yml  (brew pr-pull)
   • uploads bottles to the tap release remctl-X.Y.Z
   • commits the updated formula (new version + bottle block) to tap main
        │
        ▼
brew update && brew upgrade remctl  →  pours the new bottle
```

Bottles are built by Homebrew's own `brew test-bot` + `brew pr-pull` — the same
machinery `homebrew/core` uses — so the formula's bottle DSL, `rebuild` counter,
`root_url`, and cellar are handled correctly.

## One-time setup: the tap token

The source repo opens a PR on the tap, and the tap's bottle CI must run on that PR.
The default `GITHUB_TOKEN` cannot do either (it is scoped to one repo, and events
it triggers do not start new workflow runs). So `release.yml` needs a Personal
Access Token with write access to the tap, stored as a secret.

1. Create a **fine-grained PAT**: GitHub → Settings → Developer settings →
   Fine-grained tokens → Generate new token.
   - **Resource owner:** `markmals`
   - **Repository access:** Only select repositories → `markmals/homebrew-tap`
   - **Repository permissions:** **Contents: Read and write**, **Pull requests:
     Read and write**
   - (A classic PAT with the `repo` scope also works but is broader.)
2. Add it to the source repo: `markmals/remctl` → Settings → Secrets and variables
   → Actions → New repository secret.
   - **Name:** `HOMEBREW_TAP_TOKEN`
   - **Value:** the token from step 1
3. Set a calendar reminder to rotate it before it expires (fine-grained tokens
   expire; max 1 year). When it expires, `release.yml`'s last step fails with a
   clear "Missing secret" / auth error — regenerate and update the secret.

## Cutting a release

1. **Bump the version in code.** Edit `remctlVersion` in
   `Sources/RemindersControl/GlobalOptions.swift` (e.g. `"0.1.0"` → `"0.2.0"`),
   commit, and push to `main`. Wait for CI to pass.

2. **Tag the release.** Either:

   - **From the Actions UI (recommended, no remote confusion):** open the
     **Release** workflow on `markmals/remctl`, click **Run workflow**, and enter
     the version (e.g. `0.2.0`). It creates and pushes the tag for you.

   - **From the command line:** push the tag to the fork remote. In this clone
     `origin` is the fork `markmals/remctl` and `upstream` is `viticci/remctl`
     (**never push to `upstream`**):

     ```bash
     git tag v0.2.0
     git push origin v0.2.0   # origin = markmals/remctl; upstream = viticci (do not push)
     ```

   Either way, `release.yml` verifies the version matches `remctlVersion` (it
   fails fast if you forgot step 1), creates the GitHub Release, and opens the
   bottle-bump PR on the tap.

3. **Publish the bottles.** When the tap PR's `brew test-bot` check is green, add
   the **`pr-pull`** label to that PR. `publish.yml` uploads the bottles to the
   `remctl-X.Y.Z` release and commits the updated formula to the tap's `main`.

4. **Verify.**

   ```bash
   brew update
   brew info markmals/tap/remctl     # shows stable X.Y.Z (bottled)
   brew upgrade remctl
   remctl --version                  # X.Y.Z
   ```

## Notes

- **Source of truth for the version** is `remctlVersion`; the tag and the formula
  follow it. The release fails if they disagree, so there is no way to ship a
  binary that misreports its version.
- **No App Store / notarization.** RemCTL links the private ReminderKit framework,
  so it is distributed only as a Homebrew bottle (built from source on the tap's
  runners) with a source-build fallback. This is by design; see
  [architecture.md](architecture.md).
- **Bottle coverage** is whatever the tap's `tests.yml` matrix builds — currently
  Apple-Silicon macOS 15 (Sequoia) and 26 (Tahoe). Other configurations (Intel,
  macOS 14) fall back to a source build during `brew install`. To add a bottle
  target, extend the matrix in the tap's `tests.yml`.
- **Fully hands-off publishing** (auto-applying `pr-pull` when the PR goes green)
  is possible but intentionally left as a one-click manual gate so a human
  confirms the bottles built before they are published.
