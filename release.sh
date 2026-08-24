#!/usr/bin/env bash

set -euo pipefail

VERSION_FILE="version.json"
DEVELOPMENT_BRANCH="development"
PRODUCTION_BRANCH="master"
RELEASE_PREFIX="release/"
REMOTE="origin"
REMOTE_REFS=""

fail() {
    echo "Release failed: $*" >&2
    exit 1
}

usage() {
    echo "Usage:"
    echo "  bash release.sh start"
    echo "  bash release.sh finish"
    echo
    echo "start  creates and pushes the release branch, then bumps development."
    echo "finish merges the release branch into master, tags it, and deletes the branch."
}

ask_with_default() {
    local label="$1"
    local default_value="$2"
    local answer=""
    local prompt="? $label: "
    local placeholder="($default_value)"
    local key=""
    local old_stty=""

    if [[ ! -t 0 ]]; then
        IFS= read -r answer || true
        echo "${answer:-$default_value}"
        return 0
    fi

    render_prompt() {
        if [[ -z "$answer" ]]; then
            printf '\r%s\033[2m%s\033[0m\033[0K\033[%dD' "$prompt" "$placeholder" "${#placeholder}" >&2
        else
            printf '\r%s%s\033[0K' "$prompt" "$answer" >&2
        fi
    }

    old_stty="$(stty -g)"
    trap 'stty "$old_stty"; printf "\n" >&2; exit 130' INT
    stty -echo -icanon time 0 min 1

    render_prompt

    while IFS= read -r -s -N 1 key; do
        case "$key" in
            $'\r'|$'\n')
                break
                ;;
            $'\177'|$'\b')
                answer="${answer%?}"
                ;;
            $'\003')
                stty "$old_stty"
                printf '\n' >&2
                exit 130
                ;;
            $'\033')
                while IFS= read -r -s -N 1 -t 0.001 key; do
                    :
                done
                ;;
            *)
                answer="${answer}${key}"
                ;;
        esac

        render_prompt
    done

    stty "$old_stty"
    trap - INT
    printf '\n' >&2
    echo "${answer:-$default_value}"
}

validate_release_version() {
    local version="$1"

    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "Validation error: Version must match number.number.number, got: $version"
}

validate_next_version() {
    local version="$1"

    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-SNAPSHOT$ ]] \
        || fail "Validation error: Next version must match number.number.number-SNAPSHOT, got: $version"
}

ensure_version_file() {
    [[ -f "$VERSION_FILE" ]] || fail "$VERSION_FILE was not found."
}

read_version_from_content() {
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

read_version() {
    local version
    version="$(read_version_from_content < "$VERSION_FILE")"
    [[ -n "$version" ]] || fail "$VERSION_FILE must contain a string \"version\" field."
    echo "$version"
}

read_version_from_branch() {
    local branch="$1"
    local version
    version="$(git show "${branch}:${VERSION_FILE}" | read_version_from_content)"
    [[ -n "$version" ]] || fail "${branch}:${VERSION_FILE} must contain a string \"version\" field."
    echo "$version"
}

write_version() {
    local version="$1"
    printf '{\n    "version": "%s"\n}\n' "$version" > "$VERSION_FILE"
}

strip_snapshot() {
    local version="$1"
    echo "${version%-SNAPSHOT}"
}

next_snapshot_version() {
    local version="$1"

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))-SNAPSHOT"
    else
        echo "${version}-SNAPSHOT"
    fi
}

current_branch() {
    git branch --show-current
}

ref_exists() {
    git show-ref --verify --quiet "$1"
}

branch_exists() {
    ref_exists "refs/heads/$1"
}

remote_branch_exists() {
    [[ -n "$(remote_branch_commit "$1")" ]]
}

load_remote_refs() {
    if ! REMOTE_REFS="$(git ls-remote --heads --tags "$REMOTE")"; then
        fail "Could not query remote refs from $REMOTE."
    fi
}

remote_ref_commit() {
    local ref="$1"
    printf '%s\n' "$REMOTE_REFS" | awk -v ref="$ref" '$2 == ref { print $1; exit }'
}

remote_branch_commit() {
    local branch="$1"
    remote_ref_commit "refs/heads/$branch"
}

