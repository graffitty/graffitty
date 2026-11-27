#import <GameController/GameController.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Terminal text entry on iOS/iPadOS.
//
// Godot 4.7/4.8 reuse one hidden UITextView (GDTKeyboardInputView) for every
// text control. It diffs the whole view after each change and replays the
// difference as Backspace and character keys. For a terminal that streams
// every intermediate edit of a composition to the remote program: the Korean
// keyboard rewrites the syllable before the caret on each jamo (ㅎ, ⌫ 하, ⌫ 한),
// and Japanese/Chinese marked text is sent before a candidate is chosen. With
// a hardware keyboard and no first responder, keys bypass the input method:
// Hangul arrives as loose jamo and the input source cannot be switched.
//
// While a terminal owns the keyboard, this shim takes over the view:
// - Marked text and the Hangul syllable before the caret are shown as preedit
//   and sent once they are final. Everything else streams immediately through
//   Godot's own key path, so the key bar's modifiers still apply.
// - The view holds only padding plus the open syllable, so Backspace always has
//   something to delete and the caret cannot drift from the terminal's.
// - With a hardware keyboard the view is first responder whenever a terminal
//   owns input; iPadOS then shows its shortcut bar, not the keyboard.
// - Hardware navigation and modifier chords go to the terminal as keys rather
//   than editing the hidden view, in order with the text around them. While
//   text is marked, UIKit keeps navigation keys for its candidate list.

@protocol GFTTerminalKeyboardHost
@property(readonly) UITextView *keyboardView;
@end

@interface UITextView (GFTGodotKeyboard)
- (BOOL)becomeFirstResponderWithString:(NSString *)existingString cursorStart:(NSInteger)start cursorEnd:(NSInteger)end;
- (void)deleteText:(NSInteger)charactersToDelete;
- (void)enterText:(NSString *)substring;
- (void)setPreviousText:(NSString *)text;
- (void)setPreviousSelectedRange:(NSRange)range;
@end

static const NSUInteger kPadding = 8;
static NSString *const kPad = @"\u200B";

// Rust (ios_terminal_ime.rs) turns these into Godot key events.
extern void gft_ios_terminal_ime_dispatch_key(int32_t code, int32_t mods);

static __weak UITextView *g_view;
static BOOL g_active;
// The view holds this shim's padding layout. Godot clears the view when the
// keyboard hides, and a LineEdit may fill it with its own text.
static BOOL g_session;
// Nesting count of programmatic edits; their notifications are not user input.
static int g_handling;
// The view became first responder for a hardware keyboard, not by Graffitty's
// keyboard button.
static BOOL g_auto_shown;
// The open Hangul syllable before the caret, kept in the view and not sent.
static NSString *g_held = @"";
// Text already sent that still sits in the view before marked text.
static NSString *g_sent = @"";
// Padding characters already reported as Backspace since the last layout.
static NSInteger g_pad_erased;
// Hardware keys whose press went to the terminal; their release does too.
static NSMutableSet<NSNumber *> *g_pressed;
static NSString *g_preedit = @"";
static NSInteger g_preedit_caret = -1;
static uint64_t g_preedit_generation;
static NSArray<NSNumber *> *g_saved_traits;

static void (*original_observe)(id, SEL, NSNotification *);
static BOOL (*original_become)(id, SEL, NSString *, NSInteger, NSInteger);
static BOOL (*original_resign)(id, SEL);
static Class g_class;

static BOOL is_hangul(unichar c) {
    return (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0x3131 && c <= 0x318E) || (c >= 0x1100 && c <= 0x11FF);
}

static NSString *padding(void) {
    return [@"" stringByPaddingToLength:kPadding withString:kPad startingAtIndex:0];
}

static NSUInteger characters(NSString *text) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *a, NSRange b, NSRange c, BOOL *d) { (void)a; (void)b; (void)c; (void)d; count++; }];
    return count;
}

// Length of the common prefix, on a composed-character boundary.
static NSUInteger common_prefix(NSString *a, NSString *b) {
    NSUInteger n = 0, limit = MIN(a.length, b.length);
    while (n < limit && [a characterAtIndex:n] == [b characterAtIndex:n]) n++;
    if (n < a.length) n = [a rangeOfComposedCharacterSequenceAtIndex:n].location;
    if (n < b.length) n = MIN(n, [b rangeOfComposedCharacterSequenceAtIndex:n].location);
    return n;
}

