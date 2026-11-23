set -eu
umask 077
state="$HOME/.local/state/graffitty"
mkdir -p "$state"
if [ -s "$state/server.json" ] && "$server" server --connection "$state/server.json" --status 2>/dev/null; then exit 0; fi
nohup "$server" server --listen 127.0.0.1:0 --connection "$state/server.json" >"$state/server.log" 2>&1 </dev/null &
i=0
while [ "$i" -lt 100 ]; do
    if [ -s "$state/server.json" ] && "$server" server --connection "$state/server.json" --status 2>/dev/null; then exit 0; fi
    i=$((i+1))
    sleep 0.1
done
cat "$state/server.log" >&2
exit 1
