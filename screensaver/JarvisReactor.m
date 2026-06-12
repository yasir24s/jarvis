// JARVIS arc-reactor screen saver — renders over the idle/lock screen (allowed by macOS).
#import <ScreenSaver/ScreenSaver.h>
#import <AppKit/AppKit.h>
#import <math.h>

@interface JarvisReactorView : ScreenSaverView
@end

@implementation JarvisReactorView {
    double _phase;
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1.0 / 30.0];
        _phase = 0.0;
    }
    return self;
}

- (void)animateOneFrame {
    _phase += 1.0;
    [self setNeedsDisplay:YES];
}

static NSColor *CYAN(CGFloat a) { return [NSColor colorWithCalibratedRed:0.37 green:0.86 blue:1.0 alpha:a]; }
static NSColor *GOLD(CGFloat a) { return [NSColor colorWithCalibratedRed:1.0 green:0.81 blue:0.42 alpha:a]; }

- (void)arc:(NSPoint)c r:(CGFloat)r from:(CGFloat)s to:(CGFloat)e w:(CGFloat)w c:(NSColor *)col {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p appendBezierPathWithArcWithCenter:c radius:r startAngle:s endAngle:e];
    [p setLineWidth:w];
    [col setStroke];
    [p stroke];
}

- (void)drawRect:(NSRect)rect {
    [[NSColor blackColor] setFill];
    NSRectFill(rect);

    NSRect b = [self bounds];
    NSPoint c = NSMakePoint(NSMidX(b), NSMidY(b));
    CGFloat unit = MIN(b.size.width, b.size.height);
    CGFloat R = unit * 0.12;
    double pulse = 1.0 + 0.07 * sin(_phase * 0.06);

    // soft radial core glow
    CGFloat cr = R * 2.0 * pulse;
    NSBezierPath *core = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - cr, c.y - cr, cr * 2, cr * 2)];
    NSGradient *glow = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithCalibratedRed:0.92 green:1.0 blue:1.0 alpha:1.0], 0.0,
        CYAN(0.95), 0.30,
        CYAN(0.45), 0.62,
        [NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0], 1.0, nil];
    [glow drawInBezierPath:core relativeCenterPosition:NSMakePoint(0, 0)];

    // bright center
    CGFloat dot = R * 0.55 * pulse;
    NSBezierPath *d = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - dot, c.y - dot, dot * 2, dot * 2)];
    [[NSColor colorWithCalibratedRed:0.96 green:1.0 blue:1.0 alpha:0.95] setFill];
    [d fill];

    double rot = _phase;
    [self arc:c r:R * 2.7 from:rot to:rot + 250 w:unit * 0.006 c:CYAN(1.0)];
    [self arc:c r:R * 2.25 from:-rot * 0.7 + 30 to:-rot * 0.7 + 300 w:unit * 0.005 c:GOLD(0.95)];
    [self arc:c r:R * 1.95 from:0 to:360 w:1.0 c:CYAN(0.22)];

    // rotating tick ring
    [CYAN(0.5) setStroke];
    CGFloat t1 = R * 2.85, t2 = R * 3.05;
    for (int i = 0; i < 60; i++) {
        double a = (i * 6.0 + _phase * 0.25) * M_PI / 180.0;
        NSBezierPath *t = [NSBezierPath bezierPath];
        [t moveToPoint:NSMakePoint(c.x + t1 * cos(a), c.y + t1 * sin(a))];
        [t lineToPoint:NSMakePoint(c.x + t2 * cos(a), c.y + t2 * sin(a))];
        [t setLineWidth:1.5];
        [t stroke];
    }

    // label
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName: ([NSFont fontWithName:@"HelveticaNeue-Medium" size:unit * 0.024]
                              ?: [NSFont systemFontOfSize:unit * 0.024]),
        NSForegroundColorAttributeName: CYAN(0.9),
        NSKernAttributeName: @(unit * 0.006),
        NSParagraphStyleAttributeName: ps,
    };
    [@"J.A.R.V.I.S" drawInRect:NSMakeRect(c.x - unit * 0.4, NSMinY(b) + unit * 0.11, unit * 0.8, unit * 0.06)
                withAttributes:attrs];
}

@end
