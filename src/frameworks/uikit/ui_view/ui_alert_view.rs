/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! `UIAlertView` — presented as an in-app dialog built from `UIView`s.
//!
//! This used to open a blocking SDL2 message box. That is wrong twice over.
//! Semantically, `-[UIAlertView show]` returns immediately on iOS and the alert
//! is dismissed later from a button tap, so blocking stops the guest's run loop
//! dead. Practically, SDL's iOS message box spins a nested `NSRunLoop` on the
//! very thread that drives the emulator, which re-enters the guest and kills the
//! process — Advena's "Receive 3,000 VENA POINTS for leaving your rating!"
//! prompt did exactly that. Building the dialog out of ordinary views keeps it
//! inside the emulator, where the compositor already draws and hit-tests it.

use super::ui_control::ui_button::UIButtonTypeCustom;
use super::ui_control::{UIControlEventTouchUpInside, UIControlStateNormal};
use crate::frameworks::core_graphics::cg_affine_transform::CGAffineTransform;
use crate::frameworks::core_graphics::{CGFloat, CGPoint, CGRect, CGSize};
use crate::frameworks::foundation::{ns_string, NSInteger, NSUInteger};
use crate::frameworks::uikit::ui_font::{UILineBreakModeWordWrap, UITextAlignmentCenter};
use crate::objc::{
    id, msg, msg_class, msg_super, nil, objc_classes, release, retain, ClassExports, HostObject,
    NSZonePtr, SEL,
};
use crate::Environment;

pub type UIAlertViewStyle = NSInteger;
pub const UIAlertViewStyleDefault: UIAlertViewStyle = 0;
pub const UIAlertViewStyleSecureTextInput: UIAlertViewStyle = 1;
pub const UIAlertViewStylePlainTextInput: UIAlertViewStyle = 2;
pub const UIAlertViewStyleLoginAndPasswordInput: UIAlertViewStyle = 3;

/// Padding around the dialog's contents, and between them.
const MARGIN: CGFloat = 12.0;
/// Gap between adjacent buttons.
const GAP: CGFloat = 8.0;
/// Height of one button. Matches the 44pt minimum touch target UIKit uses.
const BUTTON_HEIGHT: CGFloat = 44.0;
/// Widest the dialog is allowed to get. Real `UIAlertView` is 284pt wide on the
/// 320pt screens these games run at, so this keeps a familiar proportion.
const MAX_WIDTH: CGFloat = 280.0;

#[derive(Default)]
pub struct UIAlertViewHostObject {
    title: id,
    message: id,
    delegate: id,
    button_titles: id,
    cancel_button_index: NSInteger,
    visible: bool,
    alert_view_style: UIAlertViewStyle,
    tag: NSInteger,
    /// The view hierarchy put on the key window by `-show`, or `nil` when the
    /// alert isn't on screen. This is a retained reference, released on
    /// dismissal (see [dismiss_container]).
    container: id,
}
impl HostObject for UIAlertViewHostObject {}

fn rgba(env: &mut Environment, r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) -> id {
    msg_class![env; UIColor colorWithRed:r green:g blue:b alpha:a]
}

/// Create a centred white label `width` points wide, and report the height its
/// text needs. The caller positions it with `-setFrame:`.
fn make_label(
    env: &mut Environment,
    text: id,
    font_size: CGFloat,
    bold: bool,
    width: CGFloat,
) -> (id, CGFloat) {
    let font: id = if bold {
        msg_class![env; UIFont boldSystemFontOfSize:font_size]
    } else {
        msg_class![env; UIFont systemFontOfSize:font_size]
    };

    let frame = CGRect {
        origin: CGPoint { x: 0.0, y: 0.0 },
        size: CGSize {
            width,
            height: 0.0,
        },
    };
    let label: id = msg_class![env; UILabel alloc];
    let label: id = msg![env; label initWithFrame:frame];

    let white: id = msg_class![env; UIColor whiteColor];
    let clear: id = msg_class![env; UIColor clearColor];
    let unlimited_lines: NSInteger = 0;
    () = msg![env; label setFont:font];
    () = msg![env; label setTextColor:white];
    () = msg![env; label setBackgroundColor:clear];
    () = msg![env; label setNumberOfLines:unlimited_lines];
    () = msg![env; label setLineBreakMode:UILineBreakModeWordWrap];
    () = msg![env; label setTextAlignment:UITextAlignmentCenter];
    () = msg![env; label setText:text];

    // Measured after the text is set, since that is what determines the height.
    let constraint = CGSize {
        width,
        height: CGFloat::MAX,
    };
    let fitted: CGSize = msg![env; label sizeThatFits:constraint];
    let height = fitted.height;
    (label, height.max(0.0).ceil())
}

