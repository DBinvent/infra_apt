#!/bin/bash
set -Eeuo pipefail

# Generic Docker image publish step, beside publish-apt.sh: build an image from a
# context directory, check it, push its tags to Docker Hub, and confirm the
# registry serves what was pushed - publicly.
#
# Required env vars:
#   CONTEXT     - the build context directory (holding the Dockerfile)
#   IMAGE       - the repository, e.g. dbinvent/sge
#   TAGS        - the tags, space separated, e.g. "2.0.1 2.0 latest"; the first
#                 names the image the checks run on
# Optional env vars:
#   BUILD_ARGS  - KEY=VALUE ..., space separated, passed as --build-arg
#   SMOKE       - a command run with the built image (IMAGE:<first tag>) as its last
#                 argument; a non-zero exit publishes nothing
#   PUSH        - 1 (default): push and confirm; 0: build and check only; login:
#                 only log in (BUILD=0 implied) - the token checked, nothing pushed;
#                 describe: only the repository's page text below, nothing pushed
#   DESCRIPTION - the repository's one-line description on Docker Hub (100 chars at most)
#   README      - a Markdown file: the repository's page on Docker Hub
#                 Both are set after the push, and read back from Docker Hub
#                 unauthenticated; a failure there is a warning - the image is out.
#   BUILD       - 1 (default); 0: push the tags as a run before built them (PUSH=0)
#   DOCKER_USER - the Docker Hub account the token belongs to (default: IMAGE's namespace)
#   DOCKER_TOKEN - a Docker Hub access token with write access to IMAGE
#   ENV_FILE    - where DOCKER_USER and DOCKER_TOKEN are read from when the
#                 environment has neither (default: .env in this repository's root)
#
# Builds run on another docker host: DOCKER_HOST (ssh://<host> or tcp://...) is
# required, unless DOCKER_LOCAL=1 allows this host's own daemon. The token goes to
# `docker login` on stdin, into a configuration directory of this run only, removed
# at the end: nothing is left logged in.

: "${CONTEXT:?CONTEXT is required}"
: "${IMAGE:?IMAGE is required}"
: "${TAGS:?TAGS is required}"
PUSH="${PUSH:-1}"
case "$PUSH" in login|describe) BUILD=0 ;; esac
[ -z "${DESCRIPTION:-}" ] || [ "${#DESCRIPTION}" -le 100 ] || { echo "ERROR: DESCRIPTION is ${#DESCRIPTION} chars, Docker Hub takes 100" >&2; exit 1; }
[ -z "${README:-}" ] || [ -f "$README" ] || { echo "ERROR: README $README does not exist" >&2; exit 1; }
read -ra TAG_LIST <<< "$TAGS"
REF="$IMAGE:${TAG_LIST[0]}"

[ "${BUILD:-1}" = 0 ] || [ -f "$CONTEXT/Dockerfile" ] || { echo "ERROR: no Dockerfile in $CONTEXT" >&2; exit 1; }
case "${DOCKER_HOST:-}" in
  ssh://*|tcp://*) ;;
  *) [ "${DOCKER_LOCAL:-0}" = 1 ] || { echo "ERROR: DOCKER_HOST names no build host (ssh:// or tcp://) - DOCKER_LOCAL=1 builds here" >&2; exit 1; } ;;
esac

if [ "$PUSH" = login ] || [ "$PUSH" = describe ]; then
  :
elif [ "${BUILD:-1}" = 0 ]; then
  for t in "${TAG_LIST[@]}"; do
    docker image inspect "$IMAGE:$t" >/dev/null 2>&1 || { echo "ERROR: BUILD=0, and no $IMAGE:$t on ${DOCKER_HOST:-this host}" >&2; exit 1; }
  done
  echo "  OK    $REF as built before: $(docker image inspect -f '{{.Id}}' "$REF" | cut -c1-19)"
else
  args=(--pull)
  for t in "${TAG_LIST[@]}"; do args+=(-t "$IMAGE:$t"); done
  for a in ${BUILD_ARGS:-}; do args+=(--build-arg "$a"); done
  echo "Building $IMAGE (${TAGS}) from $CONTEXT on ${DOCKER_HOST:-this host} ..."
  docker build "${args[@]}" "$CONTEXT"
  echo "  OK    built $REF: $(docker image inspect -f '{{.Id}}' "$REF" | cut -c1-19), $(docker image ls --format '{{.Size}}' "$REF" | head -1)"
fi

if [ "${BUILD:-1}" != 0 ] && [ -n "${SMOKE:-}" ]; then
  # shellcheck disable=SC2086
  $SMOKE "$REF" || { echo "  FAIL  $REF: the check ($SMOKE) exited $?" >&2; exit 1; }
  echo "  OK    checked: $SMOKE"
fi
case "$PUSH" in 1|login|describe) ;; *) echo "PUSH=$PUSH: nothing pushed"; exit 0 ;; esac

