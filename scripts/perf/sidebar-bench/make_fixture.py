"""Builds a realistic sidebar fixture in the running Phi Canary (seed.sh).

Expects the 150 plain tabs open in the Default Space of the frontmost Canary,
and the fixture server on 127.0.0.1:8765. Adds, through the UI (Accessibility
to read rows, posted clicks for context menus, typing to pick menu items):
  Default Space: 6 tab groups of 5, 6 split pairs, 6 pinned tabs, 12 bookmarks
  Spaces "Bench B" and "Bench C": 30 tabs each, 2 groups of 4, 2 splits, 2 pins

usage: python3 -I make_fixture.py <mouse-tool> [all|spaces|default]
"""
import subprocess
import sys
import time

MOUSE = sys.argv[1]
PROC = '(first process whose bundle identifier is "com.phibrowser.canary.Mac")'
WIN = f'(first window of {PROC} whose subrole is "AXStandardWindow")'
SG = f'(first UI element of {WIN} whose role is "AXSplitGroup")'
SA = f'scroll area 1 of {SG}'
OL = f'outline 1 of {SA}'
BAR = f'scroll bar 1 of {SA}'


def osa(script):
    r = subprocess.run(['osascript', '-e', f'tell application "System Events"\n{script}\nend tell'],
                       capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def front():
    osa(f'set frontmost of {PROC} to true')
    time.sleep(0.3)


def mouse(kind, x, y):
    subprocess.run([MOUSE, kind, str(int(x)), str(int(y))], check=True)


def rows():
    """[(title, x, y, w, h)] of the current Space's outline rows."""
    out = osa(f'''
set res to ""
set ol to {OL}
set n to count of rows of ol
repeat with i from 1 to n
  set r to row i of ol
  set t to ""
  try
    set t to value of static text 1 of UI element 1 of UI element 1 of r
  end try
  set {{px, py}} to position of r
  set {{sw, sh}} to size of r
  set res to res & t & "|" & px & "|" & py & "|" & sw & "|" & sh & linefeed
end repeat
return res''')
    result = []
    for line in out.splitlines():
        t, x, y, w, h = line.rsplit('|', 4)
        result.append((t, float(x), float(y), float(w), float(h)))
    return result


def visible_row(title):
    """Scrolls the row titled `title` into view and returns its centre."""
    for _ in range(3):
        rs = rows()
        match = [r for r in rs if r[0] == title]
        if not match:
            raise RuntimeError(f'no row titled {title!r}')
        _, x, y, w, h = match[0]
        area = osa(f'get {{position, size}} of {SA}').replace(' ', '').split(',')
        ax, ay, aw, ah = map(float, area)
        if ay + 4 <= y and y + h <= ay + ah - 4:
            return x + min(70, w / 2), y + h / 2
        ol = osa(f'get {{position, size}} of {OL}').replace(' ', '').split(',')
        oy, oh = float(ol[1]), float(ol[3])
        offset = y - oy
        value = max(0.0, min(1.0, (offset - ah / 2) / max(1.0, oh - ah)))
        osa(f'set value of {BAR} to {value}')
        time.sleep(0.4)
    raise RuntimeError(f'could not scroll {title!r} into view')


def context(title, *keys):
    """Right-clicks the tab and picks a context-menu item by typing its name;
    a second key picks an item in that item's submenu."""
    front()
    x, y = visible_row(title)
    mouse('right', x, y)
    time.sleep(0.6)
    osa(f'keystroke "{keys[0]}"')
    time.sleep(0.25)
    if len(keys) > 1:
        osa('key code 124')
        time.sleep(0.4)
        osa(f'keystroke "{keys[1]}"')
        time.sleep(0.25)
    osa('key code 36')
    time.sleep(0.8)
    mouse('move', 900, 650)


def activate(title):
    front()
    x, y = visible_row(title)
    mouse('left', x, y)
    time.sleep(0.6)


def page(n):
    return f'Bench page {n:03d}'


def group_colors():
    """Colour names of the group headers ("Blue · 4 tabs"). A new group takes
    a colour no other group has; header counts can lag, so match on colour."""
    return {t.split(' · ')[0] for t, *_ in rows() if ' · ' in t and t.endswith(' tabs')}


def make_group(first, count):
    before = group_colors()
    context(page(first), 'New Tab Group')
    new = group_colors() - before
    if len(new) != 1:
        raise RuntimeError(f'new group header not found: {new}')
    color = new.pop()
    for n in range(first + 1, first + count):
        context(page(n), 'Add to Group', color)
    print(f'group {color}: {page(first)}..{page(first + count - 1)}', flush=True)


def make_split(a, b):
    activate(page(a))
    context(page(b), 'Split with Current')
    print(f'split {page(a)} + {page(b)}', flush=True)


def open_tabs(numbers):
    """Opens the pages as tabs; a page whose tab did not appear (a keystroke
    lost while the window was still settling) is opened again."""
    present = {r[0] for r in rows()}
    wanted = [n for n in numbers if page(n) not in present]
    for _ in range(3):
        if not wanted:
            return
        front()
        for n in wanted:
            osa('keystroke "t" using command down')
            time.sleep(0.6)
            osa(f'keystroke "127.0.0.1:8765/p{n:03d}.html"')
            time.sleep(0.15)
            osa('key code 36')
            time.sleep(0.7)
        time.sleep(2)
        titles = {r[0] for r in rows()}
        wanted = [n for n in wanted if page(n) not in titles]
        if not wanted:
            return
    raise RuntimeError(f'tabs did not open: {wanted}')


def new_space(name):
    front()
    osa(f'click menu item "New Space…" of menu 1 of menu bar item "Spaces" of menu bar 1 of {PROC}')
    time.sleep(1.2)
    osa(f'keystroke "{name}"')
    time.sleep(0.3)
    osa('key code 36')
    time.sleep(3)


def switch_space(name):
    front()
    osa(f'click menu item "{name}" of menu 1 of menu bar item "Spaces" of menu bar 1 of {PROC}')
    time.sleep(2)


def build_side_space(name, create=True):
    if create:
        new_space(name)
    open_tabs(range(1, 31))
    make_group(1, 4)
    make_group(5, 4)
    make_split(9, 10)
    make_split(11, 12)
    for n in (13, 14):
        context(page(n), 'Pin')
    print(f'space {name} done', flush=True)


def build_default_space():
    switch_space('Default')
    for g in range(6):
        make_group(1 + g * 5, 5)
    for a in range(31, 43, 2):
        make_split(a, a + 1)
    for n in range(43, 49):
        context(page(n), 'Pin')
    for n in range(49, 61):
        context(page(n), 'Add to Bookmark')
    osa(f'set value of {BAR} to 0')
    mouse('move', 900, 650)
    print('space Default done', flush=True)


if __name__ == '__main__':
    stage = sys.argv[2] if len(sys.argv) > 2 else 'all'
    if stage in ('all', 'spaces'):
        build_side_space('Bench B')
        build_side_space('Bench C')
    if stage in ('all', 'default'):
        build_default_space()
