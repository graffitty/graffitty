Open three panes in one tab and select the third. Close the first pane: the
sheet stays bound to the third pane, while the tab's first terminal is now the
second.

Select the second pane. The sheet must rebind to it at once, with no tab
transition. Select the third pane again: still no transition.

The replay checks `tab_fx_t` stays below zero after each selection.
