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
#   PACKAGE   - the package the .deb carries (its previous version is removed first)
# Optional env vars:
#   CODENAME       - the reprepro distribution (Codename in distributions), when it
#                    is not named like the package; default: PACKAGE
#   INSTALL_HTML   - path to an install.html to publish as REPO_DIR/index.html

: "${DEB:?DEB is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${CONF_DIR:?CONF_DIR is required}"
: "${GPG_KEY:?GPG_KEY is required}"
: "${PACKAGE:?PACKAGE is required}"
CODENAME="${CODENAME:-$PACKAGE}"

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

echo "Removing old $PACKAGE package from $CODENAME in $REPO_DIR ..."
reprepro -b "$REPO_DIR" remove "$CODENAME" "$PACKAGE" || true

echo "Publishing $DEB to $REPO_DIR ..."
reprepro -b "$REPO_DIR" --conf "$CONF_DIR" includedeb "$CODENAME" "$DEB"

cp -f "$SIG" "$REPO_DIR/"
rm -f "$SIG"

dpkg --contents "$DEB"
echo "Package:"
ls -lah "$DEB"