/// Create a button that reports `index` back to `alert` when tapped.
///
/// `-buttonWithType:` hands back an autoreleased button, so the caller must not
/// release it: `-addSubview:` takes the reference that keeps it alive.
fn make_button(
    env: &mut Environment,
    title: id,
    index: NSInteger,
    alert: id,
    action: SEL,
) -> id {
    let button: id = msg_class![env; UIButton buttonWithType:UIButtonTypeCustom];
    let white: id = msg_class![env; UIColor whiteColor];
    let background = rgba(env, 0.24, 0.26, 0.32, 1.0);
    () = msg![env; button setTitle:title forState:UIControlStateNormal];
    () = msg![env; button setTitleColor:white forState:UIControlStateNormal];
    () = msg![env; button setBackgroundColor:background];
    () = msg![env; button setTag:index];
    () = msg![env; button addTarget:alert
                             action:action
                   forControlEvents:UIControlEventTouchUpInside];
    button
}

/// Take down the on-screen dialog, if there is one.
fn dismiss_container(env: &mut Environment, this: id) {
    // Cleared in the host object first: `-removeFromSuperview` drops the
    // window's reference and the `release` below drops ours, after which the
    // pointer must not be read again.
    let container = std::mem::replace(
        &mut env.objc.borrow_mut::<UIAlertViewHostObject>(this).container,
        nil,
    );
    if container == nil {
        return;
    }
    () = msg![env; container removeFromSuperview];
    release(env, container);
}

