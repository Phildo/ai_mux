#!/usr/bin/env bash
# Run on Linux: bash tests/misc-deploy.tests.sh ./misc-deploy.sh [direct|bundle]
set -euo pipefail
mode=${2:-direct}
temp=$(mktemp -d /tmp/ai-mux-misc-tests.XXXXXXXX)
cleanup() {
    case $temp in /tmp/ai-mux-misc-tests.*) chmod 700 "$temp/misc"; rm -rf -- "$temp" ;; esac
}
trap cleanup EXIT
export HOME="$temp/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$temp/misc" "$temp/source"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" AI_MUX_TEST_BASE="$temp/misc"
sed 's|^base=/var/www/phildogames/misc$|base="$AI_MUX_TEST_BASE"|' "$1" > "$temp/deploy.sh"
git config --global user.name 'ai_mux test'
git config --global user.email 'test@example.invalid'
git config --global commit.gpgsign false
git config --global protocol.file.allow always
if [[ $mode == direct ]]; then
    git config --global "url.$temp/remote.git.insteadOf" https://github.com/test/sample.git
fi
git init -q --bare "$temp/remote.git"
git -C "$temp/source" init -q -b main
printf 'first\n' > "$temp/source/index.html"
git -C "$temp/source" add .
git -C "$temp/source" commit -qm first
git -C "$temp/source" remote add origin "$temp/remote.git"
git -C "$temp/source" push -q origin main
chmod 333 "$temp/misc"
deploy() {
    if [[ $mode == bundle ]]; then
        ref=refs/ai_mux/misc/0123456789abcdef0123456789abcdef
        git --git-dir="$temp/remote.git" update-ref "$ref" "refs/heads/${1:-main}" || return
        git --git-dir="$temp/remote.git" bundle create "$temp/input.bundle" "$ref" || return
        bash "$temp/deploy.sh" test sample "${1:-main}" https "$ref" < "$temp/input.bundle"
    else
        bash "$temp/deploy.sh" test sample "${1:-main}" https
    fi
}
expect_failure() {
    if "$@" > "$temp/failure.log" 2>&1; then echo 'Expected failure' >&2; exit 1; fi
}
deploy
[[ $(stat -c %a "$temp/misc") == 333 ]]
[[ $(stat -c %a "$temp/misc/sample/.git") == 700 ]]
[[ $(stat -c %a "$temp/misc/sample") == 755 ]]
[[ $(cat "$temp/misc/sample/index.html") == first ]]
printf 'second\n' > "$temp/source/index.html"
git -C "$temp/source" commit -qam second
git -C "$temp/source" push -q origin main
deploy
[[ $(cat "$temp/misc/sample/index.html") == second ]]
deploy # Already current.
printf 'local edit\n' > "$temp/misc/sample/index.html"
expect_failure deploy
[[ $(cat "$temp/misc/sample/index.html") == 'local edit' ]]
git -C "$temp/misc/sample" restore index.html
touch "$temp/misc/sample/untracked"
expect_failure deploy
rm "$temp/misc/sample/untracked"
expect_failure deploy missing-branch
git -C "$temp/misc/sample" remote set-url origin https://github.com/other/sample.git
expect_failure deploy
git -C "$temp/misc/sample" remote set-url origin https://github.com/test/sample.git
# Branch names containing shell metacharacters must remain literal.
branch="feature/quote'\$(touch_INJECTION);test"
git -C "$temp/source" checkout -qb "$branch"
git -C "$temp/source" commit -qm feature --allow-empty
git -C "$temp/source" push -q origin "$branch"
deploy "$branch"
[[ $(git -C "$temp/misc/sample" branch --show-current) == "$branch" ]]
git -C "$temp/misc/sample" commit -qm 'server only' --allow-empty
before=$(git -C "$temp/misc/sample" rev-parse HEAD)
expect_failure deploy "$branch"
[[ $(git -C "$temp/misc/sample" rev-parse HEAD) == "$before" ]]
mv "$temp/misc/sample" "$temp/saved"
ln -s "$temp/saved" "$temp/misc/sample"
expect_failure deploy
rm "$temp/misc/sample"
mkdir "$temp/misc/sample"
expect_failure deploy
[[ $(stat -c %a "$temp/misc") == 333 ]]
printf 'PASS: clone, fast-forward, repeat, mode 333, Git metadata permissions, dirty/untracked refusal, missing branch, identity mismatch, literal branch, divergence, symlink and non-repository refusal.\n'
