#!/bin/bash
set -Eeuo pipefail

# Generic download publish step, beside publish-apt.sh: a tarball of binaries, for a
# host that takes no deb or rpm, into the repository's /paks/ download area, by its
# convention:
#   <name>-<version>-<sha8>.tar.gz   the artifact: its name follows from its bytes,
#                                    so it never changes - held a year at the edge
#   ... .sha256, ... .sig            its checksum, its detached signature (GPG_KEY)
#   <name>-latest.tar.gz             a symlink to it, with a .sha256 and .sig that
#                                    name the link, so `curl -O` and `sha256sum -c`
#                                    work on the file a visitor saved
#   <name>.json                      the manifest: name, version, file, sha256, bytes
# The last two revalidate within minutes. The previous artifact of the name goes.
#
# Required env vars:
#   TGZ       - the tarball (a .tar.gz, under any name)
#   NAME      - the artifact's name, e.g. sge
#   VERSION   - its version, x.y.z
#   REPO_DIR  - the repository root
#   GPG_KEY   - signing key id/fingerprint
# Optional env vars:
#   PAKS      - the directory under REPO_DIR (default: paks)
#   PLATFORM  - written to the manifest (default: x86_64-linux)

: "${TGZ:?TGZ is required}"
: "${NAME:?NAME is required}"
: "${VERSION:?VERSION is required}"
: "${REPO_DIR:?REPO_DIR is required}"
: "${GPG_KEY:?GPG_KEY is required}"
PAKS="${PAKS:-paks}"
PLATFORM="${PLATFORM:-x86_64-linux}"

[ -f "$TGZ" ] || { echo "ERROR: $TGZ does not exist" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: VERSION $VERSION is not x.y.z" >&2; exit 1; }
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: NAME $NAME" >&2; exit 1; }
tar -tzf "$TGZ" >/dev/null || { echo "ERROR: $TGZ is no readable gzip tarball" >&2; exit 1; }

dir="$REPO_DIR/$PAKS"
mkdir -p "$dir"
sum="$(sha256sum "$TGZ" | cut -d' ' -f1)"
bytes="$(stat -c %s "$TGZ")"
art="$NAME-$VERSION-${sum:0:8}.tar.gz"
latest="$NAME-latest.tar.gz"

# the artifact and its companions under temporary names first: a visitor never sees
# a half-written file, and the previous artifact stays until the new one is whole
tmp="$dir/.$art.$$"
trap 'rm -f "$tmp" "$tmp.sig"' EXIT
cp -f "$TGZ" "$tmp"
gpg --local-user "$GPG_KEY" --detach-sign -o "$tmp.sig" "$tmp"
mv -f "$tmp" "$dir/$art"; mv -f "$tmp.sig" "$dir/$art.sig"
( cd "$dir" && sha256sum "$art" > "$art.sha256" )

# the previous artifacts of this name go
find "$dir" -maxdepth 1 -regextype posix-extended \
  -regex ".*/$NAME-[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{8}\.tar\.gz(\.sha256|\.sig)?" \
  ! -name "$art" ! -name "$art.sha256" ! -name "$art.sig" -printf '  removed %f\n' -delete

ln -sfn "$art" "$dir/$latest"
ln -sfn "$art.sig" "$dir/$latest.sig"
( cd "$dir" && sha256sum "$latest" > "$latest.sha256.tmp" && mv -f "$latest.sha256.tmp" "$latest.sha256" )
cat > "$dir/$NAME.json.tmp" <<JSON
{
  "name": "$NAME",
  "version": "$VERSION",
  "platform": "$PLATFORM",
  "file": "$art",
  "sha256": "$sum",
  "bytes": $bytes,
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
mv -f "$dir/$NAME.json.tmp" "$dir/$NAME.json"
chmod 644 "$dir/$art" "$dir/$art.sha256" "$dir/$art.sig" "$dir/$latest.sha256" "$dir/$NAME.json"

echo "Published $PAKS/$art ($VERSION, $bytes bytes, sha256 ${sum:0:12}), $PAKS/$latest and $PAKS/$NAME.json"
