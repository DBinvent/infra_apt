#!/bin/bash
set -Eeuo pipefail

# Generic yum publish step, beside publish-apt.sh: an rpm into the yum repository
# served next to the apt one - REPO_DIR/YUM_SUBDIR, i.e.
# https://apt.dbinvent.com/yum/el9 (nginx serves all of REPO_DIR). Generalized from
# ytcluster_dist/publish_rpm.sh.
#
# Required env vars:
#   RPM       - the built .rpm
#   REPO_DIR  - the repository root (e.g. /media/lab/repo)
#   GPG_KEY   - signing key id/fingerprint
#   PACKAGE   - the package the .rpm carries: its previous builds are removed
# Optional env vars:
#   YUM_SUBDIR - the repository under REPO_DIR (default: yum/el9)
#   KEEP       - how many builds of PACKAGE stay (default: 1, only the latest)
#
# The package is signed with rpmsign (apt install rpm) - a repository whose .repo
# file says gpgcheck=1 takes no unsigned one, so its absence is an error - and the
# metadata, rebuilt by createrepo_c (apt install createrepo-c), is signed too
# (repomd.xml.asc, for repo_gpgcheck). The .repo file users add is the
# repository's own, written by the project that owns it, not here.

: "${RPM:?RPM is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${GPG_KEY:?GPG_KEY is required}"
: "${PACKAGE:?PACKAGE is required}"
YUM_SUBDIR="${YUM_SUBDIR:-yum/el9}"
KEEP="${KEEP:-1}"

[ -f "$RPM" ] || { echo "ERROR: package $RPM does not exist" >&2; exit 1; }
for c in rpmsign createrepo_c; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is not installed (apt install rpm createrepo-c)" >&2; exit 1; }
done
name="$(rpm -qp --qf '%{NAME}' "$RPM" 2>/dev/null)"
[ "$name" = "$PACKAGE" ] || { echo "ERROR: $RPM carries ${name:-no package}, not $PACKAGE" >&2; exit 1; }

DEST="$REPO_DIR/$YUM_SUBDIR"
mkdir -p "$DEST/packages"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -f "$RPM" "$STAGE/"
PKG="$STAGE/$(basename "$RPM")"
# rpm's %__gpg is /usr/bin/gpg2, which Ubuntu does not have: the gpg that is installed
rpmsign --addsign --define "__gpg $(command -v gpg)" --define "_gpg_name $GPG_KEY" \
  --define "_gpg_sign_cmd_extra_args --batch --pinentry-mode error" "$PKG"
cp -f "$PKG" "$DEST/packages/"

# the newest KEEP builds of this package stay; another project's packages are not its
ls -1t "$DEST"/packages/"$PACKAGE"-[0-9]*.rpm 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -fv

createrepo_c --update "$DEST"
rm -f "$DEST/repodata/repomd.xml.asc"
gpg --batch --yes --pinentry-mode error --local-user "$GPG_KEY" --armor --detach-sign \
  -o "$DEST/repodata/repomd.xml.asc" "$DEST/repodata/repomd.xml"

rpm -qip "$DEST/packages/$(basename "$RPM")"
echo "Published $(basename "$RPM") to $DEST"
