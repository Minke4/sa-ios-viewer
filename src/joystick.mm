#import "joystick.h"

@implementation SAJoystickView {
    UIView *_knob;
    CGPoint _center;
    CGFloat _radius;
    BOOL _tracking;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        self.layer.cornerRadius = frame.size.width * 0.5;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        self.userInteractionEnabled = YES;

        const CGFloat d = frame.size.width * 0.42;
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, d, d)];
        _knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        _knob.layer.cornerRadius = d * 0.5;
        [self addSubview:_knob];

        _radius = frame.size.width * 0.5;
        _center = CGPointMake(frame.size.width * 0.5, frame.size.height * 0.5);
        _knob.center = _center;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _radius = self.bounds.size.width * 0.5;
    _center = CGPointMake(self.bounds.size.width * 0.5, self.bounds.size.height * 0.5);
    if (!_tracking) {
        _knob.center = _center;
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _tracking = YES;
    [self moveTo:[touches.anyObject locationInView:self]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self moveTo:[touches.anyObject locationInView:self]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reset];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self reset];
}

- (void)moveTo:(CGPoint)p {
    CGFloat dx = p.x - _center.x;
    CGFloat dy = p.y - _center.y;
    const CGFloat len = sqrt(dx * dx + dy * dy);
    const CGFloat maxR = _radius * 0.62;
    if (len > maxR && len > 0.001) {
        dx = dx / len * maxR;
        dy = dy / len * maxR;
    }
    _knob.center = CGPointMake(_center.x + dx, _center.y + dy);
    _valueX = (float)(dx / maxR);
    _valueY = (float)(-dy / maxR);   // 屏幕 y 向下，取反
    if (self.onChange) self.onChange(_valueX, _valueY);
}

- (void)reset {
    _tracking = NO;
    _valueX = 0;
    _valueY = 0;
    [UIView animateWithDuration:0.12 animations:^{
        self->_knob.center = self->_center;
    }];
    if (self.onChange) self.onChange(0, 0);
}

@end
