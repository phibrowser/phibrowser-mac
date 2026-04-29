// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit

/// NSTableCellView host for `TabGroupHeaderView` — bridges the
/// `TabGroupSidebarItem` row in NSOutlineView to its SwiftUI rendering.
/// Created lazily by `SidebarTabListViewController.outlineView(_:viewFor:item:)`
/// and reused via `prepareForReuse`. Click-to-collapse routing lands in the
/// next chunk; this chunk is visual-only.
class TabGroupHeaderCellView: SidebarCellView {
    private var hostingView: ThemedHostingView!
    private let viewModel = TabGroupHeaderViewModel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        viewModel.cancelSubscriptions()
    }

    private func setupViews() {
        hostingView = ThemedHostingView(rootView: TabGroupHeaderView(viewModel: viewModel))
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func configureAppearance() {
        guard let groupItem = item as? TabGroupSidebarItem,
              let state = MainBrowserWindowControllersManager.shared
                .controller(for: groupItem.windowId)?.browserState
        else { return }
        viewModel.configure(with: groupItem.group, in: state)
    }
}