remote_tag_exists() {
    local tag="$1"
    [[ -n "$(remote_ref_commit "refs/tags/$tag")" ]]
}

local_release_branches() {
    git for-each-ref --format='%(refname:short)' refs/heads \
        | awk -v prefix="$RELEASE_PREFIX" 'index($0, prefix) == 1 { print }' \
        | sort -V
}

sync_release_branch() {
    local release_branch="$1"

    if remote_branch_exists "$release_branch"; then
        git fetch "$REMOTE" "refs/heads/${release_branch}:refs/heads/${release_branch}"
        return 0
    fi

    branch_exists "$release_branch" || fail "Release branch $release_branch does not exist locally or on $REMOTE."
}

format_branch_list() {
    awk 'NF { branches = branches (branches ? ", " : "") $0 } END { print branches }'
}

ensure_no_local_release_branches() {
    local branches
    branches="$(local_release_branches)"

    if [[ -n "$branches" ]]; then
        fail "Validation error: Local release branch already exists: $(printf '%s\n' "$branches" | format_branch_list). Finish or delete it before starting another release."
    fi
}

single_local_release_branch() {
    local branches
    local count

    branches="$(local_release_branches)"
    count="$(printf '%s\n' "$branches" | awk 'NF { count++ } END { print count + 0 }')"

    case "$count" in
        0)
            fail "Validation error: Expected exactly one local release branch, found none."
            ;;
        1)
            printf '%s\n' "$branches"
            ;;
        *)
            fail "Validation error: Expected exactly one local release branch, found $count: $(printf '%s\n' "$branches" | format_branch_list)."
            ;;
    esac
}

ensure_clean_working_tree() {
    local status
    status="$(git status --porcelain)"

    [[ -z "$status" ]] || fail "Working tree is not clean. Commit or stash your changes before releasing."
}

ensure_current_branch() {
    local expected="$1"
    local actual
    actual="$(current_branch)"

    [[ "$actual" == "$expected" ]] || fail "Expected to be on $expected, but current branch is ${actual:-"(detached HEAD)"}."
}

ensure_branch_not_behind_remote() {
    local branch="$1"
    local local_commit
    local remote_commit
    local base

    remote_commit="$(remote_branch_commit "$branch")"
    [[ -n "$remote_commit" ]] || return 0

    local_commit="$(git rev-parse "$branch")"

    [[ "$local_commit" == "$remote_commit" ]] && return 0

    base="$(git merge-base "$branch" "$remote_commit")"

    if [[ "$base" == "$local_commit" ]]; then
        fail "$branch is behind ${REMOTE}/${branch}. Pull or rebase before releasing."
    fi

    if [[ "$base" != "$remote_commit" ]]; then
        fail "$branch has diverged from ${REMOTE}/${branch}. Resolve it before releasing."
    fi
}

ensure_tag_does_not_exist() {
    local tag="$1"

    if ref_exists "refs/tags/$tag"; then
        fail "Tag $tag already exists."
    fi

    if remote_tag_exists "$tag"; then
        fail "Remote tag $tag already exists."
    fi
}

commit_if_changed() {
    local message="$1"
    local diff
    diff="$(git status --porcelain -- "$VERSION_FILE")"

    if [[ -z "$diff" ]]; then
        echo "No $VERSION_FILE change to commit for: $message"
        return 0
    fi

    git add "$VERSION_FILE"
    git commit -m "$message"
}

merge_release_into_production() {
    local release_branch="$1"
    local release_version="$2"
    local conflicts
    local conflict
    local merge_output
    local only_version_conflict="true"

    set +e
    merge_output="$(git merge --no-ff --no-commit "$release_branch" 2>&1)"
    local merge_status=$?
    set -e

    if [[ $merge_status -ne 0 ]]; then
        conflicts="$(git diff --name-only --diff-filter=U)"

        if [[ -z "$conflicts" ]]; then
            [[ -z "$merge_output" ]] || printf '%s\n' "$merge_output"
            fail "Merge failed and no conflicted files were reported."
        fi

        while IFS= read -r conflict; do
            [[ "$conflict" == "$VERSION_FILE" ]] || only_version_conflict="false"
        done <<< "$conflicts"

        if [[ "$only_version_conflict" != "true" ]]; then
            [[ -z "$merge_output" ]] || printf '%s\n' "$merge_output"
            fail "Merge conflicts need manual resolution before finishing: $conflicts"
        fi

        echo "Resolving $VERSION_FILE conflict with release version $release_version"
    else
        [[ -z "$merge_output" ]] || printf '%s\n' "$merge_output"
    fi

    write_version "$release_version"
    git add "$VERSION_FILE"

    conflicts="$(git diff --name-only --diff-filter=U)"
    [[ -z "$conflicts" ]] || fail "Merge conflicts need manual resolution before finishing: $conflicts"

    git commit -m "Merge branch '${release_branch}'"
}