static void set_preedit(NSString *text, NSInteger caret) {
    if ([text isEqualToString:g_preedit] && caret == g_preedit_caret) return;
    g_preedit = [text copy];
    g_preedit_caret = caret;
    g_preedit_generation++;
}

// Rewrite the view to padding + the open syllable, caret at the end. Marked
// text is UIKit's until it commits, so a marked view is left alone.
static void normalize(UITextView *view) {
    if (view.markedTextRange != nil) return;
    NSString *wanted = [padding() stringByAppendingString:g_held];
    g_handling++;
    if (![view.text isEqualToString:wanted]) view.text = wanted;
    NSRange end = NSMakeRange(wanted.length, 0);
    if (!NSEqualRanges(view.selectedRange, end)) view.selectedRange = end;
    g_handling--;
    g_sent = @"";
    g_pad_erased = 0;
    g_session = YES;
}

typedef struct {
    NSInteger backspaces;
    NSString *text;
} Edit;

// What the terminal must receive for the view's current state. `finishing`
// ends the composition: the open syllable is sent too.
static Edit read_change(UITextView *view, BOOL finishing) {
    NSString *text = view.text ?: @"";
    NSString *marked = @"";
    NSUInteger base_end = text.length;
    NSInteger caret = -1;
    UITextRange *range = view.markedTextRange;
    if (range != nil && !range.isEmpty) {
        NSInteger start = [view offsetFromPosition:view.beginningOfDocument toPosition:range.start];
        NSInteger end = [view offsetFromPosition:view.beginningOfDocument toPosition:range.end];
        start = MAX(0, MIN(start, (NSInteger)text.length));
        end = MAX(start, MIN(end, (NSInteger)text.length));
        marked = [text substringWithRange:NSMakeRange(start, end - start)];
        base_end = start;
        NSInteger selection = (NSInteger)NSMaxRange(view.selectedRange) - start;
        caret = MAX(0, MIN(selection, (NSInteger)marked.length));
    }
    // Everything before marked text except the padding, wherever the caret
    // is: a caret moved into the padding inserts between padding characters.
    // A padding character gone is a Backspace, reported once.
    NSString *base = [text substringToIndex:base_end];
    NSUInteger padding_left = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if ([text characterAtIndex:i] == 0x200B) padding_left++;
    }
    // An empty view was reset (Godot clears it on keyboard show and hide);
    // a user deletes one character, or a word, at a time.
    NSInteger erased_total = padding_left < kPadding && text.length > 0 ? (NSInteger)(kPadding - padding_left) : 0;
    NSInteger erased = MAX(0, erased_total - g_pad_erased);
    g_pad_erased = MAX(g_pad_erased, erased_total);
    NSString *content = [base stringByReplacingOccurrencesOfString:kPad withString:@""];
    NSUInteger common = common_prefix(g_sent, content);
    // Hold the open syllable, unless it was already sent before marked text.
    NSString *held = @"";
    if (!finishing && marked.length == 0 && content.length > common) {
        NSRange last = [content rangeOfComposedCharacterSequenceAtIndex:content.length - 1];
        if (last.length == 1 && last.location >= common && is_hangul([content characterAtIndex:last.location])) {
            held = [content substringWithRange:last];
            content = [content substringToIndex:last.location];
        }
    }
    Edit edit = {erased + (NSInteger)characters([g_sent substringFromIndex:common]), [content substringFromIndex:common]};
    g_sent = content;
    g_held = held;
    set_preedit(marked.length > 0 ? marked : held, marked.length > 0 ? caret : -1);
    return edit;
}

static void stream(UITextView *view, Edit edit) {
    if (edit.backspaces > 0) [view deleteText:edit.backspaces];
    if (edit.text.length > 0) [view enterText:edit.text];
}

// Commits marked text and returns everything not yet sent, open syllable
// included. Returns an empty edit when the view is not this shim's.
static Edit finish_composition(UITextView *view) {
    Edit none = {0, @""};
    if (!g_session) return none;
    g_handling++;
    if (view.markedTextRange != nil) [view unmarkText];
    Edit edit = read_change(view, YES);
    g_held = @"";
    set_preedit(@"", -1);
    normalize(view);
    g_handling--;
    return edit;
}

