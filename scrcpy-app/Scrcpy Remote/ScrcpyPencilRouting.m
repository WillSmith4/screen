#import "ScrcpyPencilRouting.h"
#import "Scrcpy_Remote-Swift.h"
#import <objc/runtime.h>

static char pencilHandlerKey;
typedef void (*TouchImplementation)(id, SEL, NSSet<UITouch *> *, UIEvent *);

@implementation ScrcpyPencilRouting
+ (void)load {
    Class cls = NSClassFromString(@"SDL_uikitview");
    if (!cls) { return; }
    NSArray<NSString *> *selectors = @[@"touchesBegan:withEvent:", @"touchesMoved:withEvent:",
                                       @"touchesEnded:withEvent:", @"touchesCancelled:withEvent:"];
    SEL cancelSelector = NSSelectorFromString(selectors[3]);
    TouchImplementation cancelOriginal = (TouchImplementation)class_getMethodImplementation(cls, cancelSelector);
    [selectors enumerateObjectsUsingBlock:^(NSString *name, NSUInteger phase, BOOL *stop) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) { return; }
        TouchImplementation original = (TouchImplementation)method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^(UIView *view, NSSet<UITouch *> *touches, UIEvent *event) {
            DrawingInputHandler *handler = objc_getAssociatedObject(view, &pencilHandlerKey);
            if (!handler) { original(view, selector, touches, event); return; }
            NSSet<UITouch *> *forwarded = [handler filterTouches:touches event:event phase:phase];
            NSSet<UITouch *> *cancelled = [handler takeCancelledFingers];
            if (cancelled.count) { cancelOriginal(view, cancelSelector, cancelled, event); }
            if (forwarded.count) { original(view, selector, forwarded, event); }
        });
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    }];
}

+ (void)attachToView:(UIView *)view {
    // The controller view is normally SDL_uikitview; search its children too
    // so this stays correct if SDL introduces a container view.
    Class cls = NSClassFromString(@"SDL_uikitview");
    if ([view isKindOfClass:cls]) {
        DrawingInputHandler *old = objc_getAssociatedObject(view, &pencilHandlerKey);
        [old invalidate];
        DrawingInputHandler *handler = [[DrawingInputHandler alloc] initWithView:view];
        objc_setAssociatedObject(view, &pencilHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        for (UIView *child in view.subviews) { [self attachToView:child]; }
    }
}
@end
