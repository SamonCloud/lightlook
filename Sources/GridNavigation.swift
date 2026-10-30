import Foundation

/// 按实际排版后的行定位，避免从窗口宽度估算列数导致跳错行。
struct GridRowNavigation {
    struct Destination: Equatable {
        let index: Int
        let preferredX: CGFloat
    }
    static func destination(current: Int, count: Int, direction: Int, preferredX: CGFloat?, frameAt: (Int) -> CGRect?) -> Destination? {
        guard count > 0, (0..<count).contains(current), direction == -1 || direction == 1,
              let currentFrame = frameAt(current) else { return nil }
        let x = preferredX ?? currentFrame.midX
        // FlowLayout 按行排列的 item 下标对应的 y 坐标单调递增。
        func firstRow(after y: CGFloat) -> Int? {
            var low = 0, high = count
            while low < high {
                let middle = low + (high-low)/2
                guard let frame = frameAt(middle) else { return nil }
                if frame.minY > y { high = middle } else { low = middle+1 }
            }
            return low
        }
        let neighbour: Int
        if direction > 0 {
            guard let first = firstRow(after:currentFrame.minY+0.5), first < count else { return nil }
            neighbour = first
        } else {
            guard let first = firstRow(after:currentFrame.minY-0.5), first > 0 else { return nil }
            neighbour = first-1
        }
        guard let targetFrame = frameAt(neighbour),
              let start = firstRow(after:targetFrame.minY-0.5),
              let end = firstRow(after:targetFrame.minY+0.5), start < end else { return nil }
        var best = start
        var distance = CGFloat.greatestFiniteMagnitude
        for index in start..<end {
            guard let frame = frameAt(index) else { return nil }
            let delta = abs(frame.midX-x)
            if delta < distance { best = index; distance = delta }
        }
        return Destination(index:best,preferredX:x)
    }
}
