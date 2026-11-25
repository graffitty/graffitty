// Stock UIKit reference for the shared mobile page transition.
// See docs/developers/architecture/mobile-navigation.md for reproduction.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
@interface App : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property UINavigationController *nav;
@property UIView *fromView;
@property UIView *toView;
@property CADisplayLink *link;
@property double startTime;
@property NSString *direction;

@end
@implementation App
- (void)tick:(CADisplayLink *)link {
 double t=CACurrentMediaTime()-self.startTime;
 CALayer *f=self.fromView.layer.presentationLayer, *v=self.toView.layer.presentationLayer;
 CGPoint fp=[f convertPoint:CGPointZero toLayer:self.window.layer.presentationLayer];
 CGPoint tp=[v convertPoint:CGPointZero toLayer:self.window.layer.presentationLayer];
 NSLog(@"SAMPLE %@ %.9f %.9f %.9f %.9f",self.direction,t,fp.x,tp.x,self.window.bounds.size.width);
 if (t>0.55) { [self.link invalidate]; self.link=nil; }
}
- (void)sample:(NSString *)direction from:(UIView *)from to:(UIView *)to {
 self.fromView=from; self.toView=to; self.direction=direction; self.startTime=CACurrentMediaTime();
 self.link=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
 [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
 UIViewController *first=[UIViewController new]; first.view.backgroundColor=UIColor.blueColor; first.title=@"Servers";
 self.nav=[[UINavigationController alloc] initWithRootViewController:first];
 self.window.rootViewController=self.nav; [self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
  UIViewController *second=[UIViewController new]; second.view.backgroundColor=UIColor.greenColor; second.title=@"Workspace";
  [self.nav pushViewController:second animated:YES];
  [second.transitionCoordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) { [self sample:@"PUSH" from:first.view to:second.view]; } completion:nil];
  NSLog(@"PROBE PUSH coordinator duration=%.9f curve=%ld",second.transitionCoordinator.transitionDuration,(long)second.transitionCoordinator.completionCurve);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
   [self.nav popViewControllerAnimated:YES];
   [first.transitionCoordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) { [self sample:@"POP" from:second.view to:first.view]; } completion:nil];
   NSLog(@"PROBE POP coordinator duration=%.9f curve=%ld",first.transitionCoordinator.transitionDuration,(long)first.transitionCoordinator.completionCurve);
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ exit(0); });
  });
 }); return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(App.class)); } }