static void gft_observe(id self, SEL command, NSNotification *notification) {
    if (!g_active || !g_session || self != g_view || notification.object != self) {
        original_observe(self, command, notification);
        return;
    }
    if (g_handling > 0) return;
    g_handling++;
    stream(self, read_change(self, NO));
    normalize(self);
    g_handling--;
}

// UIKit can commit marked text without changing the text, which posts no
// text-change notification.
static void gft_unmark(id self, SEL command) {
    struct objc_super parent = {self, class_getSuperclass(g_class)};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, command);
    if (!g_active || !g_session || self != g_view || g_handling > 0) return;
    // An explicit commit ends the composition, a final Hangul syllable too.
    stream(self, finish_composition(self));
}

// The caret belongs at the end; UIKit moves it with the keyboard's trackpad.
static void gft_selection(id self, SEL command, UITextView *view) {
    (void)command;
    (void)view;
    if (!g_active || !g_session || self != g_view || g_handling > 0) return;
    if (((UITextView *)self).markedTextRange != nil) return;
    g_handling++;
    stream(self, read_change(self, NO));
    normalize(self);
    g_handling--;
}

static BOOL gft_become(id self, SEL command, NSString *existing, NSInteger start, NSInteger end) {
    // A LineEdit is about to replace the text: send the composition first.
    if (g_active && self == g_view && existing.length > 0 && g_session) {
        stream(self, finish_composition(self));
        g_session = NO;
    }
    BOOL result = original_become(self, command, existing, start, end);
    if (g_active && self == g_view) {
        // A terminal opens the keyboard with no text; anything else is a
        // LineEdit that took the view first, and Godot's own diff keeps it.
        if (existing.length == 0) normalize(self);
        else g_session = NO;
    }
    return result;
}

static BOOL gft_resign(id self, SEL command) {
    // Hiding the keyboard ends the composition; the user typed that syllable.
    if (g_active && self == g_view && g_session && g_handling == 0) stream(self, finish_composition(self));
    // Godot clears the view next; the next keyboard show lays it out again.
    if (self == g_view) g_session = NO;
    return original_resign(self, command);
}

static int godot_key(UIKey *key) API_AVAILABLE(ios(13.4)) {
    switch (key.keyCode) {
        case UIKeyboardHIDUsageKeyboardEscape: return 4194305;
        case UIKeyboardHIDUsageKeyboardTab: return 4194306;
        case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return 4194308;
        case UIKeyboardHIDUsageKeyboardReturnOrEnter: return 4194309;
        case UIKeyboardHIDUsageKeyboardDeleteForward: return 4194312;
        case UIKeyboardHIDUsageKeyboardHome: return 4194317;
        case UIKeyboardHIDUsageKeyboardEnd: return 4194318;
        case UIKeyboardHIDUsageKeyboardLeftArrow: return 4194319;
        case UIKeyboardHIDUsageKeyboardUpArrow: return 4194320;
        case UIKeyboardHIDUsageKeyboardRightArrow: return 4194321;
        case UIKeyboardHIDUsageKeyboardDownArrow: return 4194322;
        case UIKeyboardHIDUsageKeyboardPageUp: return 4194323;
        case UIKeyboardHIDUsageKeyboardPageDown: return 4194324;
        default: break;
    }
    NSString *label = key.charactersIgnoringModifiers;
    if (label.length == 1) {
        unichar c = [label characterAtIndex:0];
        if (c >= 'a' && c <= 'z') return c - 32;
        if (c >= 32 && c < 127) return c;
    }
    return 0;
}

// Keys the terminal must receive as keys. Plain text, Return and Backspace
// stay with the input method so composition and candidate selection work.
static BOOL terminal_key(UITextView *view, UIKey *key, int *code, int *mods) API_AVAILABLE(ios(13.4)) {
    UIKeyModifierFlags flags = key.modifierFlags;
    *mods = ((flags & UIKeyModifierControl) ? 1 : 0) | ((flags & UIKeyModifierAlternate) ? 2 : 0)
        | ((flags & UIKeyModifierShift) ? 4 : 0) | ((flags & UIKeyModifierCommand) ? 8 : 0);
    *code = godot_key(key);
    if (*code == 0) return NO;
    BOOL chord = (flags & (UIKeyModifierControl | UIKeyModifierCommand)) != 0;
    // Control-Space switches input sources on iPadOS.
    if ((flags & UIKeyModifierControl) && key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar) return NO;
    // Arrows, Escape and Tab choose and cancel candidates while text is marked.
    if (!chord && view.markedTextRange != nil) return NO;
    switch (key.keyCode) {
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        case UIKeyboardHIDUsageKeyboardDeleteOrBackspace:
            return chord || (flags & UIKeyModifierAlternate);
        default:
            break;
    }
    return chord || *code >= 4194304;
}