/// Build the dialog and put it on the key window.
///
/// Returns `false` when there is no window to attach to, which tells `-show` to
/// dismiss the alert instead of leaving the guest waiting for a tap that can
/// never arrive.
fn present(env: &mut Environment, this: id) -> bool {
    let app: id = msg_class![env; UIApplication sharedApplication];
    if app == nil {
        return false;
    }
    let window: id = msg![env; app keyWindow];
    if window == nil {
        return false;
    }

    // `CGRect` is `#[repr(C, packed)]`, so its fields are copied into locals
    // before being used in arithmetic.
    let window_bounds: CGRect = msg![env; window bounds];
    let screen_width = window_bounds.size.width;
    let screen_height = window_bounds.size.height;
    if screen_width <= 0.0 || screen_height <= 0.0 {
        return false;
    }

    // A second `-show` without a dismissal in between would otherwise strand
    // the first dialog on the window forever.
    dismiss_container(env, this);

    let (title, message, buttons) = {
        let host = env.objc.borrow::<UIAlertViewHostObject>(this);
        (host.title, host.message, host.button_titles)
    };

    let panel_width = (screen_width - 2.0 * MARGIN).min(MAX_WIDTH);
    let text_width = panel_width - 2.0 * MARGIN;

    // The contents are measured before anything is positioned, because the
    // panel's height is whatever the wrapped text turned out to need.
    let mut content_height = MARGIN;
    let title_label = if title == nil {
        nil
    } else {
        let (label, height) = make_label(env, title, 17.0, true, text_width);
        let frame = CGRect {
            origin: CGPoint {
                x: MARGIN,
                y: content_height,
            },
            size: CGSize {
                width: text_width,
                height,
            },
        };
        () = msg![env; label setFrame:frame];
        content_height += height + MARGIN;
        label
    };
    let message_label = if message == nil {
        nil
    } else {
        let (label, height) = make_label(env, message, 14.0, false, text_width);
        let frame = CGRect {
            origin: CGPoint {
                x: MARGIN,
                y: content_height,
            },
            size: CGSize {
                width: text_width,
                height,
            },
        };
        () = msg![env; label setFrame:frame];
        content_height += height + MARGIN;
        label
    };

    // Two buttons sit side by side, as UIKit lays them out; any other count
    // gets a column, which is also what UIKit falls back to.
    let button_count: NSUInteger = msg![env; buttons count];
    let side_by_side = button_count == 2;
    let buttons_height = if button_count == 0 {
        0.0
    } else if side_by_side {
        BUTTON_HEIGHT
    } else {
        BUTTON_HEIGHT * (button_count as CGFloat) + GAP * ((button_count - 1) as CGFloat)
    };
    let panel_height = content_height + buttons_height + MARGIN;

    let container: id = msg_class![env; UIView alloc];
    let container_frame = CGRect {
        origin: CGPoint { x: 0.0, y: 0.0 },
        size: CGSize {
            width: screen_width,
            height: screen_height,
        },
    };
    let container: id = msg![env; container initWithFrame:container_frame];
    // The backdrop dims the game and, being a full-screen view, swallows the
    // touches that would otherwise reach it — which is what makes this modal.
    let dim = rgba(env, 0.0, 0.0, 0.0, 0.55);
    () = msg![env; container setBackgroundColor:dim];

    let panel: id = msg_class![env; UIView alloc];
    let panel_frame = CGRect {
        origin: CGPoint {
            x: ((screen_width - panel_width) / 2.0).round(),
            y: ((screen_height - panel_height) / 2.0).max(MARGIN).round(),
        },
        size: CGSize {
            width: panel_width,
            height: panel_height,
        },
    };
    let panel: id = msg![env; panel initWithFrame:panel_frame];
    let panel_background = rgba(env, 0.13, 0.14, 0.17, 0.98);
    let corner_radius: CGFloat = 10.0;
    () = msg![env; panel setBackgroundColor:panel_background];
    let panel_layer: id = msg![env; panel layer];
    () = msg![env; panel_layer setCornerRadius:corner_radius];
    () = msg![env; container addSubview:panel];

    // `-addSubview:` retains, so the `alloc` reference is handed over here.
    if title_label != nil {
        () = msg![env; panel addSubview:title_label];
        release(env, title_label);
    }
    if message_label != nil {
        () = msg![env; panel addSubview:message_label];
        release(env, message_label);
    }

    let action = env
        .objc
        .register_host_selector("touchHLEAlertButtonTapped:".to_string(), &mut env.mem);
    let usable_width = panel_width - 2.0 * MARGIN;
    let half_width = ((usable_width - GAP) / 2.0).floor();
    for i in 0..button_count {
        let button_title: id = msg![env; buttons objectAtIndex:i];
        let button = make_button(env, button_title, i as NSInteger, this, action);
        let frame = if side_by_side {
            CGRect {
                origin: CGPoint {
                    x: MARGIN + (half_width + GAP) * (i as CGFloat),
                    y: content_height,
                },
                size: CGSize {
                    width: half_width,
                    height: BUTTON_HEIGHT,
                },
            }
        } else {
            CGRect {
                origin: CGPoint {
                    x: MARGIN,
                    y: content_height + (BUTTON_HEIGHT + GAP) * (i as CGFloat),
                },
                size: CGSize {
                    width: usable_width,
                    height: BUTTON_HEIGHT,
                },
            }
        };
        () = msg![env; button setFrame:frame];
        () = msg![env; panel addSubview:button];
    }
    release(env, panel);

    () = msg![env; window addSubview:container];
    () = msg![env; window bringSubviewToFront:container];
    // Ours to keep: the window holds its own reference, and this one is what
    // lets `-dismissWithClickedButtonIndex:animated:` find the dialog again.
    env.objc.borrow_mut::<UIAlertViewHostObject>(this).container = container;
    true
}

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation UIAlertView: NSObject

