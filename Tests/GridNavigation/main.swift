import AppKit

func require(_ condition: @autoclosure () -> Bool,_ message: String) { if !condition() { fputs("FAIL: \(message)\n",stderr); exit(1) } }
func rectangles(count: Int, columns: Int) -> [CGRect] {
    (0..<count).map { CGRect(x:14+($0%columns)*187,y:12+($0/columns)*192,width:170,height:175) }
}
func move(_ index: Int,_ direction: Int,_ frames: [CGRect],_ preferredX: CGFloat? = nil) -> GridRowNavigation.Destination? {
    GridRowNavigation.destination(current:index,count:frames.count,direction:direction,preferredX:preferredX,frameAt:{ frames[$0] })
}
let frames = rectangles(count:12,columns:5)
require(move(2,1,frames)?.index == 7,"down keeps same column")
require(move(7,-1,frames)?.index == 2,"up keeps same column")
require(move(3,-1,frames) == nil,"first row does not wrap")
require(move(11,1,frames) == nil,"last row does not wrap")
let down = move(8,1,frames)!
require(down.index == 11,"short final row clamps to nearest photo")
require(move(11,-1,frames,down.preferredX)?.index == 8,"up restores preferred column after short row")
require(move(0,1,rectangles(count:4,columns:1))?.index == 1,"single column")
require(move(0,1,[]) == nil,"empty view")
require(move(0,1,rectangles(count:1,columns:4)) == nil,"single photo")
require(GridRowNavigation.destination(current:0,count:2,direction:1,preferredX:nil,frameAt:{ _ in nil }) == nil,"unavailable layout safely ignored")

// 在不同宽度、缩略图尺寸下使用真实 AppKit 排版，避免仅验证固定列数公式。
final class FixtureCell: NSCollectionViewItem {
    override func loadView() { view = NSView() }
}
final class FixtureSource: NSObject, NSCollectionViewDataSource {
    let count = 23
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem { collectionView.makeItem(withIdentifier:.init("cell"),for:indexPath) }
}
for width in [370.0,610.0,980.0] {
    for size in [110.0,170.0,280.0] {
        let source = FixtureSource()
        let collection = NSCollectionView(frame:NSRect(x:0,y:0,width:width,height:3000))
        let flow = NSCollectionViewFlowLayout(); flow.itemSize = NSSize(width:size,height:size+5)
        flow.minimumInteritemSpacing = 10; flow.minimumLineSpacing = 10; flow.sectionInset = NSEdgeInsets(top:12,left:14,bottom:14,right:14)
        collection.collectionViewLayout = flow; collection.dataSource = source
        collection.register(FixtureCell.self,forItemWithIdentifier:.init("cell")); collection.reloadData(); collection.layoutSubtreeIfNeeded(); flow.prepare()
        let actual = (0..<source.count).compactMap { flow.layoutAttributesForItem(at:IndexPath(item:$0,section:0))?.frame }
        require(actual.count == source.count,"AppKit produced all item frames")
        for current in actual.indices {
            for direction in [-1,1] {
                let rows = Set(actual.map(\.minY)).sorted()
                let row = rows.firstIndex(of:actual[current].minY)!
                let targetRow = row+direction
                let result = move(current,direction,actual)
                if rows.indices.contains(targetRow) {
                    let candidates = actual.indices.filter { actual[$0].minY == rows[targetRow] }
                    let expected = candidates.min { abs(actual[$0].midX-actual[current].midX) < abs(actual[$1].midX-actual[current].midX) }!
                    require(result?.index == expected,"actual grid width=\(width), size=\(size), index=\(current), direction=\(direction)")
                } else { require(result == nil,"actual grid boundary does not wrap") }
            }
        }
    }
}
print("PASS grid rows, preferred column, short final row, boundaries and 9 real AppKit layouts")

// 回归：选择移出视口后，真实 NSClipView 必须随之滚动，而非仅改变 selection。
for width in [370.0,610.0,980.0] {
    for size in [110.0,170.0,280.0] {
        let source = FixtureSource()
        let scroller = NSScrollView(frame:NSRect(x:0,y:0,width:width,height:250))
        scroller.hasVerticalScroller = true; scroller.autohidesScrollers = true
        let collection = NSCollectionView(frame:NSRect(x:0,y:0,width:scroller.contentSize.width,height:10000))
        let flow = NSCollectionViewFlowLayout(); flow.itemSize = NSSize(width:size,height:size+5)
        flow.minimumInteritemSpacing = 10; flow.minimumLineSpacing = 10; flow.sectionInset = NSEdgeInsets(top:12,left:14,bottom:14,right:14)
        collection.collectionViewLayout = flow; collection.dataSource = source
        collection.register(FixtureCell.self,forItemWithIdentifier:.init("cell")); scroller.documentView = collection
        collection.reloadData(); scroller.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded(); flow.prepare()
        let last = source.count-1
        require(CollectionSelectionVisibility.reveal(index:last,collection:collection,scrollView:scroller),"downward auto-scroll width=\(width), size=\(size)")
        require(scroller.contentView.bounds.origin.y > 0,"clip origin actually moved downward")
        require(CollectionSelectionVisibility.reveal(index:0,collection:collection,scrollView:scroller),"upward auto-scroll width=\(width), size=\(size)")
        require(scroller.contentView.bounds.origin.y <= 12,"clip returned to first row")
        let before = scroller.contentView.bounds.origin
        CollectionSelectionVisibility.reveal(index:0,collection:collection,scrollView:scroller)
        require(scroller.contentView.bounds.origin == before,"visible selection does not jitter")
        require(!CollectionSelectionVisibility.reveal(index:source.count,collection:collection,scrollView:scroller),"invalid selection is ignored")
    }
}
print("PASS actual clip-view scroll down/up, edge clamping, large thumbnails, visible-item stability in 9 layouts")
