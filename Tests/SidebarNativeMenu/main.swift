import AppKit

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let data = Data(#"[{"title":"Recent","items":[{"id":"0.0","title":"A chat","checked":true,"icon":"bubble.left"}]},{"separator":true},{"id":"2","title":"Delete","enabled":false},{"id":"3","title":"Rename"}]"#.utf8)
    let items = try! JSONDecoder().decode([SidebarNativeMenuItem].self, from: data)
    let selection = SidebarNativeMenuSelection()
    let menu = selection.makeMenu(items)
    precondition(menu.autoenablesItems == false)
    precondition(menu.items.count == 4)
    precondition(menu.items[1].isSeparatorItem)
    precondition(menu.items[2].isEnabled == false)
    precondition(menu.items.allSatisfy { $0.view == nil })
    let child = menu.items[0].submenu!.items[0]
    precondition(child.state == .on)
    precondition(child.image != nil)
    precondition(child.representedObject as? String == "0.0")
    selection.selectItem(menu.items[2])
    precondition(selection.selectedId == nil)
    selection.selectItem(child)
    precondition(selection.selectedId == "0.0")
    print("Native NSMenu model checks passed")
}
