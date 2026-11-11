# admin-socket.sh - sourced by daoc-server.sh and daoc-admin: the admin socket's path.
#
# The socket lives in run/ next to the server, unless that path is too long for a
# unix socket (macOS: 104 bytes, sun_path), as it is under a deep data home such as
# ~/Library/Application Support/OfflineDAoC with a long user name. Then it is a short
# path in this user's private temp folder (getconf DARWIN_USER_TEMP_DIR: mode 0700, ends
# in "/"), named for this folder, so every script finds the same socket and no other
# user can pre-create it.
admin_socket() {
  local LC_ALL=C
  local path="$1/run/admin.sock"
  if (( ${#path} > 100 )); then
    path="$(getconf DARWIN_USER_TEMP_DIR)daoc-$(printf '%s' "$1" | cksum | cut -d' ' -f1).sock"
  fi
  printf '%s\n' "$path"
}
