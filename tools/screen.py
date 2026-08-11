#!/usr/bin/env python3
"""Render a captured ANSI stream into the grid the handheld would actually show.

Stripping escape codes with sed collapses cursor-positioned output into one
unreadable line, which hides every layout bug. This applies the cursor moves
instead, so we see the real screen.

    expect tools/drive.exp <appdir> "<keys>" | tools/screen.py [rows] [cols]
"""
import re
import sys

rows = int(sys.argv[1]) if len(sys.argv) > 1 else 15
cols = int(sys.argv[2]) if len(sys.argv) > 2 else 40

grid = [[" "] * cols for _ in range(rows)]
inv = [[False] * cols for _ in range(rows)]
cy = cx = 0
reverse = False

data = sys.stdin.buffer.read().decode("utf-8", "replace")
token = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")

i = 0
while i < len(data):
    m = token.match(data, i)
    if m:
        args, cmd = m.group(1), m.group(2)
        nums = [int(n) for n in args.split(";") if n.isdigit()]
        if cmd == "H":
            cy = (nums[0] - 1) if nums else 0
            cx = (nums[1] - 1) if len(nums) > 1 else 0
        elif cmd == "J":
            grid = [[" "] * cols for _ in range(rows)]
            inv = [[False] * cols for _ in range(rows)]
            if not nums or nums[0] == 2:
                cy = cx = 0
        elif cmd == "K":
            if 0 <= cy < rows:
                for x in range(cx, cols):
                    grid[cy][x] = " "
                    inv[cy][x] = False
        elif cmd == "m":
            if not nums or 0 in nums:
                reverse = False
            if 7 in nums:
                reverse = True
        i = m.end()
        continue

    ch = data[i]
    i += 1
    if ch == "\n":
        cy += 1
        cx = 0
    elif ch == "\r":
        cx = 0
    elif ch in ("\x1b", "\x07", "\x00"):
        continue
    else:
        if 0 <= cy < rows and 0 <= cx < cols:
            grid[cy][cx] = ch
            inv[cy][cx] = reverse
        cx += 1
        if cx >= cols:
            cx = 0
            cy += 1

print("+" + "-" * cols + "+")
for y in range(rows):
    line = "".join(grid[y])
    # Mark the reverse-video run so selection is visible in plain text.
    if any(inv[y]):
        s = next(x for x in range(cols) if inv[y][x])
        e = max(x for x in range(cols) if inv[y][x])
        line = line[:s] + "\033[7m" + line[s:e + 1] + "\033[0m" + line[e + 1:]
        line = line.replace("\033[7m", "«").replace("\033[0m", "»")
    print("|" + line.ljust(cols + line.count("«") + line.count("»"))[:cols + 2] + "|")
print("+" + "-" * cols + "+")
