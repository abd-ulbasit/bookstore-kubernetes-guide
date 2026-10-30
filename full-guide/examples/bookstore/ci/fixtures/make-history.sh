#!/usr/bin/env bash
# Build a throwaway git repository whose history holds credentials that the
# last commit deleted (Part 07 ch.03). Nothing here is a real token: both are
# fake and belong to no account, and they are assembled at run time so that no
# file in the guide holds one. Run it from anywhere:
#
#   make-history.sh DIR
#
# DIR is removed and recreated. The first commit adds a README and a .env with
# one token-shaped string per secret scanner (the same two shapes as
# vulnerable/config.env); the second commit deletes .env. The tree is then
# clean and the history is not, which is the case a scan of the files on disk
# cannot see.
set -euo pipefail

dir="${1:?usage: make-history.sh DIR}"
rm -rf "$dir"
mkdir -p "$dir"
git -C "$dir" init -q
g() { git -C "$dir" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"; }

echo "A service that once committed a credential." >"$dir/README"
{
  printf 'GITLEAKS_PLANT=ghp_%s\n' "$(printf 'NOTAREALTOKEN%.0s' 1 2 3)"
  printf 'TRUFFLEHOG_PLANT=ghp_%s\n' "$(printf 'FAKE%.0s' 1 2 3 4 5 6 7 8 9)"
} >"$dir/.env"
g add README .env
g commit -q -m "add the service and its config"

g rm -q .env
g commit -q -m "remove the credentials"
