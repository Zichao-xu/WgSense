# 生成 WgSense 路由追踪地球底图数据（TraceGeo.bin）。来源均为 Natural Earth（公有领域）：
#   国家轮廓 earth-topojson 50m；省级边界 @motionscript/geography（NE 10m admin-1）；中文国名 i18n-iso-countries。
import json, sys, struct, os, math
et, mgdir, zh, out = sys.argv[1:5]

def unwrap(pts):
    # 源数据个别点是坏值（如 earth-topojson 里斐济跨 180° 的几段首点为 (9999, 4042)），先剔除超出经纬度范围的点
    pts = [(x, y) for x, y in pts if -180 <= x <= 180 and -90 <= y <= 90]
    if not pts: return []
    o = [pts[0]]
    for x, y in pts[1:]:
        px = o[-1][0]
        while x - px > 180: x -= 360
        while px - x > 180: x += 360
        o.append((x, y))
    return o

def dp(pts, tol):
    if len(pts) < 3: return pts
    keep = [False]*len(pts); keep[0] = keep[-1] = True
    stack = [(0, len(pts)-1)]
    while stack:
        a, b = stack.pop()
        ax, ay = pts[a]; bx, by = pts[b]
        dx, dy = bx-ax, by-ay; L = math.hypot(dx, dy)
        best, bi = -1, -1
        for i in range(a+1, b):
            px, py = pts[i]
            d = abs(dy*(px-ax) - dx*(py-ay)) / L if L > 0 else math.hypot(px-ax, py-ay)
            if d > best: best, bi = d, i
        if best > tol:
            keep[bi] = True; stack += [(a, bi), (bi, b)]
    return [p for p, k in zip(pts, keep) if k]

def ring_area(r):
    return 0.5*sum(x1*y2-x2*y1 for (x1,y1),(x2,y2) in zip(r, r[1:]+r[:1]))

def centroid(r):
    a = ring_area(r)
    if abs(a) < 1e-9: return r[0]
    cx = sum((x1+x2)*(x1*y2-x2*y1) for (x1,y1),(x2,y2) in zip(r, r[1:]+r[:1]))/(6*a)
    cy = sum((y1+y2)*(x1*y2-x2*y1) for (x1,y1),(x2,y2) in zip(r, r[1:]+r[:1]))/(6*a)
    return (cx, cy)

# ---- 国家（topojson）
topo = json.load(open(et))
sx, sy = topo['transform']['scale']; tx, ty = topo['transform']['translate']
arcs = []
for a in topo['arcs']:
    x = y = 0; p = []
    for dx, dy in a:
        x += dx; y += dy; p.append((x*sx+tx, y*sy+ty))
    arcs.append(p)
def topo_ring(idx):
    o = []
    for i in idx:
        p = arcs[i] if i >= 0 else arcs[~i][::-1]
        o.extend(p if not o else p[1:])
    return unwrap(o)
names = json.load(open(zh))['countries']
countries = []
for g in topo['objects']['countries']['geometries']:
    pr = g.get('properties') or {}
    code = pr.get('iso_a2') or ''
    if code in ('-99', '', None): code = (pr.get('postal') or 'ZZ')[:2]
    if pr.get('continent') == 'Antarctica': continue
    polys = g['arcs'] if g['type'] == 'MultiPolygon' else ([g['arcs']] if g['type'] == 'Polygon' else [])
    rings = [topo_ring(r) for p in polys for r in p]
    rings = [r for r in rings if len(r) >= 3]
    if not rings: continue
    big = max(rings, key=lambda r: abs(ring_area(r)))
    lx, ly = centroid(big)
    area = sum(abs(ring_area(r)) for r in rings)
    name = names.get(code) or pr.get('name') or code
    if isinstance(name, list): name = name[0]
    countries.append((code, name, lx, ly, area, rings))

# ---- 省级边界（每国一份 arcs，扁平 delta 编码）
# 省级边界只做这几个国家（MVP），逗号分隔，可用环境变量 PROVINCE_COUNTRIES 改
PROVINCE_COUNTRIES = set(os.environ.get('PROVINCE_COUNTRIES', 'CN,JP,US').split(','))
provinces = {}
for fn in sorted(os.listdir(mgdir)):
    if fn[:-5] not in PROVINCE_COUNTRIES: continue
    d = json.load(open(os.path.join(mgdir, fn)))
    sx2, sy2 = d['transform']['scale']; tx2, ty2 = d['transform']['translate']
    lines = []
    for a in d['arcs']:
        x = y = 0; p = []
        # 每点三个数：x, y, 简化权重（首点 x/y 为绝对值，其余为增量）
        for i in range(0, len(a)-2, 3):
            x += a[i]; y += a[i+1]; p.append((x*sx2+tx2, y*sy2+ty2))
        if len(p) >= 2: lines.append(unwrap(p))
    provinces[fn[:-5]] = lines

def pack_pts(pts):
    return struct.pack('<I', len(pts)) + b''.join(struct.pack('<ff', x, y) for x, y in pts)

COARSE, FINE, PROV = 0.12, 0.015, 0.02
blob = bytearray(b'WGTG') + struct.pack('<I', 1)
blob += struct.pack('<I', len(countries))
tot = {'coarse': 0, 'fine': 0, 'prov': 0}
for code, name, lx, ly, area, rings in countries:
    nb = name.encode('utf-8')
    blob += code.encode('ascii', 'replace')[:2].ljust(2, b'?') + struct.pack('<H', len(nb)) + nb + struct.pack('<fff', lx, ly, area)
    for lod, tol in (('coarse', COARSE), ('fine', FINE)):
        rs = [dp(r + [r[0]], tol)[:-1] for r in rings]
        rs = [r for r in rs if len(r) >= 3 and (lod == 'fine' or abs(ring_area(r)) > tol*tol*4)]
        blob += struct.pack('<I', len(rs))
        for r in rs: blob += pack_pts(r); tot[lod] += len(r)
blob += struct.pack('<I', len(provinces))
for code, lines in provinces.items():
    ls = [dp(l, PROV) for l in lines]
    ls = [l for l in ls if len(l) >= 2]
    blob += code.encode('ascii', 'replace')[:2].ljust(2, b'?') + struct.pack('<I', len(ls))
    for l in ls: blob += pack_pts(l); tot['prov'] += len(l)
open(out, 'wb').write(blob)
print('countries', len(countries), 'points', tot, 'bytes', len(blob), file=sys.stderr)
print([c[:2] for c in countries if c[0] in ('CN','US','JP','RU','FR','NO')], file=sys.stderr)