# the token: the environment's, or the env file's - only these two keys are read
if [ -z "${DOCKER_TOKEN:-}" ]; then
  ENV_FILE="${ENV_FILE:-$(cd "$(dirname "$0")/.." && pwd)/.env}"
  [ -f "$ENV_FILE" ] || { echo "ERROR: no DOCKER_TOKEN, and no $ENV_FILE" >&2; exit 1; }
  DOCKER_TOKEN="$(sed -n 's/^[[:space:]]*DOCKER_TOKEN[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -1 | tr -d '"'"'"'\r')"
  : "${DOCKER_USER:=$(sed -n 's/^[[:space:]]*DOCKER_USER[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" | tail -1 | tr -d '"'"'"'\r')}"
fi
[ -n "${DOCKER_TOKEN:-}" ] || { echo "ERROR: DOCKER_TOKEN is empty" >&2; exit 1; }
DOCKER_USER="${DOCKER_USER:-${IMAGE%%/*}}"
export -n DOCKER_TOKEN

DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
# its warning about a plain-text store is about this run's own directory, gone at exit
login_out="$(printf '%s' "$DOCKER_TOKEN" | docker login -u "$DOCKER_USER" --password-stdin 2>&1)" \
  || { echo "$login_out" >&2; echo "  FAIL  docker login as $DOCKER_USER refused" >&2; exit 1; }
echo "  OK    docker login as $DOCKER_USER"
[ "$PUSH" = login ] && { unset DOCKER_TOKEN; docker logout >/dev/null 2>&1 || true; exit 0; }

# [hub] The repository's page: the push carries none of it. Docker Hub's API, with a
# bearer token the access token is exchanged for - both on stdin, never an argument.
describe() {
  [ -n "${DESCRIPTION:-}${README:-}" ] || return 0
  local r
  r="$(printf '%s' "$DOCKER_TOKEN" | python3 -I -c '
import json, sys, urllib.request
user, ns, repo, desc, readme = sys.argv[1:6]
secret = sys.stdin.read()
def call(method, url, body, token=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method=method,
                                 headers={"Content-Type": "application/json"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as f:
        return json.load(f)
try:
    tok = call("POST", "https://hub.docker.com/v2/auth/token", {"identifier": user, "secret": secret})["access_token"]
    body = {}
    if desc: body["description"] = desc
    if readme: body["full_description"] = open(readme).read()
    call("PATCH", f"https://hub.docker.com/v2/namespaces/{ns}/repositories/{repo}", body, tok)
    with urllib.request.urlopen(f"https://hub.docker.com/v2/namespaces/{ns}/repositories/{repo}", timeout=30) as f:
        got = json.load(f)
    bad = [k for k in body if (got.get(k) or "").strip() != body[k].strip()]
    print("mismatch: " + ", ".join(bad) if bad else "ok")
except Exception as e:
    print(f"error: {e}")
' "$DOCKER_USER" "${IMAGE%%/*}" "${IMAGE#*/}" "${DESCRIPTION:-}" "${README:-}")"
  if [ "$r" = ok ]; then echo "  OK    $IMAGE: Docker Hub page set${DESCRIPTION:+ (\"$DESCRIPTION\")}${README:+, from $(basename "$README")}"
  else echo "  WARN  $IMAGE: Docker Hub page not set: $r"; fi
}
if [ "$PUSH" = describe ]; then describe; unset DOCKER_TOKEN; docker logout >/dev/null 2>&1 || true; exit 0; fi

for t in "${TAG_LIST[@]}"; do
  out="$(docker push "$IMAGE:$t")" || { echo "$out" >&2; echo "  FAIL  push $IMAGE:$t" >&2; exit 1; }
  digest="$(grep -oE 'digest: sha256:[0-9a-f]{64}' <<< "$out" | tail -1 | cut -d' ' -f2)"
  [ -n "$digest" ] || { echo "$out" >&2; echo "  FAIL  push $IMAGE:$t named no digest" >&2; exit 1; }
  # what anyone pulls now: Docker Hub's own answer, unauthenticated - a private
  # repository answers nothing
  served=""
  for _ in $(seq 1 12); do
    # the tag's own digest, the top-level one: an image with attestations is an index,
    # and its "images" list the digests of the manifests in it - the first "digest"
    # in the answer is one of those, not the index the push named
    served="$(curl -fsS -m 20 "https://hub.docker.com/v2/namespaces/${IMAGE%%/*}/repositories/${IMAGE#*/}/tags/$t" 2>/dev/null \
      | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("digest") or "")')" || true
    [ "$served" = "$digest" ] && break
    sleep 5
  done
  [ "$served" = "$digest" ] \
    || { echo "  FAIL  $IMAGE:$t: Docker Hub serves ${served:-nothing public}, not the pushed $digest" >&2; exit 1; }
  echo "  OK    pushed $IMAGE:$t ($digest), public"
done
describe
unset DOCKER_TOKEN
docker logout >/dev/null 2>&1 || true
