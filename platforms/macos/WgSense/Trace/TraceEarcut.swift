import Foundation

// 多边形三角剖分：mapbox/earcut 的耳切算法（ISC 许可）移植，只用到不带洞的单环部分。
// 地图上陆地的每个环单独剖分；环在源数据里可能有自交（简化后），earcut 的三道兜底（滤点 → 修局部自交 → 对角线切分）照搬，
// 保证尽量不漏面。顶点多的环用 z 序曲线加速找耳朵。节点用数组下标串链表，不建对象。

enum TraceEarcut {
    /// 输入一个环（x, y），返回三角形的顶点下标（每 3 个一组）。
    static func triangulate(_ pts: [SIMD2<Double>]) -> [Int] {
        var e = Engine(pts)
        return e.run()
    }

    private struct Engine {
        var x: [Double] = [], y: [Double] = [], idx: [Int] = []
        var prev: [Int] = [], next: [Int] = [], z: [Int] = [], prevZ: [Int] = [], nextZ: [Int] = []
        var minX = 0.0, minY = 0.0, invSize = 0.0
        var tris: [Int] = []
        let src: [SIMD2<Double>]

        init(_ p: [SIMD2<Double>]) { src = p }

        mutating func run() -> [Int] {
            let n = src.count
            guard n >= 3 else { return [] }
            var outer = linkedList(clockwise: true)
            guard outer >= 0, next[outer] != prev[outer] else { return [] }
            if n > 80 {
                var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
                for p in src { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) }
                minX = x0; minY = y0
                let s = max(x1 - x0, y1 - y0)
                invSize = s != 0 ? 32767 / s : 0
            }
            outer = filterPoints(outer, -1)
            earcutLinked(outer, pass: 0)
            return tris
        }

        // MARK: 链表

        mutating func create(_ i: Int, _ px: Double, _ py: Double) -> Int {
            x.append(px); y.append(py); idx.append(i)
            prev.append(-1); next.append(-1); z.append(0); prevZ.append(-1); nextZ.append(-1)
            return x.count - 1
        }

        mutating func insert(_ i: Int, _ last: Int) -> Int {
            let p = create(i, src[i].x, src[i].y)
            if last < 0 { prev[p] = p; next[p] = p } else {
                next[p] = next[last]; prev[p] = last
                prev[next[last]] = p; next[last] = p
            }
            return p
        }

        mutating func remove(_ p: Int) {
            prev[next[p]] = prev[p]; next[prev[p]] = next[p]
            if prevZ[p] >= 0 { nextZ[prevZ[p]] = nextZ[p] }
            if nextZ[p] >= 0 { prevZ[nextZ[p]] = prevZ[p] }
        }

        mutating func linkedList(clockwise: Bool) -> Int {
            var sum = 0.0
            var j = src.count - 1
            for i in 0..<src.count { sum += (src[j].x - src[i].x) * (src[i].y + src[j].y); j = i }
            var last = -1
            if clockwise == (sum > 0) { for i in 0..<src.count { last = insert(i, last) } }
            else { for i in stride(from: src.count - 1, through: 0, by: -1) { last = insert(i, last) } }
            if last >= 0, equals(last, next[last]) { let n = next[last]; remove(last); last = n }
            return last
        }

        // MARK: 几何

