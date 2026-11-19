# Visual Update Guard

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Find out whether a change broke how your web app looks, before you merge it.

Visual Update Guard screenshots your app twice in the same job: once on the base branch and once on the current code. Playwright compares every pair pixel by pixel, and you get one of four answers: `OK`, `CHANGED`, `BROKEN` or `UNAVAILABLE`.

It works with any web app that Playwright can start: Next.js, React, Vue, Vite, Astro, SvelteKit or plain HTML. Common uses:

- Dependency update pull requests (Dependabot, Renovate, a security bot): does the new version change the UI?
- Pull requests that touch styles or shared components.
- Scheduled jobs that update packages and want to check the result before committing it.

## How it works

1. **Base.** It checks out `base-ref` in a separate git worktree, so your workspace is never switched to another branch. It installs, runs `setup-command` and `build-command`, and runs your Playwright tests with `updateSnapshots: 'all'`. The screenshots go to a temporary folder outside git.
2. **Current code.** It does the same in your workspace as it is, uncommitted changes included. The tests run with `updateSnapshots: 'none'`, so every screenshot is compared with the one from base and is never overwritten.
3. **Result.** It sets the `status` and `summary` outputs, writes the job summary and uploads the Playwright HTML report with the expected, actual and diff images.

Your committed baseline images are never read or changed. The reference is always the base branch rendered in the same job, on the same runner, with the same browser. This is how it works:

- It writes a small config next to yours that imports your config and changes only `snapshotPathTemplate` and `updateSnapshots`.
- It deletes that file when it ends.

## The four statuses

| Status | Meaning | What to do |
|---|---|---|
| `OK` | Every screenshot is pixel-identical to base. | Nothing. |
| `CHANGED` | At least one screenshot differs from base, or is new and has no reference. The summary names them. | Open the report and decide if the change is expected. |
| `BROKEN` | With the current code, the install, setup, build or server failed, or a test failed for a reason other than a screenshot difference. | Read the log. The current code does not work. |
| `UNAVAILABLE` | There is nothing to compare: `base-ref` could not be found, built or tested, or it took no screenshots. | Fix the base, or accept that this run checked nothing. |

By default the step never fails because of the result. Use `fail-on` to make it fail, for example `fail-on: CHANGED,BROKEN`.

## Quick Start

You need a Playwright config with `toHaveScreenshot()` assertions and a `webServer` that starts your app:

```yaml
- uses: actions/checkout@v7
- uses: Fariiixm/visual-diff-action@v1
  with:
    playwright-config: playwright.config.ts
```

That is the whole setup for a standard project. The package manager is detected from the lockfile, the build runs `npm run build` when the script exists, and the reference is the pull request's base branch (`main` outside pull requests).

A full workflow that comments the result on the pull request:

```yaml
name: Visual check

on: pull_request

permissions:
  contents: read
  pull-requests: write

jobs:
  visual:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - id: visual
        uses: Fariiixm/visual-diff-action@v1
        with:
          playwright-config: playwright.config.ts
          browsers: chromium

      - name: Comment on the pull request
        if: always() && steps.visual.outputs.summary != ''
        env:
          GH_TOKEN: ${{ github.token }}
          SUMMARY: ${{ steps.visual.outputs.summary }}
        run: gh pr comment "${{ github.event.pull_request.number }}" --body "$SUMMARY"
```

A minimal config and test, if you are starting from zero:

```ts
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './visual',
  use: { ...devices['Desktop Chrome'], baseURL: 'http://127.0.0.1:3000' },
  expect: { toHaveScreenshot: { maxDiffPixels: 0, animations: 'disabled', caret: 'hide' } },
  webServer: { command: 'npm run start', url: 'http://127.0.0.1:3000', timeout: 120_000 },
});
```

```ts
// visual/home.spec.ts
import { test, expect } from '@playwright/test';

test('home page', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveScreenshot('home.png', { fullPage: true });
});
```

## Advanced Setup

### Apps that need a database, migrations or secrets

`setup-command` runs on each side before the build, in the same shell as the build and the tests. Variables it exports reach both. It starts in the root of the code being tested, which is also in `$VUG_ROOT`. `$VUG_SIDE` is `before` or `after`.

This example runs in a monorepo. The app uses a local SQLite file, runs migrations before building, and needs an auth secret that only exists during the job:

