#!/usr/bin/env python3
"""unit-graph.py --- the systemd dependency graph of the units a window touches (tool/unit-model.txt).

The window script stops and starts a few units on the target; what else goes down or comes up with them is decided by
their dependencies. tool/test-window.sh simulates exactly the graph in the model, and night.sh compares the target's
graph with it before anything stops, so a changed graph (firmware / Protect update) cannot silently invalidate the
sandbox tests.

  unit-graph.py check <model> <file|->       compare `systemctl show` output (arguments: see query) with the model.
                                             exit 0 = same; 1 = different (each difference printed); 2 = unusable
  unit-graph.py query <model>                the `systemctl show` arguments check expects (units + -p list)
  unit-graph.py closure <model> stop|start|restart|conflicts <unit>
                                             the other model units the operation reaches, one per line
  unit-graph.py tables <model> <dir>         per-unit closure tables for test-window.sh's fake systemctl
  unit-graph.py lint <model>                 parse only (exit 0 = valid)

Model format: the header of tool/unit-model.txt.
"""
import os
import re
import sys

# compared with the target (complete lists, every unit type)
# ConflictedBy: the units whose start stops this one (systemd's reverse of their Conflicts=)
PROPS = ('Requires', 'Requisite', 'BindsTo', 'PartOf', 'Wants', 'Conflicts', 'OnFailure', 'ConflictedBy')   # always reported
OPTIONAL = ('Upholds', 'UpheldBy', 'PropagatesStopTo', 'StopPropagatedFrom', 'OnSuccess')   # newer systemd: compared when reported
# what test-window.sh's fake simulates; every other property must be empty in the model (lint refuses otherwise), so a
# target that has such an edge always fails the comparison until the fake learns it. ConflictedBy is simulated as the
# reverse of the window units' Conflicts (lint: exactly that set), so a unit outside the model that conflicts with a
# window unit still fails the comparison
MODELED = ('Requires', 'Requisite', 'BindsTo', 'PartOf', 'Wants', 'Conflicts', 'ConflictedBy')
STOP_EDGES = ('Requires', 'Requisite', 'BindsTo', 'PartOf')      # X lists Y here: stop / restart of Y reaches X
PULL_EDGES = ('Requires', 'BindsTo', 'Wants')                    # start of X pulls these in
UNIT_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9:_.@\\-]*\.(service|socket|target|slice|mount|automount|swap|path|timer|'
                     r'device|scope)')
WINDOW_UNIT_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9:_.@-]*\.service')


class GraphError(Exception):
    pass


class Model:
    def __init__(self):
        self.units = []                  # window set, file order
        self.deps = {}                   # unit -> {prop: set(units)}
        self.observed_stop = {}          # unit -> [units], simulated only

    def edges(self, unit, prop):
        return self.deps[unit].get(prop, set())


def _unit(name, where):
    if not UNIT_RE.fullmatch(name):
        raise GraphError(f'{where}: not a unit name: {name!r}')
    return name