+ (id)allocWithZone:(NSZonePtr)_zone {
    let host_object = Box::new(UIAlertViewHostObject {
        title:               nil,
        message:             nil,
        delegate:            nil,
        button_titles:       nil,
        cancel_button_index: -1,
        visible:             false,
        alert_view_style:    UIAlertViewStyleDefault,
        tag:                 0,
        container:           nil,
    });
    env.objc.alloc_object(this, host_object, &mut env.mem)
}

- (id)initWithTitle:(id)title
            message:(id)message
           delegate:(id)delegate
  cancelButtonTitle:(id)cancel_title
  otherButtonTitles:(id)other_titles {

    // ВАЖНО: Вызов базового инициализатора для корректной регистрации объекта
    let this: id = msg_super![env; this init];

    let buttons: id = msg_class![env; NSMutableArray new];
    retain(env, title);
    retain(env, message);
    {
        // ИСПРАВЛЕНИЕ: Добавлен `mut`, так как изменение полей `RefMut` требует
        // мутабельности переменной
        let host = env.objc.borrow_mut::<UIAlertViewHostObject>(this);
        host.title    = title;
        host.message  = message;
        host.delegate = delegate;
        host.button_titles = buttons;
    }
    if cancel_title != nil {
        let idx: NSUInteger = msg![env; buttons count];
        let _: () = msg![env; buttons addObject:cancel_title];
        env.objc.borrow_mut::<UIAlertViewHostObject>(this).cancel_button_index = idx as NSInteger;
    }
    if other_titles != nil {
        let _: () = msg![env; buttons addObject:other_titles];
    }
    let title_str = if title != nil { ns_string::to_rust_string(env, title).into_owned() } else { "(nil)".into() };
    let msg_str   = if message != nil { ns_string::to_rust_string(env, message).into_owned() } else { "(nil)".into() };
    log!("UIAlertView init title={:?} message={:?}", title_str, msg_str);
    this
}

- (())dealloc {
    // A deallocated alert must not leave its dialog on the window.
    dismiss_container(env, this);

    // ИСПРАВЛЕНИЕ: Блокируем `host` в узком scope, чтобы снять заимствование до
    // `release`
    let (title, message, buttons) = {
        let host = env.objc.borrow::<UIAlertViewHostObject>(this);
        (host.title, host.message, host.button_titles)
    };
    release(env, title);
    release(env, message);
    release(env, buttons);
    env.objc.dealloc_object(this, &mut env.mem)
}

- (id)title   { env.objc.borrow::<UIAlertViewHostObject>(this).title }
- (id)message { env.objc.borrow::<UIAlertViewHostObject>(this).message }
- (id)delegate { env.objc.borrow::<UIAlertViewHostObject>(this).delegate }
- (())setTitle:(id)title {
    let old = env.objc.borrow::<UIAlertViewHostObject>(this).title;
    release(env, old); retain(env, title);
    env.objc.borrow_mut::<UIAlertViewHostObject>(this).title = title;
}
- (())setMessage:(id)message {
    let old = env.objc.borrow::<UIAlertViewHostObject>(this).message;
    release(env, old); retain(env, message);
    env.objc.borrow_mut::<UIAlertViewHostObject>(this).message = message;
}
- (())setDelegate:(id)delegate {
    // Делегаты в UIKit не удерживаются!
    env.objc.borrow_mut::<UIAlertViewHostObject>(this).delegate = delegate;
}
- (NSInteger)tag { env.objc.borrow::<UIAlertViewHostObject>(this).tag }
- (())setTag:(NSInteger)tag { env.objc.borrow_mut::<UIAlertViewHostObject>(this).tag = tag; }
- (UIAlertViewStyle)alertViewStyle { env.objc.borrow::<UIAlertViewHostObject>(this).alert_view_style }
- (())setAlertViewStyle:(UIAlertViewStyle)style { env.objc.borrow_mut::<UIAlertViewHostObject>(this).alert_view_style = style; }
- (bool)isVisible { env.objc.borrow::<UIAlertViewHostObject>(this).visible }

