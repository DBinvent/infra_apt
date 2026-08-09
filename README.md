# infra_apt

Shared apt-repo (reprepro) publish pipeline, reused by every DBinvent apt-repo
project (`yaxaha_dist` and future ones). One GitHub reusable workflow +
composite action here; each project keeps only its own build steps and repo
config.

## Layout

- `scripts/publish-apt.sh` — generic publish logic: gpg-sign a `.deb`,
  `reprepro includedeb` it into a repo dir, copy in `install.html` as the
  index page. Callable standalone (env-var driven), used both locally and
  from CI.
- `actions/publish-deb/` — composite action wrapping the script above.
- `.github/workflows/publish-apt.yml` — reusable workflow (`workflow_call`):
  checks out the caller repo, runs the caller's build step, then calls
  `publish-deb`.

## Onboarding a new project

The calling repo needs to provide:

1. **`build.sh`** at its root — does whatever project-specific build
   (cargo, npm, whatever) produces a `.deb`, and writes the result as
   `deb=<absolute path>` to `$GITHUB_OUTPUT` (works locally too if you set
   `GITHUB_OUTPUT` to point at a temp file before calling it).
2. **`repo-conf/distributions`** — reprepro distribution config for this
   project (its own `Codename`/`Origin`/`SignWith`).
3. **`install.html`** — the page served as the repo's `index.html`.
4. **A GPG key dedicated to that project/org** — keep signing keys separate
   per org; don't reuse one key across projects.
5. A caller workflow, e.g. `.github/workflows/build.yml`:

```yaml
name: Build <project>

on:
  workflow_dispatch:
  push:

concurrency:
  group: deploy
  cancel-in-progress: true

jobs:
  build:
    uses: DBinvent/infra_apt/.github/workflows/publish-apt.yml@main
    with:
      project: <project>
      package: <reprepro codename, matches repo-conf/distributions>
      repo_dir: /media/lab/repo-<project>
      build_script: ./build.sh /media/lab/vk-home/git
      cleanup_docker: true
    secrets:
      gpg_key: ${{ secrets.GPG_KEY }}
```

Give each project its own `repo_dir` (own reprepro `conf`/`pool`/`dists`) —
the publish script overwrites `REPO_DIR/conf/distributions` wholesale, so
projects can't safely share one repo root.

Once this pipeline is stable, pin callers to a tag (`@v1`) instead of
`@main` so an edit here doesn't simultaneously affect every project.

See `yaxaha_dist` for a working reference implementation.
