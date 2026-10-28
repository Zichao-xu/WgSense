#!/usr/bin/env python3
"""间距/字号/圆角档位检查与迁移。
  tokens.py <WgSense 源码目录> --check   发现可归档却写死的数字就失败（CI 用，防止回潮）
  tokens.py <WgSense 源码目录>           把写死的数字换成 WgSpace/WgType/WgRadius 档位
  tokens.py <WgSense 源码目录> --dry     只统计不改文件
映射表即「哪些数归哪一档」；超出表的值（大版面尺寸、负数、0/1 发丝线）视为有意保留。"""
import re, sys, pathlib, collections

SPACE = {2: 'hair', 3: 'xs', 4: 'xs', 5: 'xs', 6: 's', 7: 's', 8: 's', 9: 's',
         10: 'm', 11: 'm', 12: 'm', 13: 'm', 14: 'l', 15: 'l', 16: 'l',
         18: 'xl', 19: 'xl', 20: 'xl', 22: 'xxl', 24: 'xxl', 26: 'xxl',
         28: 'xxxl', 30: 'xxxl', 32: 'xxxl', 34: 'xxxl', 36: 'xxxl'}
TYPE = {7: 'micro', 8: 'micro', 8.5: 'micro', 9: 'micro', 10: 'caption', 10.5: 'caption', 11: 'caption',
        11.5: 'footnote', 12: 'footnote', 12.5: 'body', 13: 'body', 13.5: 'body',
        14: 'sub', 15: 'sub', 16: 'sub', 17: 'title', 18: 'title', 20: 'section', 21: 'section', 22: 'section',
        24: 'large', 26: 'large', 30: 'readout', 36: 'page', 40: 'page', 44: 'display', 48: 'display'}
RADIUS = {2: 's', 3: 's', 4: 'm', 5: 'm'}
KINDS = {'space': ('WgSpace', SPACE), 'type': ('WgType', TYPE), 'radius': ('WgRadius', RADIUS)}
SKIP = {'WgTokens.swift', 'WgTunePanel.swift'}

NUM = re.compile(r'(?<![\w.])\d+(?:\.\d+)?(?![\w.])')

def region_end(s, i):
    """从 i 起到同层的 ',' 或 ')' 为止。"""
    depth = 0
    while i < len(s):
        c = s[i]
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0: return i
            depth -= 1
        elif c == ',' and depth == 0: return i
        elif c == '\n' and depth == 0: return i
        i += 1
    return i

def paren_end(s, i):
    """s[i-1]=='(' 时返回匹配 ')' 的下标。"""
    depth = 0
    while i < len(s):
        c = s[i]
        if c in '([{': depth += 1
        elif c in ')]}':
            if depth == 0: return i
            depth -= 1
        i += 1
    return i

def standalone(seg, m):
    before = seg[:m.start()].rstrip()
    after = seg[m.end():].lstrip()
    ok_before = before == '' or before[-1] in '(,?:'
    ok_after = after == '' or after[0] in '),:'
    return ok_before and ok_after

def sub_region(seg, kind, stats, misses, where):
    enum, table = KINDS[kind]
    def rep(m):
        if not standalone(seg, m):
            return m.group(0)
        v = float(m.group(0)); v = int(v) if v == int(v) else v
        if kind == 'space' and v in (0, 1):
            return m.group(0)
        name = table.get(v)
        if not name:
            misses[kind].append(f'{where}: {m.group(0)}')
            return m.group(0)
        stats[kind][f'{v}→{name}'] += 1
        return f'{enum}.{name}'
    return NUM.sub(rep, seg)

def top_args(seg):
    args, depth, cur = [], 0, ''
    for c in seg:
        if c in '([{': depth += 1
        elif c in ')]}': depth -= 1
        if c == ',' and depth == 0: args.append(cur); cur = ''
        else: cur += c
    args.append(cur)
    return [a.strip() for a in args]

def process(text, fname, stats, misses):
    out, i = [], 0
    pat = re.compile(r'\.padding\(|\bspacing:|\bcornerRadius:|\.system\(size:|ofSize:')
    while True:
        m = pat.search(text, i)
        if not m:
            out.append(text[i:]); break
        line_start = text.rfind('\n', 0, m.start()) + 1
        if '//' in text[line_start:m.start()]:
            out.append(text[i:m.end()]); i = m.end(); continue
        out.append(text[i:m.start()])
        tok = m.group(0)
        lineno = text.count('\n', 0, m.start()) + 1
        where = f'{fname}:{lineno}'
        if tok == '.padding(':
            end = paren_end(text, m.end())
            seg = text[m.end():end]
            args = top_args(seg)
            new = seg
            if seg.strip():
                new = sub_region(seg, 'space', stats, misses, where)
            rename = seg.strip() != '' and 'EdgeInsets' not in seg and (
                len(args) == 1 or (len(args) == 2 and args[0][:1] in '.['))
            out.append(('.wgPadding(' if rename else '.padding(') + new + ')')
            if rename: stats['rename']['.padding→.wgPadding'] += 1
            i = end + 1
        else:
            kind = {'spacing:': 'space', 'cornerRadius:': 'radius'}.get(tok, 'type')
            end = region_end(text, m.end())
            out.append(tok + sub_region(text[m.end():end], kind, stats, misses, where))
            i = end
    return ''.join(out)

def main():
    root = pathlib.Path(sys.argv[1]); check = '--check' in sys.argv; dry = '--dry' in sys.argv or check
    stats = collections.defaultdict(collections.Counter); misses = collections.defaultdict(list)
    changed = 0
    for p in sorted(root.rglob('*.swift')):
        if p.name in SKIP: continue
        old = p.read_text()
        new = process(old, str(p.relative_to(root)), stats, misses)
        if new != old:
            changed += 1
            if not dry: p.write_text(new)
    if check:
        found = sum(sum(c.values()) for k, c in stats.items() if k != 'rename')
        if found:
            print(f'发现 {found} 处写死的间距/字号/圆角，请改用 WgSpace / WgType / WgRadius（或运行 tokens.py 自动迁移）：')
            for p in sorted(root.rglob('*.swift')):
                if p.name in SKIP: continue
                s2 = collections.defaultdict(collections.Counter)
                process(p.read_text(), str(p.relative_to(root)), s2, collections.defaultdict(list))
                n = sum(sum(c.values()) for k, c in s2.items() if k != 'rename')
                if n: print(f'  {p.relative_to(root)}: {n}')
            sys.exit(1)
        print('tokens: OK')
        return
    print(f'files changed: {changed}')
    for k, c in stats.items():
        print(f'[{k}] total {sum(c.values())}:', ', '.join(f'{a}×{n}' for a, n in sorted(c.items(), key=lambda x: -x[1])))
    for k, l in misses.items():
        print(f'[{k} 未映射] {len(l)}:', '; '.join(l[:30]))

main()
