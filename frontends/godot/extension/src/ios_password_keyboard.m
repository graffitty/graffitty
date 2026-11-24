#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Godot 4.7 exposes its view controller as WINDOW_HANDLE and reuses this
// UITextView for every LineEdit. Restore its traits when the password loses focus.
@protocol GFTKeyboardHost
@property(readonly) UITextView *keyboardView;
@end

void gft_ios_password_focus(void *window_handle, bool focused) {
    id<GFTKeyboardHost> controller = (__bridge id<GFTKeyboardHost>)window_handle;
    if (![(id)controller respondsToSelector:@selector(keyboardView)]) return;
    UITextView *view = controller.keyboardView;
    if (!view) return;
    static char saved_traits;
    NSArray<NSNumber *> *saved = objc_getAssociatedObject(view, &saved_traits);
    if (focused && !saved) {
        objc_setAssociatedObject(view, &saved_traits, @[@(view.autocapitalizationType), @(view.autocorrectionType)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.autocapitalizationType = UITextAutocapitalizationTypeNone;
        view.autocorrectionType = UITextAutocorrectionTypeNo;
    } else if (!focused && saved) {
        view.autocapitalizationType = saved[0].integerValue;
        view.autocorrectionType = saved[1].integerValue;
        objc_setAssociatedObject(view, &saved_traits, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        return;
    }
    if (view.isFirstResponder) [view reloadInputViews];
}
