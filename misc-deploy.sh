#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'misc: %s\n' "$*" >&2; exit 1; }
[[ $# == 4 || $# == 5 ]] || fail 'Expected owner, repository, branch, transport and optional bundle ref.'
owner=$1
name=$2
branch=$3
transport=$4
bundle_ref=${5:-}
[[ $owner =~ ^[a-zA-Z0-9-]+$ && $name =~ ^[a-zA-Z0-9_.][a-zA-Z0-9_.-]*$ && $name != . && $name != .. ]] || fail 'Invalid GitHub repository.'
git check-ref-format --branch "$branch" >/dev/null
case $transport in
    ssh) url="git@github.com:$owner/$name.git" ;;
    https) url="https://github.com/$owner/$name.git" ;;
    *) fail 'Invalid transport.' ;;
esac
base=/var/www/phildogames/misc
target="$base/$name"
[[ -d $base && -w $base && -x $base ]] || fail "Need write and search permission on $base."
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes'

# Lock outside the web tree. Never list or change permissions on the misc directory.
umask 077
mkdir -p "$HOME/.cache/ai_mux"
exec 9>"$HOME/.cache/ai_mux/misc-$name.lock"
flock -n 9 || fail "Another deployment of $name is running."
source_url=$url
source_ref="refs/heads/$branch"
if [[ -n $bundle_ref ]]; then
    [[ $bundle_ref =~ ^refs/ai_mux/misc/[a-f0-9]{32}$ ]] || fail 'Invalid bundle ref.'
    bundle=$(mktemp "$HOME/.cache/ai_mux/incoming.XXXXXXXX.bundle")
    trap 'rm -f -- "$bundle"' EXIT
    cat > "$bundle"
    git bundle list-heads "$bundle" "$bundle_ref" | grep -q . || fail 'Bundle does not contain the requested ref.'
    source_url=$bundle
    source_ref=$bundle_ref
fi
[[ ! -L $target ]] || fail "Refusing symlink destination: $target"
if [[ -e $target ]]; then
    [[ -d $target/.git && ! -L $target/.git ]] || fail "Destination is not a standalone Git checkout: $target"
    cd "$target"
    actual=$(git rev-parse --show-toplevel)
    [[ $actual == "$(pwd -P)" ]] || fail 'Destination is not the repository root.'
    existing=$(git config --get remote.origin.url)
    # Compare repository identity across standard GitHub HTTPS and SSH URLs.
    case $existing in
        https://github.com/*) identity=${existing#https://github.com/} ;;
        git@github.com:*) identity=${existing#git@github.com:} ;;
        ssh://git@github.com/*) identity=${existing#ssh://git@github.com/} ;;
        *) fail 'Destination origin is not a supported GitHub URL.' ;;
    esac
    identity=${identity%/}
    identity=${identity%.git}
    [[ ${identity,,} == "${owner,,}/${name,,}" ]] || fail "Destination belongs to a different repository: $existing"
    [[ -z $(git status --porcelain --untracked-files=all) ]] || fail 'Server checkout has local changes; commit or remove them before deploying.'
    # Keep Git metadata inaccessible to nginx while leaving web files readable.
    chmod 700 .git
    umask 022
    if [[ -n $bundle_ref ]]; then
        git fetch --no-tags "$source_url" "$source_ref"
    else
        git fetch --no-tags origin "$source_ref"
    fi
    git rev-parse --verify HEAD >/dev/null
    git merge-base --is-ancestor HEAD FETCH_HEAD || fail 'Server HEAD is ahead of or diverges from the requested branch; resolve it manually.'
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git merge-base --is-ancestor "refs/heads/$branch" FETCH_HEAD || fail 'Server branch has divergent commits; resolve it manually.'
        git checkout "$branch"
    else
        git checkout -b "$branch" FETCH_HEAD
    fi
    git merge --ff-only FETCH_HEAD
else
    if [[ -z $bundle_ref ]]; then
        git ls-remote --exit-code --heads "$url" "$source_ref" >/dev/null
    fi
    # Keep a new checkout private until cloning finishes and .git has been protected.
    mkdir "$target"
    umask 022
    if [[ -n $bundle_ref ]]; then
        git init --quiet "$target"
        git -C "$target" fetch --no-tags "$source_url" "$source_ref"
        git -C "$target" checkout -b "$branch" FETCH_HEAD
        git -C "$target" remote add origin "$url"
    else
        git clone --single-branch --branch "$branch" -- "$url" "$target"
    fi
    chmod 700 "$target/.git"
    chmod 755 "$target"
    cd "$target"
fi
if [[ -n $bundle_ref ]]; then
    git update-ref "refs/remotes/origin/$branch" HEAD
    git config "branch.$branch.remote" origin
    git config "branch.$branch.merge" "refs/heads/$branch"
fi
printf '\nDeployed %s at %s\nhttp://phildogames.com/misc/%s/\n' "$(git rev-parse --short HEAD)" "$target" "$name"
