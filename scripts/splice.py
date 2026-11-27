"""Dev helper: replace a region of a file between two markers with the contents of another file.
usage: splice.py FILE START_MARKER END_MARKER REPLACEMENT_FILE"""
import sys

f, start, end, repl = sys.argv[1:5]
s = open(f, encoding="utf8").read()
a = s.index(start)
b = s.index(end, a)
s = s[:a] + open(repl, encoding="utf8").read() + s[b:]
open(f, "w", encoding="utf8").write(s)
