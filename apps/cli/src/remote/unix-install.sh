# $1 is the release tag, $2 is the script URL and $3 is the listing URL or
# the uploaded directory name. The shell receives them as literal arguments.
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GRAFFITTY_VERSION="$1" GRAFFITTY_NO_DESKTOP=1
# The installer's desktop update handoff must leave live servers alone.
export GRAFFITTY_SERVER_DESCRIPTOR="$tmp/server.json"
case "$3" in
    https://*) export GRAFFITTY_RELEASES="$3" ;;
    *) export GRAFFITTY_RELEASES="$HOME/$3"
       sh "$GRAFFITTY_RELEASES/install.sh"
       exit ;;
esac

if command -v curl >/dev/null 2>&1; then
    curl --proto '=https' -fsSL --connect-timeout 15 -o "$tmp/install.sh" "$2" || exit 75
else
    wget -q -O "$tmp/install.sh" "$2" || exit 75
fi
# Stream progress while preserving the installer's status on POSIX sh.
(sh "$tmp/install.sh" || echo "$?" > "$tmp/status") 2>&1 | tee "$tmp/log"
[ -f "$tmp/status" ] || exit 0
# Only a failed download warrants retrying with an uploaded archive. A
# checksum, storage or platform error should reach the user immediately.
if grep -Eq '^graffitty: error: (Graffitty .* is not listed at |could not download |curl or wget is required$)' "$tmp/log"; then
    exit 75
fi
exit 1
