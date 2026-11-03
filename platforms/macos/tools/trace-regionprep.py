# 生成 WgSense 路由追踪重点地区的市 / 区数据（TraceRegions.bin），与世界底图 TraceGeo.bin（trace-geoprep.py）分开。
#   用法：python3 trace-regionprep.py <下载目录> <输出 TraceRegions.bin>，下载目录里放：
#     广东地级市与珠三角区县  阿里云 DataV  https://geo.datav.aliyun.com/areas_v3/bound/{440000,440100,440300,440400,440600,440700,441200,441300}_full.json
#                            存成 gd.json（440000）与 <行政区划代码>.json（东莞、中山不设区，没有下一级）
#     东京都区市町村          国土数値情報 N03（smartnews-smri/japan-topography 简化版）
#                            https://raw.githubusercontent.com/smartnews-smri/japan-topography/main/data/municipality/geojson/s0010/N03-21_13_210101.json → tokyo.json
#     加州、纽约州的县        美国人口普查局 1:50 万县界（公有领域）
#                            https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_county_500k.zip → 解压到 c500/
#   精细陆地块（land/ 子目录）：世界底图的陆地是 Natural Earth 1:5000 万，放大到区县级时河口、海湾都成了大三角；
#   这几块矩形里改用精细陆地（底图的粗陆地、国界、省界在块内不画），块内所有陆地都要有数据：
#     广东块  DataV 省界 {440000,450000,430000,360000,350000,460000,810000,820000}.json → land/cn_<代码>.json
#             （珠三角七市用区县、其余广东地级市用上面的 gd.json，更细）
#     东京块  国土数値情報 N03 简化版 {08,10,11,12,13,14,19,22} → land/jp_<代码>.json（同上 s0010 目录）
#     纽约块、湾区块、洛杉矶块  上面的人口普查局县界（新泽西 34、纽约 36、康涅狄格 09、加州 06）
#     纽约块的河道            县界没扣内河（哈德逊河、东河），另取人口普查局 TIGER 水面：
#                            https://www2.census.gov/geo/tiger/TIGER2023/AREAWATER/tl_2023_<州县代码>_areawater.zip → 解压到 land/water/
#                            （纽约 36005 36047 36061 36081 36085 36119 36059 36087，新泽西 34003 34013 34017 34039 34023 34025 34031，康涅狄格 09190）
import json, sys, struct, os, math
regdir, out = sys.argv[1:3]

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

# ---- 重点地区的市 / 区：level 1 = 地级市、美国县；level 2 = 珠三角区县、东京区市町村
def shp_polygons(base):
    """读 ESRI shapefile（只认多边形）与 dbf 属性，不依赖第三方库。返回 [(属性 dict, [环...])]。"""
    shp = open(base + '.shp', 'rb').read(); dbf = open(base + '.dbf', 'rb').read()
    n, hlen, rlen = struct.unpack('<IHH', dbf[4:12])
    fields = []; o = 32
    while dbf[o] != 0x0D:
        fields.append((dbf[o:o+11].split(b'\0')[0].decode(), dbf[o+16])); o += 32
    recs = []
    for i in range(n):
        r = dbf[hlen + i*rlen + 1: hlen + (i+1)*rlen]; d = {}; p = 0
        for name, ln in fields: d[name] = r[p:p+ln].decode('utf-8', 'replace').strip(); p += ln
        recs.append(d)
    out = []; o = 100
    while o < len(shp):
        _, ln = struct.unpack('>II', shp[o:o+8]); c = shp[o+8:o+8+ln*2]; o += 8 + ln*2
        if struct.unpack('<i', c[:4])[0] != 5: out.append([]); continue
        nparts, npts = struct.unpack('<ii', c[36:44])
        parts = list(struct.unpack('<%di' % nparts, c[44:44+4*nparts])) + [npts]
        xy = struct.unpack('<%dd' % (2*npts), c[44+4*nparts:44+4*nparts+16*npts])
        out.append([[(xy[2*k], xy[2*k+1]) for k in range(parts[j], parts[j+1])] for j in range(nparts)])
    return list(zip(recs, out))

def geojson_polys(geom):
    """GeoJSON 几何 → [多边形[环...]]（每个多边形首环是外环，其余是洞）。"""
    if geom['type'] == 'Polygon': return [geom['coordinates']]
    if geom['type'] == 'MultiPolygon': return geom['coordinates']
    return []

def region(level, name, polys, label=None, code='CN'):
    """polys：[[外环, 洞...], ...]。面积 = 外环减洞（平方度），标注点默认取最大外环的形心。"""
    rings, area, big = [], 0.0, None
    for poly in polys:
        for k, r in enumerate(poly):
            r = unwrap([(float(x), float(y)) for x, y, *_ in r])
            if len(r) < 3: continue
            rings.append(r)
            a = abs(ring_area(r)); area += -a if k > 0 else a
            if k == 0 and (big is None or a > abs(ring_area(big))): big = r
    if not rings: return None
    lx, ly = label if label else centroid(big)
    return (level, name, lx, ly, max(area, 0.0), rings, code)