```yaml
- id: visual
  uses: Fariiixm/visual-diff-action@v1
  with:
    working-directory: apps/web
    playwright-config: playwright.visual.config.ts
    browsers: chromium
    setup-command: |
      # A secret that only lives in this job: nothing real is ever needed
      export AUTH_SECRET="$(openssl rand -hex 32)"
      export AUTH_URL="http://127.0.0.1:3000"
      # A throwaway SQLite database inside the project
      mkdir -p data
      export DATABASE_URL="file:$PWD/data/visual.db"
      npm run db:migrate
    build-command: npm run build
    fail-on: BROKEN
```

To keep the screenshots stable, serve recorded API responses with `page.route()` instead of live data, and hide anything random, such as dates, maps or ads. Use `mask`, `stylePath` or a style tag for that.

### Check a dependency update before committing it

The current side is your workspace as it is, so you can change packages in a step and check them before any commit. With `base-ref: HEAD`, the reference is the last commit:

```yaml
- uses: actions/checkout@v7
- run: npm update --package-lock-only
- id: visual
  uses: Fariiixm/visual-diff-action@v1
  with:
    base-ref: HEAD
- if: steps.visual.outputs.status == 'OK'
  run: echo "Safe to commit the update"
```

### Push events

There is no base branch on a push, so compare with the previous commit of the branch:

```yaml
with:
  base-ref: ${{ github.event.before }}
```

### Matrix jobs

Artifact names must be unique in a run:

```yaml
with:
  artifact-name: visual-report-${{ matrix.browser }}
  playwright-args: --project=${{ matrix.browser }}
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `playwright-config` | `playwright.visual.config.ts` | Playwright config with the screenshot tests, relative to `working-directory`. |
| `working-directory` | `.` | Folder of the web app, relative to the repository root. |
| `base-ref` | `${{ github.base_ref \|\| 'main' }}` | Branch, tag, commit or HEAD-relative ref whose screenshots are the reference. |
| `install-command` | detected | Installs the dependencies. It is detected from the lockfile: `npm ci` (`npm install` without a lockfile), `pnpm install --frozen-lockfile`, or `yarn install --frozen-lockfile` (`--immutable` on Yarn 2+). |
| `setup-command` | empty | Commands run before the build on each side. Exported variables reach the build and the tests. |
| `build-command` | `npm run build --if-present` | Builds the app. Set it to an empty string to skip the build. |
| `browsers` | empty | Browsers to install, for example `chromium`. Empty installs Playwright's default set. |
| `install-deps` | `true` | Install the system libraries the browsers need. |
| `playwright-args` | empty | Extra arguments for `playwright test` on both sides. |
| `node-version` | empty | Node.js version. Empty uses `.nvmrc` or `.node-version`, or else the runner's Node.js. |
| `cache` | `true` | Cache the package manager store and the Playwright browsers. |
| `upload-report` | `true` | Upload the HTML report and the diff images as an artifact. |
| `artifact-name` | `visual-update-guard-report` | Name of the report artifact. |
| `retention-days` | `14` | Days to keep the artifact. |
| `fail-on` | empty | Statuses that fail the step, separated by commas. |
| `job-summary` | `true` | Write the summary to the job summary page. |

## Outputs

| Output | Description |
|---|---|
| `status` | `OK`, `CHANGED`, `BROKEN` or `UNAVAILABLE`. |
| `summary` | Markdown summary, ready for a pull request comment. |
| `changed` | Comma-separated names of the snapshots that changed or have no reference. |
| `report-url` | URL of the report artifact, when it was uploaded. |
| `base-sha` | Commit used as the reference. |

## Security

- The action runs the code of both refs. Use it with `pull_request`, never with `pull_request_target`, or a fork could run its code with your secrets.
- Anyone who can read the repository can download the report artifact. If your tests log in with real credentials, turn off traces and videos in the config, or set `upload-report: false`.
- Every input reaches the scripts through environment variables, never by text substitution.
- The third-party actions it uses are pinned to commit SHAs.

## Requirements and limitations

- Linux runners such as `ubuntu-latest`. macOS should work. Windows is not supported.
- `@playwright/test` 1.28 or newer.
- Run `actions/checkout` first. A shallow clone is fine: the base is fetched with `--depth=1`.
  - On a private repository, keep the default `persist-credentials: true` so the base can be fetched.
- The config file can be `.ts`, `.js`, `.mjs`, `.cjs`, `.mts` or `.cts`, and its default export must be an object.
- Each side installs and builds once, so the job takes about twice as long as a single test run.
- Git LFS files and private submodules on the base are not fetched.

## License

[MIT](LICENSE)