- (NSInteger)addButtonWithTitle:(id)title {
    let buttons = env.objc.borrow::<UIAlertViewHostObject>(this).button_titles;
    let idx: NSUInteger = msg![env; buttons count];
    let _: () = msg![env; buttons addObject:title];
    idx as NSInteger
}
- (NSUInteger)numberOfButtons {
    let buttons = env.objc.borrow::<UIAlertViewHostObject>(this).button_titles;
    msg![env; buttons count]
}
- (id)buttonTitleAtIndex:(NSInteger)index {
    let buttons = env.objc.borrow::<UIAlertViewHostObject>(this).button_titles;
    let count: NSUInteger = msg![env; buttons count];
    if index < 0 || index as NSUInteger >= count { return nil; }
    msg![env; buttons objectAtIndex:(index as NSUInteger)]
}
- (NSInteger)cancelButtonIndex { env.objc.borrow::<UIAlertViewHostObject>(this).cancel_button_index }
- (())setCancelButtonIndex:(NSInteger)index { env.objc.borrow_mut::<UIAlertViewHostObject>(this).cancel_button_index = index; }
- (NSInteger)firstOtherButtonIndex {
    // ИСПРАВЛЕНИЕ: Скоуп не даст возникнуть ошибке заимствования на `msg![env;
    // ...]`
    let (buttons, cancel) = {
        let host = env.objc.borrow::<UIAlertViewHostObject>(this);
        (host.button_titles, host.cancel_button_index)
    };
    let count: NSUInteger = msg![env; buttons count];
    for i in 0..count { if i as NSInteger != cancel { return i as NSInteger; } }
    -1
}
- (id)textFieldAtIndex:(NSInteger)_index { nil }

// Real `UIAlertView` is a `UIView`, and the dialog this class puts on screen is
// made of views — but the alert object itself is not one of them, so it has no
// place in a view hierarchy. These stub the geometry selectors guest apps
// actually invoke on alert views, none of which affect what gets drawn.
- (())addSubview:(id)_view {
    log_dbg!("UIAlertView addSubview: ignored");
}
- (())removeFromSuperview {
    log_dbg!("UIAlertView removeFromSuperview: ignored");
}
- (())setHidden:(bool)_hidden {
    log_dbg!("UIAlertView setHidden: ignored");
}
- (CGRect)frame {
    CGRect { origin: CGPoint { x: 0.0, y: 0.0 }, size: CGSize { width: 0.0, height: 0.0 } }
}
- (())setFrame:(CGRect)_frame {
    log_dbg!("UIAlertView setFrame: ignored");
}

- (())setTransform:(CGAffineTransform)_transform {
    // The dialog is laid out and centred by `-show`, so a guest transform has
    // nothing to apply to.
    log_dbg!("UIAlertView setTransform: ignored");
}

- (id)viewWithTag:(NSInteger)tag {
    // Real UIAlertView would search subviews, but touchHLE doesn't manage
    // a subview hierarchy for alerts.  Return self if the tag matches,
    // otherwise nil (Apple semantics: receiver is searched first).
    let own_tag: NSInteger = msg![env; this tag];
    if own_tag == tag { return this; }
    nil
}

- (CGSize)sizeThatFits:(CGSize)size {
    // On iOS this reports the size the content wants. The dialog sizes itself
    // to the screen in `-show` and the alert object has no frame of its own, so
    // the requested size is passed straight back.
    size
}

- (())sizeToFit {
    // 1. Получаем текущий frame
    let frame: CGRect = msg![env; this frame];

    // 2. ВАЖНО: Выносим размер в отдельную переменную.
    // Макрос msg! не принимает "frame.size" как аргумент после двоеточия.
    let current_size = frame.size;

    // 3. Запрашиваем подходящий размер
    let new_size: CGSize = msg![env; this sizeThatFits:current_size];

    // 4. Формируем новый frame и применяем его
    let new_frame = CGRect { origin: frame.origin, size: new_size };
    let _: () = msg![env; this setFrame:new_frame];
}

