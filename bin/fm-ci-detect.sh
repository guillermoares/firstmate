#!/usr/bin/env bash
# Report whether a clone's default branch carries any CI configuration, so a
# no-mistakes ship brief can skip the pipeline's ci step when there is provably
# nothing for it to wait on. Prints exactly one line to stdout:
#   ci=present evidence=<the first known CI path found on the default branch>
#   ci=absent forge=<github|gitlab>
#   ci=unknown reason=<why no verdict was reached>
# and exits 0 for all three; a missing clone or a directory that is not a git
# work tree exits 2 with an error on stderr.
#
# Only `ci=absent` ever changes behaviour (bin/fm-dod-lib.sh fm_dod_ci_state owns
# what a caller does with it), so every doubt resolves to `present` or `unknown`,
# both of which keep the pipeline's ci step exactly as it is today.
#
# Absent is claimed only when BOTH hold, read from the clone's own git data and
# never from the network:
#   - the forge is known: origin's host is github.com, or a host with a `gitlab`
#     label (gitlab.com, gitlab.example.org, gitlab-ce.example.org). A
#     self-hosted instance under another name is unknown, not guessed.
#   - the tree of origin/HEAD (the default branch as last fetched, no checkout)
#     holds none of the known CI entries: .gitlab-ci.yml, .github/workflows/,
#     .circleci/, Jenkinsfile, azure-pipelines.yml, .travis.yml,
#     bitbucket-pipelines.yml, .drone.yml, .buildkite/.
# An origin/HEAD that cannot be resolved to a tree is unknown. Checks a forge
# runs without a repository file (a GitHub App, an external status, a GitLab
# project whose CI config lives at a path set in project settings) are not
# visible here and are outside this detection.
# Usage: fm-ci-detect.sh <clone-dir>
set -eu

DIR=${1:?usage: fm-ci-detect.sh <clone-dir>}
if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $DIR is not a git work tree" >&2
  exit 2
fi

unknown() {
  printf 'ci=unknown reason=%s\n' "$1"
  exit 0
}

# The host of an origin URL in any of the shapes git accepts for a network
# remote: scp-like `user@host:path`, and scheme URLs with optional userinfo and
# port. Prints nothing for a local path or anything it cannot read a host from.
origin_host() {  # <url>
  local url=$1 rest host
  case "$url" in
    *://*)
      rest=${url#*://}
      rest=${rest%%/*}
      rest=${rest##*@}
      host=${rest%%:*}
      ;;
    *@*:*)
      rest=${url##*@}
      host=${rest%%:*}
      ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$host" | tr '[:upper:]' '[:lower:]'
}

# github | gitlab for a host this script is willing to call known, else nothing.
forge_for_host() {  # <host>
  local host=$1 label
  local -a labels
  [ -n "$host" ] || return 0
  [ "$host" = github.com ] && { printf 'github\n'; return 0; }
  IFS=. read -ra labels <<< "$host"
  for label in "${labels[@]}"; do
    case "$label" in
      gitlab|gitlab-*) printf 'gitlab\n'; return 0 ;;
    esac
  done
}

url=$(git -C "$DIR" remote get-url origin 2>/dev/null) || unknown "no origin remote"
forge=$(forge_for_host "$(origin_host "$url")")
[ -n "$forge" ] || unknown "origin is not a known GitHub or GitLab host"

git -C "$DIR" rev-parse --verify --quiet 'refs/remotes/origin/HEAD^{tree}' >/dev/null 2>&1 \
  || unknown "origin/HEAD does not resolve to a tree"

found=$(git -C "$DIR" ls-tree --name-only refs/remotes/origin/HEAD -- \
  .gitlab-ci.yml .github/workflows .circleci Jenkinsfile azure-pipelines.yml \
  .travis.yml bitbucket-pipelines.yml .drone.yml .buildkite 2>/dev/null) \
  || unknown "the default branch tree could not be read"

if [ -n "$found" ]; then
  printf 'ci=present evidence=%s\n' "$(printf '%s\n' "$found" | head -n 1)"
else
  printf 'ci=absent forge=%s\n' "$forge"
fi
