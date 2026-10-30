import AppKit

final class MetadataSettings: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:390,height:520),styleMask:[.titled],backing:.buffered,defer:false)
    let table = NSTableView()
    var fields: [MetadataField]
    let completion: ([MetadataField]) -> Void
    init(fields: [MetadataField], completion: @escaping ([MetadataField]) -> Void) {
        self.fields = fields; self.completion = completion; super.init()
        panel.title = "自定义元数据"; panel.appearance = NSAppearance(named:.darkAqua)
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top:18,left:18,bottom:16,right:18); stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor),stack.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor),stack.topAnchor.constraint(equalTo:panel.contentView!.topAnchor),stack.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor)])
        stack.addArrangedSubview(label("勾选要显示的字段，选中一行后调整顺序。",size:12,color:.secondaryLabelColor))
        let column = NSTableColumn(identifier:.init("field")); column.title = "字段"; column.width = 330; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 26; table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        let scroller = scroll(table); stack.addArrangedSubview(scroller); scroller.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-36).isActive = true
        let controls = NSStackView(); controls.spacing = 8
        for v in [button("上移",symbol:"arrow.up",target:self,action:#selector(up)),button("下移",symbol:"arrow.down",target:self,action:#selector(down)),button("恢复默认",target:self,action:#selector(reset)),NSView(),button("取消",target:self,action:#selector(cancel)),button("保存",target:self,action:#selector(save))] { controls.addArrangedSubview(v) }
        stack.addArrangedSubview(controls); controls.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-36).isActive = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { fields.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let checkbox = NSButton(checkboxWithTitle:fields[row].title,target:self,action:#selector(toggle(_:))); checkbox.state = fields[row].visible ? .on : .off; checkbox.tag = row; return checkbox
    }
    @objc func toggle(_ sender: NSButton) { fields[sender.tag].visible = sender.state == .on }
    func move(_ step: Int) {
        let row = table.selectedRow; let next = row+step
        guard fields.indices.contains(row), fields.indices.contains(next) else { return }
        fields.swapAt(row,next); table.reloadData(); table.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:false); table.scrollRowToVisible(next)
    }
    @objc func up() { move(-1) }
    @objc func down() { move(1) }
    @objc func reset() { fields = MetadataField.defaults; table.reloadData() }
    @objc func cancel() { panel.sheetParent?.endSheet(panel) }
    @objc func save() { completion(fields); panel.sheetParent?.endSheet(panel) }
}
