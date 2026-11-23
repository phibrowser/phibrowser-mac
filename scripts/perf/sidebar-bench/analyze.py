"""Summarizes bench rounds in out/: main-thread cost of the sidebar toggle and
scroll scenarios, per build.

usage: python3 -I analyze.py <baseline-label> <candidate-label> [out-dir]

Every time-profile sample is 1ms of one thread. Only the main thread counts.
The window is the driver's: 2.5s to 19.5s into the 20s recording (the driver
starts at 3s). Ops: 24 toggles, or 400 scroll steps. A busy stretch is a run
of main-thread samples with gaps of at most 3ms; one over 16.7ms is a frame
the main thread could not commit at 60Hz. Accessibility servicing is the
driver's own cost (each step is an AX request answered on the main thread),
reported separately and excluded from the "app" line.
"""
import collections
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

OPS = {'toggle': 24, 'scroll': 400}
COMPONENTS = [
    ('layout (_layoutViewTree)', '_layoutViewTree'),
    ('CA commit', 'CA::Transaction::commit'),
    ('NSHostingView', 'NSHostingView'),
    ('ContentSurfaceHosting.update', 'ContentSurfaceHosting.update'),
    ('outline/table row views', re.compile(r'NSTableView.*(viewAtColumn|makeView|_addRowView|rowViewAtRow)|NSOutlineView.*(viewAtColumn|makeView)')),
    ('accessibility (driver)', re.compile(r'ccessibility')),
]


def main_samples(path):
    root = ET.parse(path).getroot()
    ids = {e.attrib['id']: e for e in root.iter() if 'id' in e.attrib}
    ref = lambda e: ids[e.attrib['ref']] if e is not None and 'ref' in e.attrib else e
    rows = []
    for row in root.iter('row'):
        thread = ref(row.find('thread'))
        if not (thread.get('fmt') or '').startswith('Main Thread'):
            continue
        t = int(ref(row.find('sample-time')).text) / 1e9
        bt = ref(row.find('tagged-backtrace'))
        frames = [ref(f).get('name', '?') for f in (bt.findall('frame') if bt is not None else [])]
        rows.append((t, frames))
    return sorted(rows)


def has(frames, pattern):
    if isinstance(pattern, str):
        return any(pattern in f for f in frames)
    return any(pattern.search(f) for f in frames)


def measure(path, scenario):
    rows = main_samples(path)
    if not rows:
        return None
    t0 = rows[0][0]
    window = [(t, f) for t, f in rows if t0 + 2.5 <= t < t0 + 19.5]
    ops = OPS[scenario]
    ax = [has(f, COMPONENTS[-1][1]) for _, f in window]
    m = collections.OrderedDict()
    m['main ms / op'] = len(window) / ops
    m['app ms / op (excl. AX)'] = (len(window) - sum(ax)) / ops
    for name, pattern in COMPONENTS:
        m['  ' + name] = sum(1 for _, f in window if has(f, pattern)) / ops
    stretches = []
    for t, _ in window:
        if not stretches or t - stretches[-1][1] > 0.003:
            stretches.append([t, t])
        else:
            stretches[-1][1] = t
    lengths = [(b - a) * 1000 + 1 for a, b in stretches]
    over = [x for x in lengths if x > 16.7]
    m['stretches > 16.7ms / op'] = len(over) / ops
    m['over-budget ms / op'] = sum(x - 16.7 for x in over) / ops
    m['longest stretch ms'] = max(lengths) if lengths else 0
    return m


def main():
    base, cand = sys.argv[1], sys.argv[2]
    default_out = os.path.join(os.environ.get('BENCH_DIR', os.path.expanduser('~/Library/Application Support/PhiSidebarBench')), 'out')
    out = sys.argv[3] if len(sys.argv) > 3 else default_out
    for scenario in ('toggle', 'scroll'):
        runs = {}
        for label in (base, cand):
            for path in sorted(glob.glob(os.path.join(out, f'{label}-{scenario}-*.xml'))):
                m = measure(path, scenario)
                if m:
                    runs[os.path.basename(path)[:-4]] = (label, m)
        if not runs:
            continue
        names = list(runs)
        keys = list(next(iter(runs.values()))[1])
        print(f'\n## {scenario}  (per op: {"toggle" if scenario == "toggle" else "scroll step"})')
        print(f"{'':32s}" + ''.join(f'{n.replace(scenario + "-", ""):>12s}' for n in names) + '      change')
        for k in keys:
            vals = {n: runs[n][1][k] for n in names}
            mean = lambda label: sum(v for n, v in vals.items() if runs[n][0] == label) / max(1, sum(1 for n in names if runs[n][0] == label))
            b, c = mean(base), mean(cand)
            change = f'{100 * (c - b) / b:+.0f}%' if b else ''
            print(f'{k:32s}' + ''.join(f'{vals[n]:12.2f}' for n in names) + f'   {change:>8s}')


if __name__ == '__main__':
    main()
