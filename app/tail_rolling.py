#!/usr/bin/env python3
"""Rolling terminal display: keeps only the last N lines visible, removing older ones."""
import sys
import collections
import subprocess

LINES = 30

def main():
    if len(sys.argv) < 2:
        print("Usage: tail_rolling.py <file>")
        sys.exit(1)

    filepath = sys.argv[1]
    buf = collections.deque(maxlen=LINES)

    proc = subprocess.Popen(
        ["tail", "-n", str(LINES), "-f", filepath],
        stdout=subprocess.PIPE, text=True
    )
    try:
        for line in proc.stdout:
            buf.append(line.rstrip())
            print("\033[2J\033[H" + "\n".join(buf), flush=True)
    except KeyboardInterrupt:
        proc.terminate()

if __name__ == "__main__":
    main()
