// Keep Chromium's commands and website context-menu semantics, but let the
// owning Godot pane display the menu in its own coordinate system. Chromium's
// ui/menus/cocoa/text_services_context_menu.h owns these IDs.
//
// They belong to the Cocoa submenu delegate, not RenderViewContextMenu.
static constexpr int speechStartCommand = 101, speechStopCommand = 102;
@interface NSApplication (GraffittyContextSpeech)
- (void)speakString:(NSString *)text;
- (IBAction)stopSpeaking:(id)sender;
@end
static CefRefPtr<CefRunContextMenuCallback> contextCallback;
static NSString *contextSelection = @"";
static int contextWindow = 0;
static uint64_t contextSerial = 0;
static std::set<int> contextCommands;
static NSString *contextRequest = @"";
static void contextEvent(NSArray *items) {
    NSDictionary *menu = @{@"id":@(contextSerial), @"request":contextRequest, @"items":items, @"windowId":@(contextWindow)};
    serverReply(@{@"method":@"Graffitty.contextMenu", @"params":menu});
}
static NSArray *contextItems(CefRefPtr<CefMenuModel> model, int depth = 0) {
    NSMutableArray *items = [NSMutableArray new];
    if (!model || depth > 6) return items;
    for (size_t i = 0; i < model->GetCount(); ++i) {
        if (!model->IsVisibleAt(i)) continue;
        int type = model->GetTypeAt(i), command = model->GetCommandIdAt(i);
        bool enabled = model->IsEnabledAt(i);
        NSMutableDictionary *item = [@{@"id":@(command), @"type":@(type),
            @"label":@(model->GetLabelAt(i).ToString().c_str()), @"enabled":@(enabled),
            @"checked":@(model->IsCheckedAt(i))} mutableCopy];
        if (type == MENUITEMTYPE_SUBMENU) item[@"items"] = contextItems(model->GetSubMenuAt(i), depth + 1);
        else if (enabled && type != MENUITEMTYPE_SEPARATOR) contextCommands.insert(command);
        [items addObject:item];
    }
    return items;
}
static NSMutableDictionary<NSNumber *, NSString *> *selectRequests;
static NSMenu *activeSelect;
static NSInteger selectedOption = -1;

static void chooseContext(uint64_t serial, int command) {
    if (serial != contextSerial) return;
    if (activeSelect) {
        selectedOption = command >= 0 && command < activeSelect.numberOfItems &&
            [activeSelect itemAtIndex:command].enabled ? command : -1;
        activeSelect = nil;
        return;
    }
    if (!contextCallback) return;
    auto callback = contextCallback;
    contextCallback = nullptr;
    bool allowed = contextCommands.count(command);
    contextCommands.clear();
    NSString *selection = contextSelection;
    contextSelection = @"";
    if (allowed && (command == speechStartCommand || command == speechStopCommand)) {
        // CEF Continue() dispatches to the root browser-command delegate; its
        // metrics validation aborts on Cocoa speech IDs. Match Chromium's
        // TextServicesContextMenu delegate using the selection from this menu.
        callback->Cancel();
        if (command == speechStartCommand) [NSApp speakString:selection];
        else [NSApp stopSpeaking:nil];
    }
    else if (allowed) callback->Continue(command, EVENTFLAG_NONE);
    else callback->Cancel();
}
static void trackContextInput(CefRefPtr<CefDictionaryValue> params) {
    if (params && params->GetString("button") == "left" && params->GetString("type") == "mousePressed" && view().active) {
        selectRequests[@(view().active->GetIdentifier())] = @(params->GetString("contextMenuRequest").ToString().c_str());
    }
    if (params && params->GetString("button") == "right" && params->GetString("type") == "mousePressed")
        contextRequest = @(params->GetString("contextMenuRequest").ToString().c_str());
}

// Only redirect menus belonging to a captured, registered browser window.
static std::shared_ptr<WindowView> selectMenuView(NSView *anchor) {
    if (!anchor.window || anchor.window.visible || activeSelect) return nullptr;
    for (auto &page : pages) {
        auto state = viewFor(page);
        if (windowFor(page) == anchor.window && state->active == page && state->id &&
            [selectRequests[@(page->GetIdentifier())] length]) return state;
    }
    return nullptr;
}

// Chromium attaches the popup before entering its tracking loop. Suppress both
// steps for captured pages: attach alone can show a menu at the hidden host's
// coordinates, even when performClick is redirected to the owning client.
static void installSelectMenuBridge() {
    selectRequests = [NSMutableDictionary new];
    Class cls = NSPopUpButtonCell.class;
    SEL attach = @selector(attachPopUpWithFrame:inView:);
    Method attachMethod = class_getInstanceMethod(cls, attach);
    IMP originalAttach = method_getImplementation(attachMethod);
    IMP attachBridge = imp_implementationWithBlock(^(NSPopUpButtonCell *cell, NSRect frame, NSView *anchor) {
        if (!selectMenuView(anchor))
            ((void (*)(id, SEL, NSRect, NSView *))originalAttach)(cell, attach, frame, anchor);
    });
    if (!class_addMethod(cls, attach, attachBridge, method_getTypeEncoding(attachMethod)))
        class_replaceMethod(cls, attach, attachBridge, method_getTypeEncoding(attachMethod));
    SEL selector = @selector(performClickWithFrame:inView:);
    Method method = class_getInstanceMethod(cls, selector);
    IMP original = method_getImplementation(method);
    IMP bridge = imp_implementationWithBlock(^(NSPopUpButtonCell *cell, NSRect frame, NSView *anchor) {
        auto state = selectMenuView(anchor);
        NSString *request = state ? selectRequests[@(state->active->GetIdentifier())] : nil;
        int windowId = state ? state->id : 0;
        if (!request.length || !windowId) {
            ((void (*)(id, SEL, NSRect, NSView *))original)(cell, selector, frame, anchor);
            return;
        }
        chooseContext(contextSerial, -1);
        const auto serial = ++contextSerial;
        contextRequest = request;
        contextWindow = windowId;
        NSMenu *menu = cell.menu;
        NSMutableArray *items = [NSMutableArray new];
        for (NSInteger index = 0; index < menu.numberOfItems; ++index) {
            NSMenuItem *item = [menu itemAtIndex:index];
            if (!item.hidden) [items addObject:@{@"id": @(index), @"type": @(item.separatorItem ? 4 : 3),
                @"label": item.title, @"enabled": @(item.enabled && !item.separatorItem),
                @"checked": @(index == cell.indexOfSelectedItem)}];
        }
        if (!items.count) return;
        activeSelect = menu;
        selectedOption = -1;
        contextEvent(items);
        // AppKit's native picker runs a nested loop too. Keep serving the
        // owning client until selection, dismissal, shutdown or lost focus.
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
        while (activeSelect == menu && !ending && !anchor.window.visible &&
               anchor.superview && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        activeSelect = nil;
        if (serial != contextSerial) return;
        if (selectedOption >= 0) [menu performActionForItemAtIndex:selectedOption];
        contextEvent(@[]);
    });
    if (!class_addMethod(cls, selector, bridge, method_getTypeEncoding(method)))
        class_replaceMethod(cls, selector, bridge, method_getTypeEncoding(method));
}