static NSSet<UIPress *> *route_presses(id self, NSSet<UIPress *> *presses, BOOL began) API_AVAILABLE(ios(13.4)) {
    if (!g_active || !g_session || self != g_view) return presses;
    NSMutableSet<UIPress *> *rest = [NSMutableSet set];
    for (UIPress *press in presses) {
        int code = 0, mods = 0;
        NSNumber *usage = @(press.key.keyCode);
        if (!began) {
            // A release follows its press, whatever the mark state is now.
            if ([g_pressed containsObject:usage]) [g_pressed removeObject:usage];
            else [rest addObject:press];
            continue;
        }
        if (press.key == nil || !terminal_key(self, press.key, &code, &mods)) {
            [rest addObject:press];
            continue;
        }
        [g_pressed addObject:usage];
        // The composition precedes the key. Both go through Godot's input
        // queue, so later text cannot overtake the key.
        stream(self, finish_composition(self));
        gft_ios_terminal_ime_dispatch_key(code, mods);
    }
    return rest;
}

// The input method takes Return before presses reach this view, so modified
// Return (Shift+Enter, Alt+Enter: a new line in many terminal programs) is a
// key command, which UIKit matches first.
static NSArray<UIKeyCommand *> *return_commands(void) API_AVAILABLE(ios(13.4)) {
    static NSArray<UIKeyCommand *> *commands;
    if (commands) return commands;
    NSMutableArray<UIKeyCommand *> *list = [NSMutableArray array];
    const UIKeyModifierFlags chords[] = {
        UIKeyModifierShift, UIKeyModifierAlternate, UIKeyModifierControl,
        UIKeyModifierShift | UIKeyModifierAlternate, UIKeyModifierShift | UIKeyModifierControl,
    };
    for (size_t i = 0; i < sizeof(chords) / sizeof(chords[0]); i++) {
        UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:chords[i] action:@selector(gft_terminalReturn:)];
        if (@available(iOS 15.0, *)) command.wantsPriorityOverSystemBehavior = YES;
        [list addObject:command];
    }
    commands = list;
    return commands;
}

static NSArray<UIKeyCommand *> *gft_key_commands(id self, SEL command) {
    struct objc_super parent = {self, class_getSuperclass(g_class)};
    NSArray<UIKeyCommand *> *base = ((NSArray * (*)(struct objc_super *, SEL))objc_msgSendSuper)(&parent, command);
    if (!g_active || !g_session || self != g_view) return base;
    if (@available(iOS 13.4, *)) return base.count ? [base arrayByAddingObjectsFromArray:return_commands()] : return_commands();
    return base;
}

static void gft_terminal_return(id self, SEL command, UIKeyCommand *key) {
    (void)command;
    if (!g_active || !g_session || self != g_view) return;
    UIKeyModifierFlags flags = key.modifierFlags;
    int mods = ((flags & UIKeyModifierControl) ? 1 : 0) | ((flags & UIKeyModifierAlternate) ? 2 : 0)
        | ((flags & UIKeyModifierShift) ? 4 : 0);
    stream(self, finish_composition(self));
    gft_ios_terminal_ime_dispatch_key(4194309, mods);
}

static void gft_presses_began(id self, SEL command, NSSet<UIPress *> *presses, UIPressesEvent *event) {
    NSSet<UIPress *> *rest = presses;
    if (@available(iOS 13.4, *)) rest = route_presses(self, presses, YES);
    if (rest.count == 0) return;
    struct objc_super parent = {self, class_getSuperclass(g_class)};
    ((void (*)(struct objc_super *, SEL, NSSet *, UIPressesEvent *))objc_msgSendSuper)(&parent, command, rest, event);
}

