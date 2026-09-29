# Split chat ownership

`BrowserState.aiChatTabs` remains the source of chat-tab ownership. Web-content
controllers use the ordinary per-tab identifier; chat code uses
`chatIdentifier(for:)` so both panes can resolve to one shared chat.

The resolver first reuses an existing pane chat, then an in-flight creation.
If neither exists, it uses the invoking tab's identifier. It does not choose an
unrelated currently focused pane. Keeping in-flight creation in the resolution
prevents the other pane from starting a duplicate chat.

When a new split contains two existing chats, reconciliation keeps the foreground
pane's chat and closes the other. If a closing pane owns the shared chat, the
binding migrates to the surviving pane. Changing split primary/secondary roles
does not itself change the tab-keyed binding.

Creation also synchronizes chat collapse state across the panes, preferring
expanded when either pane had chat open. The historical proposal's exclusion of
collapse-state sharing is not the current behavior.

## Source and checks

- [Resolver and migration](../../Sources/States/BrowserState.swift)
- [Split reconciliation and collapse state](../../Sources/States/BrowserState+Split.swift)
- [Embedded chat](../../Sources/UserInterface/Chat/EmbeddedChatViewController.swift)
- [Binding tests](../../Tests/PhiBrowserTests/SplitChatBindingTests.swift)
- [Collapse tests](../../Tests/PhiBrowserTests/BrowserStateCollapseAIChatTests.swift)

Check creating a split with zero, one and two existing chats; invoking chat from
either pane while creation is pending; switching/reversing panes; and closing the
owner versus survivor. Do not replace this derivation with a parallel global
split-to-chat ownership map.
