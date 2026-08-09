#!/bin/bash
set -Eeu

# Generic apt (reprepro) publish step, shared by all apt-repo projects.
# Signs a .deb, publishes it into a reprepro repository, and (optionally)
# drops an install.html as the repo's index page.
#
# Required env vars:
#   DEB       - path to the built .deb package
#   REPO_DIR  - reprepro repository root (e.g. /media/lab/repo)
#   CONF_DIR  - directory containing this project's repo-conf/distributions
#   GPG_KEY   - signing key id/fingerprint
#   PACKAGE   - reprepro package/codename (matches Codename in distributions)
# Optional env vars:
#   INSTALL_HTML   - path to an install.html to publish as REPO_DIR/index.html
#   CLEANUP_DOCKER - "true" to run `docker system prune -a -f` after publishing

: "${DEB:?DEB is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${CONF_DIR:?CONF_DIR is required}"
: "${GPG_KEY:?GPG_KEY is required}"
: "${PACKAGE:?PACKAGE is required}"

if [ ! -f "$DEB" ]; then
  echo "ERROR: package $DEB does not exist" >&2
  exit 1
fi

mkdir -p "$REPO_DIR/conf"
cp -f "$CONF_DIR/distributions" "$REPO_DIR/conf/distributions"

if [ -n "${INSTALL_HTML:-}" ] && [ -f "$INSTALL_HTML" ]; then
  cp -f "$INSTALL_HTML" "$REPO_DIR/index.html"
fi

SIG="${DEB}.sig"
rm -f "$SIG"
gpg --local-user "$GPG_KEY" --detach-sign -o "$SIG" "$DEB"

echo "Removing old $PACKAGE package from $REPO_DIR ..."
reprepro -b "$REPO_DIR" remove "$PACKAGE" "$PACKAGE" || true

echo "Publishing $DEB to $REPO_DIR ..."
reprepro -b "$REPO_DIR" --conf "$CONF_DIR" includedeb "$PACKAGE" "$DEB"

cp -f "$SIG" "$REPO_DIR/"
rm -f "$SIG"

if [ "${CLEANUP_DOCKER:-false}" = "true" ]; then
  echo "Cleaning up docker..."
  docker system prune -a -f
fi

dpkg --contents "$DEB"
echo "Package:"
ls -lah "$DEB"