def load_model(path):
    m = Model()
    seen_props = set()
    pending = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            s = line.split('#', 1)[0].split()
            if not s:
                continue
            where = f'{path}:{n}'
            if s[0] == 'unit':
                if len(s) != 2:
                    raise GraphError(f'{where}: expected "unit <name>"')
                u = _unit(s[1], where)
                if not WINDOW_UNIT_RE.fullmatch(u):      # window units end up on a remote command line (query)
                    raise GraphError(f'{where}: window unit names are limited to [A-Za-z0-9:_.@-]: {u!r}')
                if u in m.deps:
                    raise GraphError(f'{where}: unit {u} declared twice')
                m.units.append(u)
                m.deps[u] = {}
            elif s[0] == 'observed-stop':
                if len(s) < 3:
                    raise GraphError(f'{where}: expected "observed-stop <unit> <unit>..."')
                pending.append((where, 'observed-stop', [_unit(x, where) for x in s[1:]]))
            elif len(s) >= 2 and s[1] in PROPS + OPTIONAL:
                pending.append((where, s[1], [_unit(x, where) for x in [s[0]] + s[2:]]))
            else:
                raise GraphError(f'{where}: cannot parse: {line.strip()!r}')
    if not m.units:
        raise GraphError(f'{path}: no "unit" lines')
    for where, kind, us in pending:          # units may be declared after their lines are read: resolve at the end
        head, rest = us[0], us[1:]
        if head not in m.deps:
            raise GraphError(f'{where}: {head} is not declared with a "unit" line')
        if kind == 'observed-stop':
            lst = m.observed_stop.setdefault(head, [])
            for x in rest:
                if x not in m.deps:
                    raise GraphError(f'{where}: observed-stop target {x} is not a window unit')
                if x != head and x not in lst:
                    lst.append(x)
            continue
        if (head, kind) in seen_props:
            raise GraphError(f'{where}: {head} {kind} listed twice')
        seen_props.add((head, kind))
        if len(set(rest)) != len(rest):
            raise GraphError(f'{where}: duplicate entries in {head} {kind}')
        m.deps[head][kind] = set(rest)
    for u in m.units:
        missing = [p for p in PROPS if (u, p) not in seen_props]
        if missing:
            raise GraphError(f'{path}: {u} has no line for {", ".join(missing)} (write the property with an empty '
                             f'list if it has none)')
        unmodeled = [p for p in PROPS + OPTIONAL if p not in MODELED and m.deps[u].get(p)]
        if unmodeled:
            raise GraphError(f'{path}: {u} {", ".join(unmodeled)}: not simulated by tool/test-window.sh --- teach the '
                             f'fake systemctl that dependency before modelling it')
    for u in m.units:            # systemd reports ConflictedBy as the reverse of Conflicts: the model must say the same
        want = {x for x in m.units if u in m.edges(x, 'Conflicts')}
        have = m.edges(u, 'ConflictedBy')
        if have != want:
            raise GraphError(f'{path}: {u} ConflictedBy must list exactly the window units that list it under Conflicts'
                             f' ({" ".join(sorted(want)) or "none"}); has {" ".join(sorted(have)) or "none"} (a unit '
                             f'outside the model that conflicts with a window unit is not simulated)')
    return m


def parse_show(text):
    """`systemctl show <u>... -p ...` output -> {Id: {prop: value-string}}; blocks are separated by empty lines."""
    blocks, cur = [], {}
    for line in text.splitlines():
        if not line.strip():
            if cur:
                blocks.append(cur)
                cur = {}
            continue
        k, sep, v = line.partition('=')
        if not sep or not re.fullmatch(r'[A-Za-z]+', k):
            raise GraphError(f'not systemctl show output: {line[:80]!r}')
        if k in cur:
            raise GraphError(f'property {k} twice in one block (missing empty line between units?)')
        cur[k] = v.strip()
    if cur:
        blocks.append(cur)
    out = {}
    for b in blocks:
        if 'Id' not in b:
            raise GraphError('a block without Id= (query must include -p Id)')
        if b['Id'] in out:
            raise GraphError(f'unit {b["Id"]} reported twice')
        out[b['Id']] = b
    return out


def check(model, text):
    """-> list of differences (empty = same). Raises GraphError when the input cannot be judged at all."""
    got = parse_show(text)
    if not got:
        raise GraphError('empty systemctl show output')
    diffs = []
    for u in model.units:
        b = got.get(u)
        if b is None:
            diffs.append(f'{u}: not reported (an alias, or the query did not include it)')
            continue
        ls = b.get('LoadState')
        if ls != 'loaded':
            diffs.append(f'{u}: LoadState={ls if ls is not None else "(not reported)"}, expected loaded')
            continue
        for p in PROPS + OPTIONAL:
            want = model.edges(u, p)
            if p not in b:
                if p in OPTIONAL and not want:
                    continue                     # systemd too old to know the property: no such edges possible
                diffs.append(f'{u} {p}: not reported')
                continue
            have = set(b[p].split())
            if have != want:
                add, rem = sorted(have - want), sorted(want - have)
                diffs.append(f'{u} {p}: target' + (f' adds {" ".join(add)}' if add else '')
                             + (';' if add and rem else '') + (f' lacks {" ".join(rem)}' if rem else ''))
    extra = sorted(set(got) - set(model.units))
    if extra:
        diffs.append(f'reported but not in the model: {" ".join(extra)}')
    return diffs


