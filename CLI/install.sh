#!/bin/bash
# Links the `shirusu` command and the Claude skill from this checkout, so
# pulling the repo updates both. Run again any time; it only replaces links.
#
#   CLI/install.sh                 # ~/.local/bin and ~/.claude/skills
#   CLI/install.sh --bin /usr/local/bin
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
skills_dir="$HOME/.claude/skills"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin) bin_dir="${2:?--bin needs a folder}"; shift 2 ;;
        --skills) skills_dir="${2:?--skills needs a folder}"; shift 2 ;;
        *) echo "usage: $0 [--bin DIR] [--skills DIR]" >&2; exit 64 ;;
    esac
done

link() {
    local source="$1" target="$2"
    if [[ -e "$target" && ! -L "$target" ]]; then
        echo "Skipped $target: something that is not a link is already there." >&2
        return
    fi
    mkdir -p "$(dirname "$target")"
    ln -sfn "$source" "$target"
    echo "Linked $target"
}

link "$repo/CLI/shirusu" "$bin_dir/shirusu"
link "$repo/.claude/skills/shirusu" "$skills_dir/shirusu"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "Note: $bin_dir is not on your PATH." ;;
esac
