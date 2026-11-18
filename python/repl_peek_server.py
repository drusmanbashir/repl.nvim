"""Answer `<M-k>` value peeks from inside the REPL, without touching its screen.

The editor's fallback peek PASTES a probe at the prompt, and a terminal echoes
whatever is pasted into it: one long line of scrollback per peek, for a feature
meant to be glanced at. This listens on a unix socket instead, so a peek costs
the REPL nothing visible at all.

Started by the REPL's own launcher (`ipython -i <this file>`; see
lua/repl/specs.lua and bin/slime-repl-restart), so it runs in the user
namespace -- `globals()` here IS what the operator typed into.

Wire: one request line (the expression) in; `ok\\n<repr>` or `err:<ExcType>`
out; then the connection closes. Same two answers the pasted probe writes, so
repl.peek parses one format either way.

Socket name is how the editor knows WHICH REPL it is talking to: the kitty
window id or the tmux pane the REPL is running in, both of which the editor
already stores as its slime binding. Lives under $XDG_RUNTIME_DIR (mode 700,
this user only) -- a socket that evaluates expressions must not be reachable by
another account, and there it is not.
"""


def __nvim_peek_boot():
    import os
    import socket
    import threading

    limit = int(os.environ.get("NVIM_REPL_PEEK_MAX_CHARS") or 4000)
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    directory = os.path.join(base, "nvim-peek")
    names = []
    window = os.environ.get("KITTY_WINDOW_ID")
    pane = os.environ.get("TMUX_PANE")
    if pane:
        # Inside tmux, KITTY_WINDOW_ID names the window the MULTIPLEXER runs in,
        # which other panes share -- claiming it would answer for them too.
        names.append("t%s.sock" % pane.lstrip("%"))
    elif window:
        names.append("k%s.sock" % window)
    if not names:
        # Not in a window the editor can name, so it could never find us.
        return

    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        return

    namespace = globals()

    def resolve():
        try:
            shell = get_ipython()  # noqa: F821 - IPython builtin
        except NameError:
            return namespace
        user_ns = getattr(shell, "user_ns", None)
        return user_ns if isinstance(user_ns, dict) else namespace

    def answer(expression):
        try:
            ns = resolve()
            return "ok\n" + repr(eval(compile(expression, "<peek>", "eval"), ns, ns))
        except BaseException as exc:  # noqa: BLE001 - every failure is one answer
            return "err:" + type(exc).__name__

    def serve(server):
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            try:
                conn.settimeout(5)
                request = b""
                while b"\n" not in request and len(request) < 65536:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    request += chunk
                expression = request.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
                if expression:
                    conn.sendall(answer(expression)[:limit].encode("utf-8", "replace"))
            except BaseException:  # noqa: BLE001 - one bad client never ends the server
                pass
            finally:
                try:
                    conn.close()
                except BaseException:  # noqa: BLE001
                    pass

    for name in names:
        path = os.path.join(directory, name)
        try:
            # A socket under our own window id can only be a dead REPL's.
            if os.path.exists(path):
                os.unlink(path)
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            os.chmod(path, 0o600)
            server.listen(4)
        except OSError:
            continue
        threading.Thread(target=serve, args=(server,), daemon=True).start()
        import atexit

        atexit.register(lambda p=path: os.path.exists(p) and os.unlink(p))


__nvim_peek_boot()
del __nvim_peek_boot
