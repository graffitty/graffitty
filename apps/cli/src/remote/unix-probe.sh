# The launcher may be outside PATH in a noninteractive SSH session.
for candidate in "$@"; do
    [ -x "$candidate" ] || continue
    if actual=$("$candidate" --version 2>/dev/null) && [ "$actual" = "$expected" ]; then
        printf 'installed\n%s\n' "$candidate"
        exit 0
    fi
done

# An executable uploaded for an earlier session can already be gone. Check
# the same exclusive flock as gft server --status before touching an install.
state="${XDG_STATE_HOME:-$HOME/.local/state}/graffitty"
[ -f "$state/server.json" ] && [ -f "$state/server.lock" ] || exit 0
if command -v flock >/dev/null 2>&1; then
    flock -n -E 75 "$state/server.lock" true
    [ "$?" = 75 ] || exit 0
elif command -v perl >/dev/null 2>&1; then
    perl -MFcntl=:flock -MErrno=EWOULDBLOCK -e '
        open my $lock, "<", $ARGV[0] or exit 1;
        exit 1 if flock($lock, LOCK_EX | LOCK_NB);
        exit($! == EWOULDBLOCK ? 0 : 1);
    ' "$state/server.lock" || exit 0
else
    exit 0
fi
printf 'running\n'
