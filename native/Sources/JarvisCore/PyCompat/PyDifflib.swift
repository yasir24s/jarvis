import Foundation

// Python 3.14 `difflib.SequenceMatcher(None, a, b)` with autojunk=True (plan: M01 §3.4),
// ported from the installed difflib.py: `__chain_b` (line 266), `find_longest_match` (305),
// `get_matching_blocks` (421), `ratio` (597) and `_calculate_ratio` (39). Proven against
// Python by the `m1_difflib` golden suite: ratio compared by bit pattern, blocks exactly.
//
// Sequences are arrays of Unicode scalars, because Python iterates `str` by code point.
// Elements compare by scalar value, never by Swift's canonical equivalence.

public enum PyDifflib {
    /// `difflib.SequenceMatcher(None, a, b).ratio()`: `2.0 * M / T` over code points, where M
    /// is the matched element count and T = len(a) + len(b); 1.0 when both are empty.
    public static func ratio(_ a: String, _ b: String) -> Double {
        let sa = Array(a.unicodeScalars), sb = Array(b.unicodeScalars)
        let matches = matchingBlocks(sa, sb).reduce(0) { $0 + $1.size }
        return calculateRatio(matches, sa.count + sb.count)
    }

    /// `difflib.SequenceMatcher(None, a, b).get_matching_blocks()`: ascending, non-adjacent
    /// blocks with `a[a..<a+size] == b[b..<b+size]`, ending with the dummy (len(a), len(b), 0).
    public static func matchingBlocks(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> [(a: Int, b: Int, size: Int)] {
        var m = Matcher(a, b)
        return m.matchingBlocks()
    }

    /// `_calculate_ratio`: `2.0 * matches / length`, evaluated left to right as Python does,
    /// so the double is bit-identical.
    static func calculateRatio(_ matches: Int, _ length: Int) -> Double {
        length != 0 ? 2.0 * Double(matches) / Double(length) : 1.0
    }
}

/// One `SequenceMatcher(None, a, b)` (autojunk=True). `isjunk` is None, so `bjunk` is empty.
private struct Matcher {
    let a: [Unicode.Scalar]
    let b: [Unicode.Scalar]
    /// `b2j`: element of b → its indices in b, ascending; popular elements deleted.
    let b2j: [Unicode.Scalar: [Int]]

    // find_longest_match's `j2len` (previous row) and `newj2len` (current row), stored as
    // arrays indexed by key + 1 (so the key j - 1 = -1 is slot 0, never written). A slot
    // holds a key only while its stamp equals the id of the row that wrote it, which gives
    // exactly the key set of Python's per-row dicts without allocating one per row.
    private var prevLen: [Int]
    private var prevStamp: [Int]
    private var curLen: [Int]
    private var curStamp: [Int]
    private var serial = 0

    init(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) {
        self.a = a
        self.b = b
        // __chain_b
        var b2j: [Unicode.Scalar: [Int]] = [:]
        for (i, elt) in b.enumerated() {
            b2j[elt, default: []].append(i)
        }
        // No isjunk, so no junk purge. Purge popular elements (they are not added to bjunk).
        let n = b.count
        if n >= 200 {
            let ntest = n / 100 + 1
            let popular = b2j.filter { $0.value.count > ntest }.map(\.key)
            for elt in popular {
                b2j.removeValue(forKey: elt)
            }
        }
        self.b2j = b2j
        let slots = b.count + 1
        prevLen = [Int](repeating: 0, count: slots)
        prevStamp = [Int](repeating: -1, count: slots)
        curLen = prevLen
        curStamp = prevStamp
    }

    mutating func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        // j2len = {}: a fresh row id that no slot carries.
        var prevRow = serial
        serial += 1
        for i in alo..<max(alo, ahi) {
            let row = serial
            serial += 1
            // newj2len = {}
            if let js = b2j[a[i]] {
                for j in js {
                    if j < blo { continue }
                    if j >= bhi { break }
                    // k = newj2len[j] = j2len.get(j-1, 0) + 1
                    let k = (prevStamp[j] == prevRow ? prevLen[j] : 0) + 1
                    curLen[j + 1] = k
                    curStamp[j + 1] = row
                    if k > bestsize {
                        besti = i - k + 1
                        bestj = j - k + 1
                        bestsize = k
                    }
                }
            }
            // j2len = newj2len
            swap(&prevLen, &curLen)
            swap(&prevStamp, &curStamp)
            prevRow = row
        }
        // Extend over non-junk elements (every element: bjunk is empty, so Python's two
        // junk-extension loops never run). This is how popular elements get matched.
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1
            bestj -= 1
            bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }

    mutating func matchingBlocks() -> [(a: Int, b: Int, size: Int)] {
        let la = a.count, lb = b.count
        var queue = [(0, la, 0, lb)]
        var blocks: [(Int, Int, Int)] = []
        while let q = queue.popLast() {
            let (alo, ahi, blo, bhi) = q
            let x = findLongestMatch(alo, ahi, blo, bhi)
            let (i, j, k) = x
            if k != 0 {
                blocks.append(x)
                if alo < i && blo < j {
                    queue.append((alo, i, blo, j))
                }
                if i + k < ahi && j + k < bhi {
                    queue.append((i + k, ahi, j + k, bhi))
                }
            }
        }
        blocks.sort { $0 < $1 }
        // Collapse adjacent equal blocks.
        var i1 = 0, j1 = 0, k1 = 0
        var nonAdjacent: [(a: Int, b: Int, size: Int)] = []
        for (i2, j2, k2) in blocks {
            if i1 + k1 == i2 && j1 + k1 == j2 {
                k1 += k2
            } else {
                if k1 != 0 {
                    nonAdjacent.append((i1, j1, k1))
                }
                (i1, j1, k1) = (i2, j2, k2)
            }
        }
        if k1 != 0 {
            nonAdjacent.append((i1, j1, k1))
        }
        nonAdjacent.append((la, lb, 0))
        return nonAdjacent
    }
}