        func area(_ p: Int, _ q: Int, _ r: Int) -> Double { (y[q] - y[p]) * (x[r] - x[q]) - (x[q] - x[p]) * (y[r] - y[q]) }
        func equals(_ a: Int, _ b: Int) -> Bool { x[a] == x[b] && y[a] == y[b] }
        func sign(_ v: Double) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }

        func pointInTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double, _ px: Double, _ py: Double) -> Bool {
            (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
            (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
            (bx - px) * (cy - py) >= (cx - px) * (by - py)
        }

        func onSegment(_ p: Int, _ q: Int, _ r: Int) -> Bool {
            x[q] <= max(x[p], x[r]) && x[q] >= min(x[p], x[r]) && y[q] <= max(y[p], y[r]) && y[q] >= min(y[p], y[r])
        }

        func intersects(_ p1: Int, _ q1: Int, _ p2: Int, _ q2: Int) -> Bool {
            let o1 = sign(area(p1, q1, p2)), o2 = sign(area(p1, q1, q2)), o3 = sign(area(p2, q2, p1)), o4 = sign(area(p2, q2, q1))
            if o1 != o2 && o3 != o4 { return true }
            if o1 == 0 && onSegment(p1, p2, q1) { return true }
            if o2 == 0 && onSegment(p1, q2, q1) { return true }
            if o3 == 0 && onSegment(p2, p1, q2) { return true }
            if o4 == 0 && onSegment(p2, q1, q2) { return true }
            return false
        }

        func intersectsPolygon(_ a: Int, _ b: Int) -> Bool {
            var p = a
            repeat {
                if idx[p] != idx[a] && idx[next[p]] != idx[a] && idx[p] != idx[b] && idx[next[p]] != idx[b] && intersects(p, next[p], a, b) { return true }
                p = next[p]
            } while p != a
            return false
        }

        func locallyInside(_ a: Int, _ b: Int) -> Bool {
            area(prev[a], a, next[a]) < 0
                ? area(a, b, next[a]) >= 0 && area(a, prev[a], b) >= 0
                : area(a, b, prev[a]) < 0 || area(a, next[a], b) < 0
        }

        func middleInside(_ a: Int, _ b: Int) -> Bool {
            var p = a, inside = false
            let px = (x[a] + x[b]) / 2, py = (y[a] + y[b]) / 2
            repeat {
                let n = next[p]
                if (y[p] > py) != (y[n] > py), y[n] != y[p], px < (x[n] - x[p]) * (py - y[p]) / (y[n] - y[p]) + x[p] { inside.toggle() }
                p = n
            } while p != a
            return inside
        }

        func isValidDiagonal(_ a: Int, _ b: Int) -> Bool {
            idx[next[a]] != idx[b] && idx[prev[a]] != idx[b] && !intersectsPolygon(a, b) &&
                ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b) && (area(prev[a], a, prev[b]) != 0 || area(a, prev[b], b) != 0)) ||
                 (equals(a, b) && area(prev[a], a, next[a]) > 0 && area(prev[b], b, next[b]) > 0))
        }

        // MARK: z 序

        func zOrder(_ px: Double, _ py: Double) -> Int {
            var a = Int((px - minX) * invSize), b = Int((py - minY) * invSize)
            a = (a | (a << 8)) & 0x00FF00FF; a = (a | (a << 4)) & 0x0F0F0F0F; a = (a | (a << 2)) & 0x33333333; a = (a | (a << 1)) & 0x55555555
            b = (b | (b << 8)) & 0x00FF00FF; b = (b | (b << 4)) & 0x0F0F0F0F; b = (b | (b << 2)) & 0x33333333; b = (b | (b << 1)) & 0x55555555
            return a | (b << 1)
        }

        mutating func indexCurve(_ start: Int) {
            var p = start
            repeat {
                if z[p] == 0 { z[p] = zOrder(x[p], y[p]) }
                prevZ[p] = prev[p]; nextZ[p] = next[p]
                p = next[p]
            } while p != start
            nextZ[prevZ[p]] = -1
            prevZ[p] = -1
            sortLinked(p)
        }

        mutating func sortLinked(_ head: Int) {
            var list = head, inSize = 1, numMerges = 0
            repeat {
                var p = list, tail = -1
                list = -1; numMerges = 0
                while p >= 0 {
                    numMerges += 1
                    var q = p, pSize = 0
                    for _ in 0..<inSize { pSize += 1; q = nextZ[q]; if q < 0 { break } }
                    var qSize = inSize
                    while pSize > 0 || (qSize > 0 && q >= 0) {
                        let e: Int
                        if pSize != 0 && (qSize == 0 || q < 0 || z[p] <= z[q]) { e = p; p = nextZ[p]; pSize -= 1 }
                        else { e = q; q = nextZ[q]; qSize -= 1 }
                        if tail >= 0 { nextZ[tail] = e } else { list = e }
                        prevZ[e] = tail
                        tail = e
                    }
                    p = q
                }
                nextZ[tail] = -1
                inSize *= 2
            } while numMerges > 1
        }

        // MARK: 耳切

        func isEar(_ ear: Int) -> Bool {
            let a = prev[ear], b = ear, c = next[ear]
            if area(a, b, c) >= 0 { return false }
            let x0 = min(x[a], x[b], x[c]), y0 = min(y[a], y[b], y[c]), x1 = max(x[a], x[b], x[c]), y1 = max(y[a], y[b], y[c])
            var p = next[c]
            while p != a {
                if x[p] >= x0 && x[p] <= x1 && y[p] >= y0 && y[p] <= y1 &&
                    pointInTriangle(x[a], y[a], x[b], y[b], x[c], y[c], x[p], y[p]) && area(prev[p], p, next[p]) >= 0 { return false }
                p = next[p]
            }
            return true
        }

        func isEarHashed(_ ear: Int) -> Bool {
            let a = prev[ear], b = ear, c = next[ear]
            if area(a, b, c) >= 0 { return false }
            let x0 = min(x[a], x[b], x[c]), y0 = min(y[a], y[b], y[c]), x1 = max(x[a], x[b], x[c]), y1 = max(y[a], y[b], y[c])
            let minZ = zOrder(x0, y0), maxZ = zOrder(x1, y1)
            func blocks(_ p: Int) -> Bool {
                p != a && p != c && x[p] >= x0 && x[p] <= x1 && y[p] >= y0 && y[p] <= y1 &&
                    pointInTriangle(x[a], y[a], x[b], y[b], x[c], y[c], x[p], y[p]) && area(prev[p], p, next[p]) >= 0
            }
            var p = prevZ[ear], n = nextZ[ear]
            while p >= 0 && z[p] >= minZ && n >= 0 && z[n] <= maxZ {
                if blocks(p) { return false }
                p = prevZ[p]
                if blocks(n) { return false }
                n = nextZ[n]
            }
            while p >= 0 && z[p] >= minZ { if blocks(p) { return false }; p = prevZ[p] }
            while n >= 0 && z[n] <= maxZ { if blocks(n) { return false }; n = nextZ[n] }
            return true
        }

        mutating func filterPoints(_ start: Int, _ endIn: Int) -> Int {
            guard start >= 0 else { return start }
            var end = endIn < 0 ? start : endIn
            var p = start, again = false
            repeat {
                again = false
                if equals(p, next[p]) || area(prev[p], p, next[p]) == 0 {
                    let pp = prev[p]
                    remove(p)
                    p = pp; end = pp
                    if p == next[p] { break }
                    again = true
                } else {
                    p = next[p]
                }
            } while again || p != end
            return end
        }

        mutating func earcutLinked(_ start: Int, pass: Int) {
            guard start >= 0 else { return }
            var ear = start
            if pass == 0 && invSize != 0 { indexCurve(ear) }
            var stop = ear
            while prev[ear] != next[ear] {
                let p = prev[ear], n = next[ear]
                if invSize != 0 ? isEarHashed(ear) : isEar(ear) {
                    tris += [idx[p], idx[ear], idx[n]]
                    remove(ear)
                    ear = next[n]; stop = next[n]
                    continue
                }
                ear = n
                if ear == stop {
                    if pass == 0 { earcutLinked(filterPoints(ear, -1), pass: 1) }
                    else if pass == 1 { let e = cureLocalIntersections(filterPoints(ear, -1)); earcutLinked(e, pass: 2) }
                    else { splitEarcut(ear) }
                    break
                }
            }
        }

        mutating func cureLocalIntersections(_ startIn: Int) -> Int {
            var start = startIn, p = startIn
            repeat {
                let a = prev[p], b = next[next[p]]
                if !equals(a, b) && intersects(a, p, next[p], b) && locallyInside(a, b) && locallyInside(b, a) {
                    tris += [idx[a], idx[p], idx[b]]
                    let pn = next[p]
                    remove(p); remove(pn)
                    p = b; start = b
                }
                p = next[p]
            } while p != start
            return filterPoints(p, -1)
        }

        mutating func splitPolygon(_ a: Int, _ b: Int) -> Int {
            let a2 = create(idx[a], x[a], y[a]), b2 = create(idx[b], x[b], y[b])
            let an = next[a], bp = prev[b]
            next[a] = b; prev[b] = a
            next[a2] = an; prev[an] = a2
            next[b2] = a2; prev[a2] = b2
            next[bp] = b2; prev[b2] = bp
            return b2
        }

        mutating func splitEarcut(_ start: Int) {
            var a = start
            repeat {
                var b = next[next[a]]
                while b != prev[a] {
                    if idx[a] != idx[b] && isValidDiagonal(a, b) {
                        var c = splitPolygon(a, b)
                        let a1 = filterPoints(a, next[a])
                        c = filterPoints(c, next[c])
                        earcutLinked(a1, pass: 0)
                        earcutLinked(c, pass: 0)
                        return
                    }
                    b = next[b]
                }
                a = next[a]
            } while a != start
        }
    }
}