static void gft_presses_ended(id self, SEL command, NSSet<UIPress *> *presses, UIPressesEvent *event) {
    NSSet<UIPress *> *rest = presses;
    if (@available(iOS 13.4, *)) rest = route_presses(self, presses, NO);
    if (rest.count == 0) return;
    struct objc_super parent = {self, class_getSuperclass(g_class)};
    ((void (*)(struct objc_super *, SEL, NSSet *, UIPressesEvent *))objc_msgSendSuper)(&parent, command, rest, event);
}

static BOOL install(void) {
    static BOOL installed;
    if (installed) return YES;
    Class cls = NSClassFromString(@"GDTKeyboardInputView");
    if (!cls) return NO;
    Method observe = class_getInstanceMethod(cls, @selector(observeTextChange:));
    Method become = class_getInstanceMethod(cls, @selector(becomeFirstResponderWithString:cursorStart:cursorEnd:));
    Method resign = class_getInstanceMethod(cls, @selector(resignFirstResponder));
    if (!observe || !become || !resign || ![cls instancesRespondToSelector:@selector(enterText:)]
        || ![cls instancesRespondToSelector:@selector(deleteText:)]) {
        fprintf(stderr, "[gft-ime] GDTKeyboardInputView changed; terminal composition handling is off\n");
        return NO;
    }
    // These overrides call the superclass; Godot's view must not define them.
    const char *presses = "v@:@@";
    if (!class_addMethod(cls, @selector(unmarkText), (IMP)gft_unmark, "v@:")) {
        fprintf(stderr, "[gft-ime] GDTKeyboardInputView handles unmarkText; terminal composition handling is off\n");
        return NO;
    }
    if (!class_addMethod(cls, @selector(keyCommands), (IMP)gft_key_commands, "@@:")
        || !class_addMethod(cls, @selector(gft_terminalReturn:), (IMP)gft_terminal_return, "v@:@")) {
        fprintf(stderr, "[gft-ime] GDTKeyboardInputView has key commands; modified Return stays a new line\n");
    }
    if (!class_addMethod(cls, @selector(textViewDidChangeSelection:), (IMP)gft_selection, "v@:@")) {
        fprintf(stderr, "[gft-ime] GDTKeyboardInputView tracks selection; the caret may drift\n");
    }
    g_pressed = [NSMutableSet set];
    if (!class_addMethod(cls, @selector(pressesBegan:withEvent:), (IMP)gft_presses_began, presses)
        || !class_addMethod(cls, @selector(pressesEnded:withEvent:), (IMP)gft_presses_ended, presses)
        || !class_addMethod(cls, @selector(pressesCancelled:withEvent:), (IMP)gft_presses_ended, presses)) {
        fprintf(stderr, "[gft-ime] GDTKeyboardInputView handles presses; hardware keys use Godot's path\n");
    }
    g_class = cls;
    original_observe = (void *)method_setImplementation(observe, (IMP)gft_observe);
    original_become = (void *)method_setImplementation(become, (IMP)gft_become);
    // Godot's view overrides resignFirstResponder, so this replaces its own.
    original_resign = (void *)method_setImplementation(resign, (IMP)gft_resign);
    installed = YES;
    return YES;
}

static NSInteger g_saved_inline;
static NSInteger g_saved_writing;

static void set_terminal_traits(UITextView *view, BOOL terminal) {
    if (terminal && !g_saved_traits) {
        g_saved_traits = @[@(view.autocapitalizationType), @(view.autocorrectionType), @(view.spellCheckingType),
                           @(view.smartQuotesType), @(view.smartDashesType), @(view.smartInsertDeleteType)];
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.spellCheckingType = UITextSpellCheckingTypeNo;
        // Smart quotes and dashes would rewrite shell commands.
        view.smartQuotesType = UITextSmartQuotesTypeNo;
        view.smartDashesType = UITextSmartDashesTypeNo;
        view.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        // Predictions are never shown for a terminal; loading their language
        // model is part of what iPadOS does on each input-language switch.
        if (@available(iOS 17.0, *)) {
            g_saved_inline = view.inlinePredictionType;
            view.inlinePredictionType = UITextInlinePredictionTypeNo;
        }
        if (@available(iOS 18.0, *)) {
            g_saved_writing = view.writingToolsBehavior;
            view.writingToolsBehavior = UIWritingToolsBehaviorNone;
        }
    } else if (!terminal && g_saved_traits) {
        view.autocapitalizationType = g_saved_traits[0].integerValue;
        view.autocorrectionType = g_saved_traits[1].integerValue;
        view.spellCheckingType = g_saved_traits[2].integerValue;
        view.smartQuotesType = g_saved_traits[3].integerValue;
        view.smartDashesType = g_saved_traits[4].integerValue;
        view.smartInsertDeleteType = g_saved_traits[5].integerValue;
        if (@available(iOS 17.0, *)) view.inlinePredictionType = g_saved_inline;
        if (@available(iOS 18.0, *)) view.writingToolsBehavior = g_saved_writing;
        g_saved_traits = nil;
    } else {
        return;
    }
    if (view.isFirstResponder) [view reloadInputViews];
}

