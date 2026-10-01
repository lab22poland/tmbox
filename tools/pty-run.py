#!/usr/bin/env python3
"""Run a command under a real pty, feed it keystrokes, print what it drew.

The interactive half of the interface cannot be exercised from a normal build
step: lib/ui.zsh binds /dev/tty deliberately, so a test harness with no
controlling terminal sees the non-interactive fallback and proves nothing about
the path a user actually takes.

This gives the child a pty, types the supplied lines into it, and returns the
transcript. It is what makes the `curl … | zsh` case testable at all - the case
where stdin is the script and every prompt must therefore read from the tty.

    tools/pty-run.py --input 'mbp' --input '2' --input 'y' -- zsh script.zsh
    tools/pty-run.py --stdin-file script.zsh --input y -- zsh -s

--stdin-file pipes a file into the child's stdin while the pty stays attached
as the controlling terminal, which is exactly the shape of `curl | zsh`.
"""

import argparse
import os
import pty
import select
import signal
import sys
import termios
import time



def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", action="append", default=[],
                    help="a line to type; repeat, in order")
    ap.add_argument("--stdin-file",
                    help="pipe this file into the child's stdin (the curl|zsh shape)")
    ap.add_argument("--delay", type=float, default=0.35,
                    help="seconds to wait before typing each line")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=40)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
    if not cmd:
        print("pty-run: no command", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        # Child. A pty with no size set reports 0 columns, and the interface
        # falls back to its default width, so set one explicitly.
        os.environ["COLUMNS"] = str(args.cols)
        os.environ["LINES"] = str(args.rows)
        os.environ.setdefault("TERM", "xterm-256color")
        if args.stdin_file:
            # Replace stdin with the file while leaving the pty as the
            # controlling terminal. /dev/tty still resolves; a plain `read`
            # would consume the file. That is the whole point of the test.
            f = os.open(args.stdin_file, os.O_RDONLY)
            os.dup2(f, 0)
            os.close(f)
        os.execvp(cmd[0], cmd)
        os._exit(127)

    # Deliberately NOT tty.setraw(fd). On macOS the master and slave share the
    # termios state, so putting the master in raw mode clears ICRNL on the
    # slave; a typed "\r" then never becomes "\n", the shell's canonical-mode
    # `read` never sees a completed line, and every prompt hangs. Leaving the
    # line discipline alone costs an echo of the input in the transcript, which
    # is a fair trade for the prompts working at all.
    try:
        import fcntl
        import struct
        fcntl.ioctl(fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", args.rows, args.cols, 0, 0))
    except Exception:
        pass

    out = bytearray()
    pending = list(args.input)
    next_type = time.time() + args.delay
    deadline = time.time() + args.timeout

    while True:
        if time.time() > deadline:
            os.kill(pid, signal.SIGKILL)
            out += b"\n[pty-run: timed out]\n"
            break

        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk

        if pending and time.time() >= next_type:
            os.write(fd, pending.pop(0).encode() + b"\r")
            next_type = time.time() + args.delay

        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            # Drain whatever the child wrote just before exiting.
            while True:
                r, _, _ = select.select([fd], [], [], 0.2)
                if not r:
                    break
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            code = os.waitstatus_to_exitcode(status)
            sys.stdout.write(out.decode("utf-8", "replace"))
            sys.stdout.write(f"\n[pty-run: exit {code}]\n")
            return 0 if code == 0 else 1

    sys.stdout.write(out.decode("utf-8", "replace"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
