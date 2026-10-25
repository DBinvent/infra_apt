# infra_apt

Shared apt-repo (reprepro) publish pipeline, reused by every DBinvent apt-repo
project (`ytcluster_dist` and future ones). One GitHub reusable workflow +
composite action here; each project keeps only its own build steps and repo
config.

## Layout

- `scripts/publish-apt.sh` - generic publish logic: gpg-sign a `.deb`,
  `reprepro includedeb` it into a repo dir, copy in `install.html` as the
  index page. Callable standalone (env-var driven), used both locally and
  from CI.
- `scripts/publish-rpm.sh` - an `.rpm` into the yum repository beside the apt one
  (`REPO_DIR/yum/el9`, https://apt.dbinvent.com/yum/el9): signed with `rpmsign`,
  the package's previous builds removed, the metadata rebuilt with `createrepo_c`
  and signed (`repomd.xml.asc`). The `.repo` file users add belongs to the
  repository's owner (`ytcluster_dist/publish_rpm.sh` writes `yt-cluster-el9.repo`).
- `scripts/publish-pak.sh` - a tarball of binaries, for a host that takes no deb
  or rpm, into the repository's download area (`REPO_DIR/paks`): as
  `<name>-<version>-<sha8>.tar.gz`, a name that follows from the bytes and so never
  changes, with its `.sha256` and a detached `.sig`; `<name>-latest.tar.gz`, a link
  to it, with a `.sha256` naming the link; and the manifest `<name>.json` (version,
  file, sha256, bytes). The previous artifact of the name goes.
- `scripts/publish-docker.sh` - an image to Docker Hub: built from a context
  directory on a separate docker host (`DOCKER_HOST`, `ssh://` or `tcp://`;
  `DOCKER_LOCAL=1` allows this host's own daemon), checked by a `SMOKE` command,
  pushed under every tag in `TAGS`, and confirmed: Docker Hub must serve the pushed
  digest to anyone, unauthenticated, or it fails. The token is `DOCKER_TOKEN` (and
  `DOCKER_USER`, default the image's namespace), from the environment or this
  repository's `.env` - only those two keys are read, the token goes to
  `docker login` on stdin, into a configuration directory of the run that is
  removed after it. `DESCRIPTION` (one line) and `README` (a Markdown file) set
  the repository's Docker Hub page after the push, read back to confirm - a push
  carries no page of its own. `PUSH=0` builds and checks only; `BUILD=0` pushes what
  a run before built; `PUSH=login` checks the token and pushes nothing;
  `PUSH=describe` sets the page only.
- `actions/publish-deb/`, `actions/publish-rpm/`, `actions/publish-pak/`,
  `actions/publish-docker/` - composite actions wrapping the scripts above (a
  reusable workflow runs in the caller's checkout: its own scripts are reached
  through an action's path).
- `.github/workflows/publish-apt.yml` - reusable workflow (`workflow_call`):
  checks out the caller repo, runs the caller's build step, then publishes what
  it built: the deb (`publish-deb`), and from v4 an rpm (`publish-rpm`), the
  tarball (`publish-pak`, with `pak_name`) and the image (`publish-docker`, with
  `docker_image` - pushed only: the build step builds and checks it).

## Onboarding a new project

The calling repo needs to provide:

1. **`build.sh`** at its root - does whatever project-specific build
   (cargo, npm, whatever) produces a `.deb`, and writes the result as
   `deb=<absolute path>` to `$GITHUB_OUTPUT` (works locally too if you set
   `GITHUB_OUTPUT` to point at a temp file before calling it). From v4, for the
   other forms, also: `rpm=<absolute path>` (published whenever it is written),
   `tgz=<absolute path>` and `version=<x.y.z>` (with `pak_name`), and
   `docker_tags=<tag> ...` - the tags it gave `docker_image`, built on the
   runner's own docker daemon unless `docker_host` names another (the build step
   gets it as `DOCKER_HOST`). The image takes the secret `docker_token`.
2. **`repo-conf/distributions`** - reprepro distribution config for this
   project (its own `Codename`/`Origin`/`SignWith`).
3. **`install.html`** - the page served as the repo's `index.html`.
4. **A GPG key dedicated to that project/org** - keep signing keys separate
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
    uses: DBinvent/infra_apt/.github/workflows/publish-apt.yml@v4
    with:
      project: <project>
      package: <reprepro codename, matches repo-conf/distributions>
      repo_dir: /media/lab/repo-<project>
      build_script: ./build.sh /media/lab/vk-home/git
      cleanup_docker: true
    secrets:
      gpg_key: ${{ secrets.GPG_KEY }}
```

Give each project its own `repo_dir` (own reprepro `conf`/`pool`/`dists`) -
the publish script overwrites `REPO_DIR/conf/distributions` wholesale, so
projects can't safely share one repo root - with one exception: a package
published *into* another project's distribution. Then its `repo-conf/distributions`
is a copy of that root's own, and `codename` names the distribution (`package`
stays the package, the one removed before the new build goes in). Schema Guard
does that, into YT Cluster's apt.dbinvent.com root:

```yaml
      package: schema-guard
      codename: yt-cluster
      repo_dir: /media/lab/repo
```

Callers should pin to a tag (currently `@v4`; `codename` needs v3 or later, the rpm,
tarball and image v4), not `@main` - bump the tag
deliberately when this pipeline changes so an edit here doesn't
simultaneously affect every project at once.

See `ytcluster_dist` for a working reference implementation.