// Returns the open composition as UTF-8 (caller frees it with free()), each
// erased character as U+0008. Nothing of it has been sent: the caller sends
// it ahead of whatever ends the composition.
char *gft_ios_terminal_ime_finish(void) {
    UITextView *view = g_view;
    if (!g_active || !view) return NULL;
    Edit edit = finish_composition(view);
    if (edit.backspaces == 0 && edit.text.length == 0) return NULL;
    NSString *erase = [@"" stringByPaddingToLength:(NSUInteger)edit.backspaces withString:@"\b" startingAtIndex:0];
    return strdup([erase stringByAppendingString:edit.text].UTF8String);
}

static void show_for_hardware_keyboard(UITextView *view) {
    if (!g_active || view.isFirstResponder || GCKeyboard.coalescedKeyboard == nil) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    g_auto_shown = [view becomeFirstResponderWithString:@"" cursorStart:0 cursorEnd:0];
}

// Called every frame by the terminal that owns input. Graffitty and Godot hide
// the keyboard on their own (opening a workspace, closing the keyboard), which
// releases the view; with a hardware keyboard, take it back, at most twice a
// second so a deliberate hide elsewhere cannot turn into a tug of war.
void gft_ios_terminal_ime_poll(void) {
    static NSTimeInterval last;
    UITextView *view = g_view;
    if (!g_active || !view || view.isFirstResponder || GCKeyboard.coalescedKeyboard == nil) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - last < 0.5) return;
    last = now;
    show_for_hardware_keyboard(view);
}

void gft_ios_terminal_ime_set(void *window_handle, bool active) {
    static id observer;
    if (!observer) {
        observer = [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil
                                                                   queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            UITextView *view = g_view;
            if (view) show_for_hardware_keyboard(view);
        }];
    }
    id<GFTTerminalKeyboardHost> controller = (__bridge id<GFTTerminalKeyboardHost>)window_handle;
    if (!active) {
        UITextView *view = g_view;
        BOOL ours = g_session;
        g_active = NO;
        g_session = NO;
        g_held = @"";
        g_sent = @"";
        set_preedit(@"", -1);
        if (!view) return;
        set_terminal_traits(view, NO);
        // Leave a view a LineEdit already filled; Godot diffs against it.
        if (ours && view.markedTextRange == nil) {
            g_handling++;
            view.text = @"";
            g_handling--;
            if ([view respondsToSelector:@selector(setPreviousText:)]) [view setPreviousText:@""];
            if ([view respondsToSelector:@selector(setPreviousSelectedRange:)]) [view setPreviousSelectedRange:NSMakeRange(0, 0)];
        }
        if (g_auto_shown && view.isFirstResponder) [view resignFirstResponder];
        g_auto_shown = NO;
        return;
    }
    if (![(id)controller respondsToSelector:@selector(keyboardView)]) return;
    UITextView *view = controller.keyboardView;
    if (!view || !install() || ![view isKindOfClass:g_class]) return;
    if (g_active && g_view == view) return;
    g_view = view;
    g_active = YES;
    g_held = @"";
    set_preedit(@"", -1);
    set_terminal_traits(view, YES);
    normalize(view);
    show_for_hardware_keyboard(view);
}

// Copies the preedit into `buffer` when it changed since `*generation`.
// Returns the required size (including NUL), or 0 when unchanged.
size_t gft_ios_terminal_ime_preedit(uint64_t *generation, char *buffer, size_t capacity, int32_t *caret) {
    if (*generation == g_preedit_generation) return 0;
    const char *text = g_preedit.UTF8String ?: "";
    size_t size = strlen(text) + 1;
    if (size > capacity) return size;
    memcpy(buffer, text, size);
    *caret = (int32_t)g_preedit_caret;
    *generation = g_preedit_generation;
    return size;
}