def query(model):
    return model.units + [a for p in ('Id', 'LoadState') + PROPS + OPTIONAL for a in ('-p', p)]


def stop_reach(model, unit):
    """units a stop (or restart) of `unit` propagates to, transitively, excluding `unit`."""
    out, todo = [], [unit]
    while todo:
        y = todo.pop(0)
        for x in model.units:
            if x != unit and x not in out and any(y in model.edges(x, p) for p in STOP_EDGES):
                out.append(x)
                todo.append(x)
    return out


def pull_reach(model, unit):
    """window units a start of `unit` pulls in, transitively, excluding `unit` (edges to other units are not followed:
    their dependencies are not part of the model)."""
    out, todo = [], [unit]
    while todo:
        y = todo.pop(0)
        for p in PULL_EDGES:
            for x in sorted(model.edges(y, p)):
                if x in model.deps and x != unit and x not in out:
                    out.append(x)
                    todo.append(x)
    return out


def conflicts(model, unit):
    """window units a start of `unit` stops: Conflicts= in either direction."""
    return [x for x in model.units if x != unit
            and (x in model.edges(unit, 'Conflicts') or unit in model.edges(x, 'Conflicts'))]


def closure(model, op, unit):
    if unit not in model.deps:
        raise GraphError(f'{unit} is not a window unit of the model')
    if op == 'stop':
        return stop_reach(model, unit)
    if op == 'start':
        return pull_reach(model, unit)
    if op == 'conflicts':
        return conflicts(model, unit)
    if op == 'restart':              # restarted along: the stop reach; pulled in: the deps of everything restarted
        again = stop_reach(model, unit)
        pulled = []
        for x in [unit] + again:
            pulled += [y for y in pull_reach(model, x) if y != unit and y not in again and y not in pulled]
        return again + pulled
    raise GraphError(f'unknown operation {op!r} (stop|start|restart|conflicts)')


def tables(model, d):
    """files for the fake systemctl: units, and per unit stop.<u> / pull.<u> / restart.<u> / requisite.<u> /
    conflicts.<u> / observed-stop.<u> (one unit per line; requisite lists every Requisite entry, window unit or not)."""
    os.makedirs(d, exist_ok=True)

    def put(name, lines):
        with open(os.path.join(d, name), 'w') as f:
            f.write(''.join(x + '\n' for x in lines))
    put('units', model.units)
    for u in model.units:
        put(f'stop.{u}', stop_reach(model, u))
        put(f'pull.{u}', pull_reach(model, u))
        put(f'restart.{u}', stop_reach(model, u))
        put(f'requisite.{u}', sorted(model.edges(u, 'Requisite')))
        put(f'conflicts.{u}', conflicts(model, u))
        put(f'observed-stop.{u}', model.observed_stop.get(u, []))


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd, path = argv[0], argv[1]
    try:
        model = load_model(path)
        if cmd == 'lint' and len(argv) == 2:
            print(f'{path}: {len(model.units)} units, ok')
            return 0
        if cmd == 'query' and len(argv) == 2:
            print(' '.join(query(model)))
            return 0
        if cmd == 'check' and len(argv) == 3:
            if argv[2] == '-':
                text = sys.stdin.read()
            else:
                with open(argv[2]) as f:
                    text = f.read()
            diffs = check(model, text)
            if diffs:
                for x in diffs:
                    print(f'DIFFERS {x}')
                print(f'unit graph: {len(diffs)} difference(s) from {os.path.basename(path)} --- the sandbox tests do '
                      f'not model this target')
                return 1
            print(f'unit graph: matches {os.path.basename(path)} ({len(model.units)} units)')
            return 0
        if cmd == 'closure' and len(argv) == 4:
            for x in closure(model, argv[2], argv[3]):
                print(x)
            return 0
        if cmd == 'tables' and len(argv) == 3:
            tables(model, argv[2])
            return 0
    except (GraphError, OSError, UnicodeDecodeError) as e:
        print(f'unit graph: cannot check: {e}', file=sys.stderr)
        return 2
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