regions = []
gd = json.load(open(os.path.join(regdir, 'gd.json')))
for f in gd['features']:
    pr = f['properties']
    regions.append(region(1, pr['name'].removesuffix('市'), geojson_polys(f['geometry']), pr.get('centroid') or pr.get('center')))
for fn in sorted(os.listdir(regdir)):
    if not (fn[:6].isdigit() and fn.endswith('.json')): continue
    for f in json.load(open(os.path.join(regdir, fn)))['features']:
        pr = f['properties']
        regions.append(region(2, pr['name'], geojson_polys(f['geometry']), pr.get('centroid') or pr.get('center')))
# 东京：同一区市町村可能拆成多条（离岛），按代码合并；「所属未定地」不是行政区，跳过
tk = {}
for f in json.load(open(os.path.join(regdir, 'tokyo.json')))['features']:
    pr = f['properties']; nm = pr.get('N03_004') or ''
    if not nm or nm == '所属未定地': continue
    tk.setdefault((pr.get('N03_007'), nm), []).extend(geojson_polys(f['geometry']))
for (_, nm), polys in sorted(tk.items()): regions.append(region(2, nm, polys, code='JP'))
# 加州（06）、纽约州（36）的县；纽约市五个区本身就是五个县，标注用区名
boroughs = {'New York': 'Manhattan', 'Kings': 'Brooklyn', 'Bronx': 'The Bronx', 'Richmond': 'Staten Island', 'Queens': 'Queens'}
for rec, rings in shp_polygons(os.path.join(regdir, 'c500', 'cb_2023_us_county_500k')):
    if rec.get('STATEFP') not in ('06', '36') or not rings: continue
    # shapefile 外环顺时针、洞逆时针：按方向分组
    polys = []
    for r in rings:
        if ring_area(r) <= 0 or not polys: polys.append([r])
        else: polys[-1].append(r)
    nm = rec['NAME']
    if rec['STATEFP'] == '36': nm = boroughs.get(nm, nm)
    regions.append(region(1, nm, polys, code='US'))
regions = [r for r in regions if r]

# ---- 精细陆地块：(名称, (西, 南, 东, 北), [外环...])
def outer_rings(polys):
    return [unwrap([(float(x), float(y)) for x, y, *_ in poly[0]]) for poly in polys if poly and len(poly[0]) >= 4]

def in_box(r, box):
    xs = [x for x, _ in r]; ys = [y for _, y in r]
    return max(xs) >= box[0] and min(xs) <= box[2] and max(ys) >= box[1] and min(ys) <= box[3]

def outline(rings):
    """一组相邻多边形的外轮廓：两块共用的边各出现两次、相互抵消，只剩只出现一次的边（海岸与组外边界），再连成折线。"""
    key = lambda p: (round(p[0], 6), round(p[1], 6))
    cnt, pt = {}, {}
    for r in rings:
        for a, b in zip(r, r[1:] + r[:1]):
            ka, kb = key(a), key(b)
            if ka == kb: continue
            e = (ka, kb) if ka < kb else (kb, ka)
            cnt[e] = cnt.get(e, 0) + 1; pt[ka] = a; pt[kb] = b
    adj = {}
    for (ka, kb), c in cnt.items():
        if c == 1: adj.setdefault(ka, []).append(kb); adj.setdefault(kb, []).append(ka)
    lines, used = [], set()
    for start in list(adj):
        for nxt in adj[start]:
            e = (start, nxt) if start < nxt else (nxt, start)
            if e in used: continue
            line = [start]; cur, prev = nxt, start; used.add(e)
            while True:
                line.append(cur)
                cand = [n for n in adj.get(cur, []) if ((cur, n) if cur < n else (n, cur)) not in used]
                if not cand: break
                n = cand[0]; used.add((cur, n) if cur < n else (n, cur)); prev, cur = cur, n
            lines.append([pt[k] for k in line])
    return lines

def closed(r):
    return r + [r[0]] if r and r[0] != r[-1] else r

def shp_outer(rings):
    # shapefile 外环顺时针（有符号面积为负）
    return [unwrap(r) for r in rings if ring_area(r) < 0 and len(r) >= 4]

landdir = os.path.join(regdir, 'land')
county = {}
county_all = {}
for rec, rings in shp_polygons(os.path.join(regdir, 'c500', 'cb_2023_us_county_500k')):
    county.setdefault(rec.get('STATEFP'), []).extend(shp_outer(rings))
    county_all.setdefault(rec.get('STATEFP'), []).extend(unwrap(r) for r in rings)

gd_land = []
prd = {fn[:6] for fn in os.listdir(regdir) if fn[:6].isdigit() and fn.endswith('.json')}
for f in gd['features']:
    if str(f['properties'].get('adcode')) not in prd: gd_land += outer_rings(geojson_polys(f['geometry']))
for fn in sorted(prd):
    for f in json.load(open(os.path.join(regdir, fn + '.json')))['features']: gd_land += outer_rings(geojson_polys(f['geometry']))
gd_lines = []
for c in ('440000', '450000', '430000', '360000', '350000', '460000', '810000', '820000'):
    for f in json.load(open(os.path.join(landdir, 'cn_%s.json' % c)))['features']:
        rs = outer_rings(geojson_polys(f['geometry']))
        if c != '440000': gd_land += rs
        gd_lines += [closed(r) for r in rs]     # 省界（含海岸）
