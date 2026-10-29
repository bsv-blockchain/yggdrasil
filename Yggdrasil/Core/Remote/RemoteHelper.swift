import Foundation

/// The `ygg` helper installed on each host at `~/.yggdrasil/bin/ygg`. It keeps
/// one dtach session per tab so agents outlive the ssh connection, and keeps
/// the ssh command lines the app sends short and fixed.
///
/// dtach rather than tmux: it passes bytes through untouched, so SwiftTerm's
/// native selection, links and scrollback keep working (see decisions.md on
/// why tmux was dropped). The app reinstalls the script whenever `version`
/// differs from what `ygg version` reports: before every tab spawn
/// (`ensureCurrentCommand`) and on preflight.
///
/// Everything runs under /bin/sh, never the user's login shell, so a fish or
/// tcsh login shell can't misparse it. The login shell is only asked for the
/// PATH its rc files set, via `env; exit`, whose output doesn't depend on the shell.
enum RemoteHelper {
    static let version = 3
    static let path = "~/.yggdrasil/bin/ygg"
    static let requiredTools = ["claude", "git", "gh", "dtach"]

    static let script = """
    #!/bin/sh
    # Yggdrasil remote session helper. Installed and overwritten by the app.
    #   ygg version | ygg check
    #   ygg attach <tab> <cwd> [--claude-session <id>] -- [<cmd> [args...]]
    #   ygg kill <tab> | ygg alive <tab> | ygg list
    #   ygg run -- <cmd> [args...]
    set -eu
    YGG_VERSION=\(version)
    TOOLS="\(requiredTools.joined(separator: " "))"
    STATE="$HOME/.yggdrasil/sessions"
    PATH_CACHE="$HOME/.yggdrasil/login-path"

    usage() { echo "usage: ygg version|check|attach|kill|alive|list|run" >&2; exit 2; }
    tab_ok() { case "$1" in ''|*[!0-9]*) usage ;; esac; }
    # Live = dtach still holds the tab's socket and the recorded agent pid
    # runs. dtach removes the socket when the agent exits, so a pid that's
    # been reused since never counts.
    alive() {
        [ -S "$STATE/$1.sock" ] && [ -f "$STATE/$1.pid" ] && kill -0 "$(cat "$STATE/$1.pid")" 2>/dev/null
    }
    # Put the PATH the user's login shell sets (where claude & co. tend to
    # live) in front of ssh's own, keeping the latter for dtach and friends.
    # stdin closed so an rc file can't sit waiting on it. `env; exit`, not
    # `env`: an interactive shell takes the tty's foreground group and only
    # hands it back when it exits itself. Given just `env` it execs env and
    # never does, which left dtach in a background group, unable to set raw
    # mode, and ended the session on its first read.
    login_path() {
        p=$("${SHELL:-/bin/sh}" -l -i -c 'env; exit' </dev/null 2>/dev/null | sed -n 's/^PATH=//p' | tail -n 1)
        if [ -n "$p" ]; then
            mkdir -p "$HOME/.yggdrasil"
            printf '%s\\n' "$p" > "$PATH_CACHE"
            PATH=$p:$PATH
        fi
        export PATH
    }
    # For `run`, which the app calls for every git command: reuse the PATH
    # check/attach last saw instead of starting a login shell each time.
    cached_login_path() {
        if [ -s "$PATH_CACHE" ]; then
            PATH=$(cat "$PATH_CACHE"):$PATH
            export PATH
        else
            login_path
        fi
    }

    case "${1:-}" in
    version)
        echo "$YGG_VERSION" ;;
    check)
        login_path
        for t in $TOOLS; do command -v "$t" >/dev/null 2>&1 || echo "missing:$t"; done ;;
    attach)
        [ $# -ge 4 ] || usage
        tab=$2; cwd=$3; shift 3
        tab_ok "$tab"
        session=
        if [ "$1" = --claude-session ]; then session=$2; shift 2; fi
        [ "$1" = -- ] || usage
        shift
        sock="$STATE/$tab.sock"
        # Reattaching needs nothing else, not even the worktree.
        if alive "$tab"; then exec dtach -a "$sock" -E -z -r winch; fi
        login_path
        # No command: the user's own shell (the remote "Open Shell").
        [ $# -gt 0 ] || set -- "${SHELL:-/bin/sh}" -l
        # --resume searches every project dir, so look in all of them.
        if [ -n "$session" ]; then
            if ls "$HOME"/.claude/projects/*/"$session".jsonl >/dev/null 2>&1; then
                set -- "$@" --resume "$session"
            else
                set -- "$@" --session-id "$session"
            fi
        fi
        mkdir -p "$STATE"
        cd "$cwd"
        # The wrapper records its pid, then execs into the agent: pid == agent.
        # -A also replaces a stale socket left by a dead session.
        exec dtach -A "$sock" -E -z -r winch \\
            /bin/sh -c 'echo $$ > "$0"; exec "$@"' "$STATE/$tab.pid" "$@" ;;
    kill)
        [ $# -eq 2 ] || usage
        tab=$2
        tab_ok "$tab"
        if alive "$tab"; then
            pid=$(cat "$STATE/$tab.pid")
            kill -TERM "$pid" 2>/dev/null || true
            i=0
            while kill -0 "$pid" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
            kill -KILL "$pid" 2>/dev/null || true
            # Wait for dtach to drop the socket, so an attach straight after
            # this starts a fresh session instead of joining the dying one.
            i=0
            while [ -S "$STATE/$tab.sock" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
            rm -f "${STATE:?}/${tab:?}.sock"
        fi
        rm -f "${STATE:?}/${tab:?}.pid" ;;
    alive)
        [ $# -eq 2 ] || usage
        tab_ok "$2"
        alive "$2" ;;
    list)
        for f in "$STATE"/*.pid; do
            [ -e "$f" ] || continue
            t=$(basename "$f" .pid)
            if alive "$t"; then echo "$t"; fi
        done ;;
    run)
        shift
        if [ "${1:-}" = -- ]; then shift; fi
        [ $# -gt 0 ] || usage
        cached_login_path
        exec "$@" ;;
    *)
        usage ;;
    esac
    """

    /// POSIX sh that (re)installs the script. Embedded as base64 so it needs no
    /// stdin plumbing. The temp file is per shell, so tabs spawning at the
    /// same time can't move each other's half-written copy into place.
    static var installCommand: String {
        let encoded = Data(script.utf8).base64EncodedString()
        let tmp = "\(path).tmp.$$"
        return "mkdir -p ~/.yggdrasil/bin && { printf %s '\(encoded)' | base64 -d > \(tmp)"
            + " && chmod 755 \(tmp) && mv \(tmp) \(path) || { rm -f \(tmp); false; }; }"
    }

    /// POSIX sh that installs the script unless the host already runs this
    /// version. Every tab spawn runs it first, so an app update reaches hosts
    /// set up by an older app without a preflight.
    static var ensureCurrentCommand: String {
        "[ \"$(\(path) version 2>/dev/null)\" = \(version) ] || { \(installCommand); }"
    }
}
