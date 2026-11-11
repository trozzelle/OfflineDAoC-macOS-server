#!/usr/bin/env bash
# daoc-server.sh - run a portable DAoC server folder on macOS. Everything lives next to this
# script, so the folder can be unpacked or moved anywhere. No .NET install is needed: bin/ is
# self-contained.
#
#   ./daoc-server.sh start            start the server in the background and open the admin
#                                     screen here (quit it with Ctrl+Q: stop the server or leave it running)
#   ./daoc-server.sh start --console  raw server console in the foreground instead (Ctrl+C, SIGTERM
#                                     or "exit" stop it); also used automatically without a terminal
#   ./daoc-server.sh start --detach   start in the background, wait until it is ready, and return
#                                     (no admin screen; the OfflineDAoC app uses this)
#   ./daoc-server.sh stop      stop a running server cleanly (saves first)
#   ./daoc-server.sh status    is it running?
#   ./daoc-admin               manage bots, population and accounts (terminal GUI or commands)
#
# Folder layout:
#   bin/        server program (replaced on upgrade)
#   defaults/   templates copied into config/ on first start
#   config/     serverconfig.xml, logconfig.xml, invalidnames.txt, and edition (written by daoc)
#               (yours; kept on upgrade)
#   data/       opendaoc.sqlite3.db: the world and all saves (yours; kept on upgrade). Created on
#               first start from defaults/world.sqlite (a fresh Classic + SI world) or, when
#               config/edition says sluaghbinder, defaults/world-sluaghbinder.sqlite.
#   navmesh/    zone*.nav, from ./navmesh-install.sh                  (kept on upgrade)
#   logs/  run/
#
# macOS port of the Linux repo's deploy/daoc-server.sh. Differences:
#   - ICU check: macOS ships libicu as part of the system since Sonoma 14.x; on older systems the
#     bundled .NET runtime carries its own ICU fallback, so no ldconfig-style check is needed.
#   - Port probe uses nc (no /dev/tcp on bash from Homebrew; /dev/tcp works in /bin/bash but nc
#     is more predictable across bash builds).
#   - setsid does not exist on macOS: the server is detached with nohup + disown instead (own
#     process group via POSIX process groups is not needed since the script only signals by PID).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAOC_HOME="${DAOC_HOME:-$HERE}"
PIDFILE="$DAOC_HOME/run/server.pid"
# shellcheck source=admin-socket.sh
. "$HERE/admin-socket.sh"
ADMIN_SOCKET=$(admin_socket "$DAOC_HOME")

die() { echo "daoc-server: $*" >&2; exit 1; }