jp_land, jp_lines = [], []
for c in ('08', '10', '11', '12', '13', '14', '19', '22'):
    rs = []
    for f in json.load(open(os.path.join(landdir, 'jp_%s.json' % c)))['features']: rs += outer_rings(geojson_polys(f['geometry']))
    jp_land += rs; jp_lines += outline(rs)      # 都县界（含海岸）：区市町村共用边抵消
us_lines = {st: outline(county_all[st]) for st in ('34', '36', '09', '06')}   # 州界（含海岸）

PATCH_TOL = 0.0002   # 约 20 米

# 纽约块的内河水面（外环）与水中的岛（水面的洞）：岛按陆地再叠一层
ny_water, ny_islands = [], []
wdir = os.path.join(landdir, 'water')
for fn in sorted(os.listdir(wdir)):
    if not fn.endswith('.shp'): continue
    for _, rings in shp_polygons(os.path.join(wdir, fn[:-4])):
        for r in rings:
            a = ring_area(r)
            if a < -2e-6: ny_water.append(unwrap(r))       # 外环（顺时针），约 0.02 平方公里以上
            elif a > 1e-6: ny_islands.append(unwrap(r))    # 洞（逆时针）= 岛

PATCHES = [
    ('广东', (109.5, 20.1, 117.4, 25.6), gd_land, gd_lines, [], []),
    ('东京', (138.95, 35.1, 140.35, 36.05), jp_land, jp_lines, [], []),
    ('纽约', (-74.5, 40.4, -73.4, 41.2), county['34'] + county['36'] + county['09'], us_lines['34'] + us_lines['36'] + us_lines['09'], ny_water, ny_islands),
    ('湾区', (-123.1, 37.1, -121.5, 38.4), county['06'], us_lines['06'], [], []),
    ('洛杉矶', (-119.0, 33.5, -117.4, 34.5), county['06'], us_lines['06'], [], []),
]
def pack_pts(pts):
    return struct.pack('<I', len(pts)) + b''.join(struct.pack('<ff', x, y) for x, y in pts)

blob = bytearray(b'WGTR') + struct.pack('<I', 4)
tot = {}
# 格式：WGTR、版本 4、个数；每个市 / 区：级别、所属国家（两位代码）、名称、标注点、面积、边界环（简化容差约 50 米，与精细陆地的海岸对得上）；
#       然后是精细陆地块：个数；每块：名称、矩形（西南东北）、外环（填色）、折线（海岸与省 / 都县 / 州界）、内河水面外环、水中岛外环
REGION_TOL = {1: 0.0005, 2: 0.0005}
blob += struct.pack('<I', len(regions))
tot['region'] = 0
for level, name, lx, ly, area, rings, code in regions:
    nb = name.encode('utf-8')
    rs = [dp(r + [r[0]], REGION_TOL[level])[:-1] for r in rings]
    rs = [r for r in rs if len(r) >= 3]
    blob += struct.pack('<B', level) + code.encode('ascii') + struct.pack('<H', len(nb)) + nb + struct.pack('<fff', lx, ly, area) + struct.pack('<I', len(rs))
    for r in rs: blob += pack_pts(r); tot['region'] += len(r)
blob += struct.pack('<I', len(PATCHES))
tot['land'] = 0
def pack_rings(rings, box):
    rs = [dp(r, PATCH_TOL) for r in rings if in_box(r, box)]
    rs = [r[:-1] if r[0] == r[-1] else r for r in rs]
    rs = [r for r in rs if len(r) >= 3]
    tot['land'] += sum(len(r) for r in rs)
    return struct.pack('<I', len(rs)) + b''.join(pack_pts(r) for r in rs), rs

for name, box, rings, lines, water, islands in PATCHES:
    nb = name.encode('utf-8')
    rs = [dp(r, PATCH_TOL) for r in rings if in_box(r, box)]
    rs = [r[:-1] if r[0] == r[-1] else r for r in rs]
    rs = [r for r in rs if len(r) >= 3]
    blob += struct.pack('<H', len(nb)) + nb + struct.pack('<ffff', *box) + struct.pack('<I', len(rs))
    for r in rs: blob += pack_pts(r); tot['land'] += len(r)
    ls = [dp(l, PATCH_TOL) for l in lines if len(l) >= 2 and in_box(l, box)]
    blob += struct.pack('<I', len(ls))
    for l in ls: blob += pack_pts(l); tot['land'] += len(l)
    wb, ws = pack_rings(water, box); ib, iss = pack_rings(islands, box)
    blob += wb + ib
    print('patch', name, len(rs), sum(len(r) for r in rs), 'lines', len(ls), sum(len(l) for l in ls), 'water', len(ws), 'islands', len(iss), file=sys.stderr)
open(out, 'wb').write(blob)
print('regions', len(regions), {l: sum(1 for r in regions if r[0] == l) for l in (1, 2)}, file=sys.stderr)
print('points', tot, 'bytes', len(blob), file=sys.stderr)