release_start() {
    ensure_version_file
    ensure_no_local_release_branches

    local release_version
    local next_version
    local release_branch
    local current_version
    local default_release_version

    current_version="$(read_version)"
    default_release_version="$(strip_snapshot "$current_version")"

    release_version="$(ask_with_default "Release version" "$default_release_version")"
    validate_release_version "$release_version"

    next_version="$(next_snapshot_version "$release_version")"
    validate_next_version "$next_version"

    release_branch="${RELEASE_PREFIX}${release_version}"

    ensure_clean_working_tree
    ensure_current_branch "$DEVELOPMENT_BRANCH"
    load_remote_refs
    ensure_branch_not_behind_remote "$DEVELOPMENT_BRANCH"
    ensure_branch_not_behind_remote "$PRODUCTION_BRANCH"
    ensure_tag_does_not_exist "$release_version"

    if branch_exists "$release_branch" || remote_branch_exists "$release_branch"; then
        fail "Release branch $release_branch already exists."
    fi

    echo
    echo "Creating $release_branch from $DEVELOPMENT_BRANCH"
    git checkout -b "$release_branch"
    write_version "$release_version"
    commit_if_changed "Prepare release $release_version"

    echo
    echo "Bumping $DEVELOPMENT_BRANCH to $next_version"
    git checkout "$DEVELOPMENT_BRANCH"
    write_version "$next_version"
    commit_if_changed "Prepare for next release"

    git push "$REMOTE" "$release_branch" "$DEVELOPMENT_BRANCH"

    echo
    echo "Release $release_version started."
    echo "Created branch: $release_branch"
    echo "Development version: $next_version"
    echo "Wait for Jenkins, then run: bash release.sh finish"
}

release_finish() {
    ensure_version_file

    local release_version
    local release_branch
    local branch_version

    release_branch="$(single_local_release_branch)"
    release_version="${release_branch#${RELEASE_PREFIX}}"
    validate_release_version "$release_version"

    ensure_clean_working_tree
    ensure_current_branch "$DEVELOPMENT_BRANCH"
    load_remote_refs
    ensure_branch_not_behind_remote "$DEVELOPMENT_BRANCH"
    ensure_branch_not_behind_remote "$PRODUCTION_BRANCH"
    ensure_tag_does_not_exist "$release_version"
    sync_release_branch "$release_branch"

    branch_version="$(read_version_from_branch "$release_branch")"
    [[ "$branch_version" == "$release_version" ]] \
        || fail "$release_branch contains version $branch_version, expected $release_version."

    echo
    echo "Merging $release_branch into $PRODUCTION_BRANCH"
    git checkout "$PRODUCTION_BRANCH"
    merge_release_into_production "$release_branch" "$release_version"
    git tag -a "$release_version" -m "Release $release_version"

    git push "$REMOTE" "$PRODUCTION_BRANCH" "refs/tags/${release_version}" ":refs/heads/${release_branch}"
    git branch -d "$release_branch"
    git checkout "$DEVELOPMENT_BRANCH"

    echo
    echo "Release $release_version finished."
    echo "Created tag: $release_version"
    echo "Deleted branch: $release_branch"
}

main() {
    local command="${1:-}"

    case "$command" in
        start)
            [[ $# -eq 1 ]] || {
                usage
                exit 1
            }
            release_start
            ;;
        finish)
            [[ $# -eq 1 ]] || {
                usage
                exit 1
            }
            release_finish
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