running_pid() {
  local pid
  [[ -f $PIDFILE ]] || return 1
  pid=$(<"$PIDFILE")
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

# The game port from config/serverconfig.xml (10300 if not set yet).
game_port() {
  local port
  port=$(sed -n 's:.*<Port>\([0-9]*\)</Port>.*:\1:p' "$DAOC_HOME/config/serverconfig.xml" 2>/dev/null | head -1)
  echo "${port:-10300}"
}

port_in_use() { nc -z -w 1 127.0.0.1 "$(game_port)" >/dev/null 2>&1; }

# Is the server listening? The admin socket exists and the console log says so.
ready() {
  [[ -S $ADMIN_SOCKET ]] && grep -q "Server is now listening" "$DAOC_HOME/logs/console.out" 2>/dev/null
}

# Wait up to 180 s, one dot a second, for server $1 to be ready.
# Returns 0 ready, 1 the process died, 2 still not ready after 180 s.
wait_ready() {
  local pid=$1 i
  for ((i = 0; i < 180; i++)); do
    kill -0 "$pid" 2>/dev/null || return 1
    ready && return 0
    printf '.'
    sleep 1
  done
  return 2
}

start() {
  local mode=${1:-}
  # --detach: background start, wait until ready, return (the OfflineDAoC app).
  # --console, or no terminal (init system, redirect): run the raw server console in the foreground.
  local console=false detach=false
  if [[ $mode == --detach ]]; then
    detach=true
  elif [[ $mode == --console || ! -t 0 || ! -t 1 ]]; then
    console=true
  fi

  local pid rc
  if pid=$(running_pid); then
    if $detach; then
      # A server that is still booting (a terminal start, or a detached start that timed out)
      # is not ready yet: wait for it the way a fresh start does, but never kill it.
      printf 'already running (pid %s)' "$pid"
      wait_ready "$pid"; rc=$?
      echo
      [[ $rc == 0 ]] && exit 0
      if [[ $rc == 1 ]]; then echo "The server (pid $pid) stopped before it was ready."
      else echo "The server is not ready after 180 s."; fi >&2
      echo "Last lines of $DAOC_HOME/logs/console.out:" >&2
      tail -n 25 "$DAOC_HOME/logs/console.out" >&2
      exit 1
    fi
    $console && die "already running (pid $pid)"
    exec "$DAOC_HOME/daoc-admin"   # already running: just open the admin screen
  fi
  [[ -x $DAOC_HOME/bin/CoreServer ]] || die "no server program in $DAOC_HOME/bin"
  compgen -G "$DAOC_HOME/navmesh/*.nav" >/dev/null || die "no navmeshes yet. Rebuild the folder with daoc server install, or run ./navmesh-install.sh --from-dir <folder> (see README.md)"

  mkdir -p "$DAOC_HOME"/{config,data,logs,run}
  if [[ ! -f $DAOC_HOME/data/opendaoc.sqlite3.db ]]; then
    # config/edition (written by daoc) names the Edition a fresh world starts as; none: Classic.
    local edition world=world.sqlite
    edition=$(cat "$DAOC_HOME/config/edition" 2>/dev/null || echo classic)
    [[ $edition == sluaghbinder ]] && world=world-sluaghbinder.sqlite
    [[ -f $DAOC_HOME/defaults/$world ]] || die "no defaults/$world in this build; rebuild with daoc server install"
    echo "First start: creating a fresh world ($edition) in data/opendaoc.sqlite3.db"
    cp "$DAOC_HOME/defaults/$world" "$DAOC_HOME/data/opendaoc.sqlite3.db"
  fi
  for f in serverconfig.xml logconfig.xml invalidnames.txt; do
    [[ -e $DAOC_HOME/config/$f ]] || cp "$DAOC_HOME/defaults/$f" "$DAOC_HOME/config/"
  done
  ! port_in_use || die "port $(game_port) is already in use (another server is running; see <Port> in config/serverconfig.xml)"

  # The admin socket (used by ./daoc-admin): run/admin.sock, or a short path in the per-user
  # temp folder when that would be too long for a unix socket (see admin-socket.sh).
  export DAOC_ADMIN_SOCKET="$ADMIN_SOCKET"
  cd "$DAOC_HOME/bin"

  if $console; then
    echo $$ > "$PIDFILE"
    # exec keeps this PID, so the pid file and signals reach the server itself.
    exec ./CoreServer --start "-config=$DAOC_HOME/config/serverconfig.xml"
  fi

  # Default: server in the background (nohup so closing this terminal does not stop it),
  # then the admin screen in this terminal.
  local log="$DAOC_HOME/logs/console.out"
  [[ -f $log ]] && mv -f "$log" "$DAOC_HOME/logs/console.prev.out"
  nohup ./CoreServer --start "-config=$DAOC_HOME/config/serverconfig.xml" </dev/null >"$log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" > "$PIDFILE"
  printf 'Starting server (pid %s)' "$pid"
  wait_ready "$pid"; rc=$?
  echo
  if [[ $rc == 1 ]]; then
    echo "The server did not start. Last lines of $log:" >&2
    tail -n 25 "$log" >&2
    rm -f "$PIDFILE"
    exit 1
  fi
  if $detach; then
    if [[ $rc == 0 ]]; then
      echo "Server running (pid $pid)"
      exit 0
    fi
    echo "The server is not ready after 180 s. Last lines of $log:" >&2
    tail -n 25 "$log" >&2
    exit 1
  fi
  exec "$DAOC_HOME/daoc-admin"
}

stop() {
  local pid i
  pid=$(running_pid) || { echo "not running"; return 0; }
  kill -TERM "$pid"
  for ((i = 0; i < 120; i++)); do
    kill -0 "$pid" 2>/dev/null || { rm -f "$PIDFILE"; echo "stopped"; return 0; }
    sleep 1
  done
  die "server (pid $pid) did not stop within 120 s"
}

case "${1:-}" in
  start)  start "${2:-}" ;;
  stop)   stop ;;
  status) if pid=$(running_pid); then echo "running (pid $pid)"; else echo "stopped"; fi ;;
  *) echo "usage: $0 start [--console|--detach] | stop | status"; exit 2 ;;
esac