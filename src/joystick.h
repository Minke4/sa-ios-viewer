//
// joystick.h — 简单的触摸虚拟摇杆 + 视角拖拽
//
#import <UIKit/UIKit.h>

// 摇杆输出：x/y 范围 [-1,1]，y 向上为正
typedef void (^SAJoystickBlock)(float x, float y);

@interface SAJoystickView : UIView
@property (nonatomic, copy) SAJoystickBlock onChange;
@property (nonatomic, assign) float valueX;
@property (nonatomic, assign) float valueY;
@end
