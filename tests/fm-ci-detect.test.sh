#!/usr/bin/env bash
# bin/fm-ci-detect.sh reports, from a clone's own git data, whether its default
# branch carries any CI configuration. Only a known GitHub or GitLab host whose
# origin/HEAD tree holds none of the known CI entries may read as absent; every
# doubt must read as present or unknown, because only absent changes what a
# no-mistakes worker is told.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-ci-detect-tests)
DETECT="$ROOT/bin/fm-ci-detect.sh"

# new_clone <name> <origin-url> [<path-in-tree>...]: a clone whose origin/HEAD
# tree holds exactly the named files, without any network or checkout of origin.
new_clone() {
  local name=$1 url=$2 dir path
  shift 2
  dir="$TMP_ROOT/$name"
  git init -q -b main "$dir"
  printf 'code\n' > "$dir/README.md"
  for path in "$@"; do
    mkdir -p "$dir/$(dirname "$path")"
    printf 'ci\n' > "$dir/$path"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  [ -z "$url" ] || git -C "$dir" remote add origin "$url"
  git -C "$dir" update-ref refs/remotes/origin/main HEAD
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  printf '%s\n' "$dir"
}

test_no_ci_on_known_forge_is_absent() {
  local clone out
  clone=$(new_clone gitlab-none git@gitlab.com:group/sub/project.git)
  out=$("$DETECT" "$clone") || fail "detection failed on a GitLab clone"
  [ "$out" = "ci=absent forge=gitlab" ] || fail "a GitLab clone with no CI files did not read absent: $out"

  clone=$(new_clone github-none https://github.com/owner/repo.git)
  out=$("$DETECT" "$clone") || fail "detection failed on a GitHub clone"
  [ "$out" = "ci=absent forge=github" ] || fail "a GitHub clone with no CI files did not read absent: $out"

  clone=$(new_clone gitlab-self-hosted ssh://git@gitlab.example.org:2222/group/project.git)
  out=$("$DETECT" "$clone") || fail "detection failed on a self-hosted GitLab clone"
  [ "$out" = "ci=absent forge=gitlab" ] || fail "a self-hosted gitlab-labelled host did not read absent: $out"
  pass "no CI files on a known GitHub or GitLab host reads absent"
}

test_each_ci_entry_is_present() {
  local entry clone out n=0
  for entry in .gitlab-ci.yml .github/workflows/ci.yml .github/workflows/deep/nested.yaml \
    .circleci/config.yml Jenkinsfile azure-pipelines.yml .travis.yml \
    bitbucket-pipelines.yml .drone.yml .buildkite/pipeline.yml; do
    n=$((n + 1))
    clone=$(new_clone "present-$n" git@gitlab.com:group/project.git "$entry")
    out=$("$DETECT" "$clone") || fail "detection failed for $entry"
    case "$out" in
      "ci=present evidence="*) ;;
      *) fail "$entry did not read present: $out" ;;
    esac
  done
  pass "each known CI entry reads present"
}

test_similar_names_are_not_ci() {
  local clone out
  clone=$(new_clone lookalike git@github.com:owner/repo.git .github/CODEOWNERS docs/Jenkinsfile .github/workflows-notes.md)
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with look-alike names"
  [ "$out" = "ci=absent forge=github" ] || fail "a look-alike name was read as CI: $out"
  pass "files that only resemble CI entries do not count"
}

test_ci_only_in_worktree_or_a_feature_branch_is_not_the_default_branch() {
  local clone out
  clone=$(new_clone feature-only git@github.com:owner/repo.git)
  git -C "$clone" checkout -q -b feature
  mkdir -p "$clone/.github/workflows"
  printf 'ci\n' > "$clone/.github/workflows/ci.yml"
  git -C "$clone" add -A
  git -C "$clone" commit -q -m 'add ci on a branch'
  out=$("$DETECT" "$clone") || fail "detection failed"
  [ "$out" = "ci=absent forge=github" ] || fail "CI on a non-default branch or the work tree changed the verdict: $out"
  pass "only the default branch tree is read"
}

test_doubt_reads_unknown_never_absent() {
  local clone out

  clone=$(new_clone unknown-host https://git.example.org/group/project.git)
  out=$("$DETECT" "$clone") || fail "detection failed on an unknown host"
  case "$out" in
    "ci=unknown reason="*) ;;
    *) fail "an unknown host did not read unknown: $out" ;;
  esac

  clone=$(new_clone gerrit-host ssh://someone@review.example:29418/group/project)
  out=$("$DETECT" "$clone") || fail "detection failed on a Gerrit host"
  case "$out" in
    "ci=unknown reason="*) ;;
    *) fail "a Gerrit origin did not read unknown: $out" ;;
  esac

  clone=$(new_clone no-origin "")
  out=$("$DETECT" "$clone") || fail "detection failed with no origin"
  case "$out" in
    "ci=unknown reason="*) ;;
    *) fail "a clone with no origin did not read unknown: $out" ;;
  esac

  clone=$(new_clone local-path-origin /srv/git/project.git)
  out=$("$DETECT" "$clone") || fail "detection failed on a local-path origin"
  case "$out" in
    "ci=unknown reason="*) ;;
    *) fail "a local-path origin did not read unknown: $out" ;;
  esac

  clone=$(new_clone lookalike-host https://notgithub.com/owner/repo.git)
  out=$("$DETECT" "$clone") || fail "detection failed on a look-alike host"
  case "$out" in
    "ci=unknown reason="*) ;;
    *) fail "a look-alike GitHub host did not read unknown: $out" ;;
  esac

  clone=$(new_clone unreadable-head git@github.com:owner/repo.git)
  git -C "$clone" symbolic-ref --delete refs/remotes/origin/HEAD
  out=$("$DETECT" "$clone") || fail "detection failed with no origin/HEAD"
  case "$out" in
    "ci=unknown reason="*) ;;
    *) fail "an unresolvable origin/HEAD did not read unknown: $out" ;;
  esac
  pass "an unknown host, missing origin, or unreadable default branch reads unknown"
}

test_detection_writes_nothing() {
  local clone before after
  clone=$(new_clone read-only git@github.com:owner/repo.git)
  before=$(git -C "$clone" for-each-ref | LC_ALL=C sort; git -C "$clone" config --list --local | LC_ALL=C sort)
  "$DETECT" "$clone" >/dev/null || fail "detection failed"
  after=$(git -C "$clone" for-each-ref | LC_ALL=C sort; git -C "$clone" config --list --local | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "detection changed the clone"
  pass "detection reads the clone and changes nothing"
}

test_not_a_clone_is_an_error() {
  local out rc
  mkdir -p "$TMP_ROOT/plain-dir"
  out=$("$DETECT" "$TMP_ROOT/plain-dir" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a plain directory did not exit 2 (got $rc)"
  assert_contains "$out" "not a git work tree" "the error did not say why"
  pass "a directory that is not a git work tree is refused with exit 2"
}

test_no_ci_on_known_forge_is_absent
test_each_ci_entry_is_present
test_similar_names_are_not_ci
test_ci_only_in_worktree_or_a_feature_branch_is_not_the_default_branch
test_doubt_reads_unknown_never_absent
test_detection_writes_nothing
test_not_a_clone_is_an_error
echo "# all fm-ci-detect tests passed"
