set -eu
umask 077
state="${XDG_STATE_HOME:-$HOME/.local/state}/graffitty"
mkdir -p "$state"
if [ -s "$state/server.json" ] && "$server" server --connection "$state/server.json" --status >/dev/null 2>&1; then exec "$server" server --connection "$state/server.json" --ssh-attach; fi
nohup "$server" server --ssh-owner --connection "$state/server.json" >"$state/server.log" 2>&1 </dev/null &
i=0
while [ "$i" -lt 100 ]; do
    if [ -s "$state/server.json" ] && "$server" server --connection "$state/server.json" --status >/dev/null 2>&1; then exec "$server" server --connection "$state/server.json" --ssh-attach; fi
    i=$((i+1))
    sleep 0.1
done
cat "$state/server.log" >&2
exit 1