- (())show {
    log!("UIAlertView show");
    env.objc.borrow_mut::<UIAlertViewHostObject>(this).visible = true;

    let (title, message, buttons, cancel_index) = {
        let h = env.objc.borrow::<UIAlertViewHostObject>(this);
        (h.title, h.message, h.button_titles, h.cancel_button_index)
    };

    // Used to decide whether the alert actually has anything to show.
    let raw_title: String = if title != nil {
        ns_string::to_rust_string(env, title).into_owned()
    } else { String::new() };
    let raw_message: String = if message != nil {
        ns_string::to_rust_string(env, message).into_owned()
    } else { String::new() };
    let has_content = !(raw_title.trim().is_empty() && raw_message.trim().is_empty());

    // UIKit always gives an alert at least one way out; without this a guest
    // that forgot its buttons would put up a dialog nobody can dismiss.
    let btn_count: NSUInteger = msg![env; buttons count];
    if btn_count == 0 {
        let ok = ns_string::get_static_str(env, "OK");
        let _: () = msg![env; buttons addObject:ok];
    }

    // Some apps (notably Outfit7 titles like Talking Angela) create a
    // content-less alert — empty/`nil` title *and* message — as a transient
    // placeholder they dismiss programmatically once background work finishes.
    // There is nothing to draw for one of those, so it is dismissed straight
    // away. The same path catches a missing key window, where there would be
    // nowhere to put the dialog and the guest would wait for a tap forever.
    if has_content && present(env, this) {
        return;
    }
    log!(
        "UIAlertView show: nothing to present (has_content={}); dismissing immediately",
        has_content
    );
    let dismiss_index = if cancel_index >= 0 { cancel_index } else { 0 };
    let _: () = msg![env; this dismissWithClickedButtonIndex:dismiss_index animated:false];
}

// Sent by the dialog's buttons; see [make_button]. Not part of UIKit's API —
// the name is deliberately unlike anything a guest would define.
- (())touchHLEAlertButtonTapped:(id)sender {
    let index: NSInteger = msg![env; sender tag];
    let _: () = msg![env; this dismissWithClickedButtonIndex:index animated:false];
}

- (())dismissWithClickedButtonIndex:(NSInteger)button_index animated:(bool)_animated {
    env.objc.borrow_mut::<UIAlertViewHostObject>(this).visible = false;
    // Off the screen before the delegate hears about it: the callbacks below
    // routinely put up the *next* alert, and that one must not end up behind
    // this one.
    dismiss_container(env, this);
    let delegate = env.objc.borrow::<UIAlertViewHostObject>(this).delegate;

    // Честно проверяем, не был ли делегат удален (isa != 0)
    if delegate != nil {
        let isa: u32 = env.mem.read(delegate.cast());
        if isa != 0 {
            if let Some(sel) = env.objc.lookup_selector("alertView:clickedButtonAtIndex:") {
                let responds: bool = msg![env; delegate respondsToSelector:sel];
                if responds { let _: () = msg![env; delegate alertView:this clickedButtonAtIndex:button_index]; }
            }
            if let Some(sel) = env.objc.lookup_selector("alertView:willDismissWithButtonIndex:") {
                let responds: bool = msg![env; delegate respondsToSelector:sel];
                if responds { let _: () = msg![env; delegate alertView:this willDismissWithButtonIndex:button_index]; }
            }
            if let Some(sel) = env.objc.lookup_selector("alertView:didDismissWithButtonIndex:") {
                let responds: bool = msg![env; delegate respondsToSelector:sel];
                if responds { let _: () = msg![env; delegate alertView:this didDismissWithButtonIndex:button_index]; }
            }
        }
    }
}

- (id)description {
    let (title, visible) = { let h = env.objc.borrow::<UIAlertViewHostObject>(this); (h.title, h.visible) };
    let title_str = if title != nil { ns_string::to_rust_string(env, title).into_owned() } else { "(nil)".into() };
    let s = format!("<UIAlertView: {:?}; title={:?}; visible={}>", this, title_str, visible);
    let cstr = env.mem.alloc_and_write_cstr(s.as_bytes());
    msg_class![env; NSString stringWithUTF8String:cstr]
}

@end

};
