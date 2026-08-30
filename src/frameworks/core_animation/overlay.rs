/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! Drawing the UIKit layer tree *on top of* a directly-presented `CAEAGLLayer`.
//!
//! # Why this exists
//!
//! On the iOS host, `-[EAGLContext presentRenderbuffer:]` takes over the
//! screen for any `CAEAGLLayer` (see the `ios_es1_direct_present` /
//! `ios_es2_direct_present` options) and calls
//! [super::set_direct_present_active], which permanently disables
//! [super::recomposite_if_necessary]. That is necessary — SDL2 on iOS attaches
//! one GL view per GL context, so compositing in the *internal* context would
//! steal the window from the app's context and make the screen flicker.
//!
//! The side effect is that everything Core Animation would have drawn is never
//! drawn at all. Games that mix a GL world with ordinary UIKit chrome (Gamevil's
//! Zenonia 3 builds its splash logo, its title menu and several in-game buttons
//! out of nibs and `UIButton`s) end up with invisible-but-still-tappable UI:
//! hit-testing goes through `UIView`, which doesn't care whether anything was
//! rendered.
//!
//! # How it works
//!
//! Instead of switching GL contexts, we composite the layer tree in the *guest's*
//! context, from inside `present_renderbuffer`, right after the guest's frame has
//! been drawn to the drawable framebuffer:
//!
//! 1. [collect] walks the layer tree while `Environment` is still available and
//!    produces a flat, self-contained draw list ([Scene]).
//! 2. [draw] renders that list into an offscreen RGBA texture (transparent
//!    where nothing was drawn) and leaves it bound to `GL_TEXTURE_2D` for the
//!    caller to blend over the guest frame with
//!    [crate::gles::present::present_frame_overlay].
//!
//! The split exists because making a GL context current mutably borrows
//! `env.objc` and `env.window`, so no `Environment` access is possible during
//! the GL phase.
//!
//! # Known limitations
//!
//! * UIKit content is always drawn *over* the guest frame, whatever the real
//!   z-order in the layer tree is. In practice apps put their GL view at the
//!   bottom, which is what this assumes.
//! * `cornerRadius` and pattern backgrounds are drawn as plain rectangles
//!   (the rounded-corner 9-patch lives in the other compositor's GL objects,
//!   which belong to the internal context).
//! * Only the fixed-function (OpenGL ES 1.1) present path is covered; the ES 2
//!   presenter returns before we get a chance to run.
#![allow(clippy::zero_ptr)] // alas, as you know, opengl

use super::animation;
use super::ca_layer::CALayerHostObject;
use crate::frameworks::core_graphics::cg_color::CGColorHostObject;
use crate::frameworks::core_graphics::{cg_bitmap_context, cg_image, CGFloat, CGRect};
use crate::gles::gles11_raw as gles11; // constants only
use crate::gles::gles11_raw::types::*;
use crate::gles::GLES;
use crate::matrix::Matrix;
use crate::objc::{id, msg, msg_class, nil, Class};
use crate::Environment;
use std::collections::{HashMap, HashSet};

/// Vertex positions of a unit square in layer co-ordinates, ordered so that
/// `GL_TRIANGLE_STRIP` produces the same two triangles as the other
/// compositor's `SQUARE_INDICES` (`[0, 1, 2, 2, 1, 3]`).
const SQUARE_POINTS: [f32; 8] = [0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0];
/// Texture co-ordinates for content stored top-to-bottom (`CGImage`).
const BASIC_TEX_COORDS: [f32; 8] = SQUARE_POINTS;
/// Texture co-ordinates for content stored bottom-to-top (`CGBitmapContext`
/// backing stores and presented renderbuffer pixels).
const FLIPPED_TEX_COORDS: [f32; 8] = [0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0];

/// Persistent host state for the overlay compositor.
///
/// Lives in [super::State] so it survives between frames, and is
/// [std::mem::take]n out of it for the duration of the GL phase (during which
/// `Environment` is unavailable).
#[derive(Default)]
pub struct State {
    /// Offscreen render target the layer tree is composited into, and its
    /// current size in pixels.
    target: Option<(GLuint, GLuint, u32, u32)>,
    /// Per-layer content textures, keyed by layer, along with the
    /// [CALayerHostObject::content_epoch] the texture was uploaded at.
    ///
    /// Keeping these here rather than on the layer means the GL phase can
    /// create and update them without needing to write anything back to
    /// `Environment` afterwards. A layer that is deallocated leaks its entry
    /// (as the other compositor's `gles_texture` does); if its address is
    /// later reused, the epoch check makes the new layer re-upload into the
    /// recycled texture, which is harmless.
    textures: HashMap<id, (GLuint, u64)>,
}

/// Where a layer's content pixels came from, which decides whether the rows
/// need flipping.
#[derive(Copy, Clone, PartialEq)]
enum ContentSource {
    /// `contents` (a `CGImage`), stored top-to-bottom.
    Image,
    /// A `CGBitmapContext` backing store or presented renderbuffer pixels,
    /// stored bottom-to-top.
    Flipped,
}

/// One layer's contribution to the overlay, in a form that needs no
/// `Environment` access.
struct Quad {
    /// The layer this came from, used as the content texture cache key.
    layer: id,
    /// Maps the unit square onto the layer's rectangle in screen space.
    modelview: Matrix<4>,
    /// Premultiplied background colour, if the layer has one.
    background: Option<[f32; 4]>,
    /// Content texture, if the layer has any content.
    content: Option<Content>,
}

struct Content {
    source: ContentSource,
    /// Effective opacity, applied via `glColor4f` with a `GL_MODULATE` texture
    /// environment.
    opacity: f32,
    /// Fresh pixels to upload, present only when the cached texture is stale.
    /// RGBA8, with width and height.
    pixels: Option<(Vec<u8>, u32, u32)>,
    /// The epoch these pixels correspond to, recorded in the cache after
    /// uploading.
    epoch: u64,
}

/// A complete overlay frame: a flat back-to-front draw list plus the geometry
/// needed to render and present it.
pub struct Scene {
    quads: Vec<Quad>,
    /// `UIScreen` bounds, the co-ordinate space the draw list is in.
    screen_size: (f32, f32),
    /// Size of the offscreen render target in pixels.
    fb_size: (u32, u32),
    /// Host window viewport to blit the finished overlay into.
    pub viewport: (u32, u32, u32, u32),
    /// Device rotation to apply when blitting.
    pub rotation: Matrix<2>,
}

/// Whether the overlay compositor is enabled at all.
///
/// It only makes sense on the iOS host (everywhere else Core Animation
/// composition still runs), and `TOUCHHLE_DISABLE_UI_OVERLAY=1` turns it off
/// for A/B testing without a rebuild.
pub fn is_enabled() -> bool {
    if !cfg!(target_os = "ios") {
        return false;
    }
    if std::env::var_os("TOUCHHLE_DISABLE_UI_OVERLAY").is_some() {
        log_once!(
            "TOUCHHLE_DISABLE_UI_OVERLAY=1: not compositing UIKit content over the guest frame."
        );
        return false;
    }
    true
}

/// Walk the layer tree and build the draw list for one frame. Returns [None] if
/// there is nothing to draw, in which case the caller should skip the GL phase
/// entirely.
pub fn collect(env: &mut Environment) -> Option<Scene> {
    if env.window.is_none() {
        return None;
    }

    let windows = env.framework_state.uikit.ui_view.ui_window.windows.clone();
    let mut visible_windows = Vec::with_capacity(windows.len());
    for window in windows {
        let hidden: bool = msg![env; window isHidden];
        if !hidden {
            visible_windows.push(window);
        }
    }
    if visible_windows.is_empty() {
        return None;
    }

    let screen_bounds: CGRect = {
        let screen: id = msg_class![env; UIScreen mainScreen];
        msg![env; screen bounds]
    };
    if !(screen_bounds.size.width > 0.0) || !(screen_bounds.size.height > 0.0) {
        return None;
    }

    // Advance any UIImageView frame animations, then let layers that need it
    // redraw their bitmaps, exactly as the Core Animation compositor would.
    crate::frameworks::uikit::ui_view::ui_image_view::update_animations(env);
    let mut root_layers = Vec::with_capacity(visible_windows.len());
    for window in visible_windows {
        let layer: id = msg![env; window layer];
        super::composition::display_layers(env, layer);
        root_layers.push(layer);
    }

    // The guest frame is already on screen underneath us, so every CAEAGLLayer
    // — and every ancestor of one, i.e. the opaque UIWindow and root view that
    // would otherwise paint over it — must not draw its own background or
    // contents. Their sublayers are still drawn: that is exactly the UI we're
    // here for.
    let eagl_class: Class = msg_class![env; CAEAGLLayer class];
    let mut content_suppressed = HashSet::new();
    for &root in &root_layers {
        mark_eagl_chain(env, root, eagl_class, &mut content_suppressed);
    }

    let mut animation_state = animation::State::default();
    let mut quads = Vec::new();
    // Assumes the windows in the list are ordered back-to-front, as the Core
    // Animation compositor does.
    for root in root_layers {
        collect_layer(
            env,
            &mut animation_state,
            root,
            Matrix::<4>::identity(),
            1.0,
            &content_suppressed,
            &mut quads,
        );
    }
    animation_state.update_started_and_finished_animations(env);

    if quads.is_empty() {
        return None;
    }

    // The layer tree is in `UIScreen` bounds space, which is portrait even for
    // landscape apps (UIKit rotates the root view controller's view instead —
    // see `-[UIWindow addSubview:]`). Render at twice that so Retina-resolution
    // artwork isn't thrown away, unless the scale hack asks for more.
    let scale = env.options.scale_hack.get().max(2);
    let fb_size = (
        ((screen_bounds.size.width as u32) * scale).max(1),
        ((screen_bounds.size.height as u32) * scale).max(1),
    );

    // The rotation that turns portrait screen space into the display's
    // orientation. This is the matrix the Core Animation compositor passes to
    // `present_frame`, and deliberately *not* `present_renderbuffer`'s own
    // rotation, which is the identity on this path because the guest already
    // draws in the display's orientation.
    let rotation = match std::env::var("TOUCHHLE_UI_OVERLAY_ROTATION")
        .ok()
        .and_then(|degrees| degrees.trim().parse::<f32>().ok())
    {
        Some(degrees) => {
            log_once!(
                "TOUCHHLE_UI_OVERLAY_ROTATION is set: rotating the UIKit overlay by {}°.",
                degrees
            );
            Matrix::<2>::z_rotation(degrees.to_radians())
        }
        None => env.window().rotation_matrix(),
    };

    log_once!(
        "Compositing UIKit content over the directly-presented guest frame \
         ({} layer(s) in the first frame). Set TOUCHHLE_DISABLE_UI_OVERLAY=1 to turn this off, \
         or TOUCHHLE_UI_OVERLAY_ROTATION=<degrees> if it comes out rotated.",
        quads.len()
    );

    Some(Scene {
        quads,
        screen_size: (screen_bounds.size.width, screen_bounds.size.height),
        fb_size,
        viewport: env.window().viewport(),
        rotation,
    })
}

/// Record every layer that is a `CAEAGLLayer` or an ancestor of one. Returns
/// whether `layer`'s subtree (including itself) contains a `CAEAGLLayer`.
fn mark_eagl_chain(
    env: &mut Environment,
    layer: id,
    eagl_class: Class,
    out: &mut HashSet<id>,
) -> bool {
    let mut contains: bool = msg![env; layer isKindOfClass:eagl_class];
    let sublayers = env.objc.borrow::<CALayerHostObject>(layer).sublayers.clone();
    for sublayer in sublayers {
        if mark_eagl_chain(env, sublayer, eagl_class, out) {
            contains = true;
        }
    }
    if contains {
        out.insert(layer);
    }
    contains
}

/// The equivalent of the Core Animation compositor's `composite_layer_recursive`,
/// except it records what to draw instead of drawing it.
fn collect_layer(
    env: &mut Environment,
    animation_state: &mut animation::State,
    layer: id,
    cumulative_transform: Matrix<4>,
    opacity: CGFloat,
    content_suppressed: &HashSet<id>,
    out: &mut Vec<Quad>,
) {
    // Building a presentation layer clones the whole host object, which for a
    // CAEAGLLayer means copying a screen's worth of presented pixels. Only pay
    // that when the layer actually has animations to apply.
    let is_animated = {
        let host_obj = env.objc.borrow::<CALayerHostObject>(layer);
        !host_obj.animations.is_empty() || !host_obj.anonymous_animations.is_empty()
    };
    let (hidden, layer_opacity, bounds, transform, background_color) = if is_animated {
        let host_obj = animation_state.create_presentation_layer(env, layer);
        (
            host_obj.hidden,
            host_obj.opacity,
            host_obj.bounds,
            host_obj.superlayer_to_layer_transform(),
            host_obj.background_color.clone(),
        )
    } else {
        let host_obj = env.objc.borrow::<CALayerHostObject>(layer);
        (
            host_obj.hidden,
            host_obj.opacity,
            host_obj.bounds,
            host_obj.superlayer_to_layer_transform(),
            host_obj.background_color.clone(),
        )
    };

    if hidden {
        return;
    }

    let opacity = opacity * layer_opacity;

    // Update the transform to match this layer's co-ordinate space.
    let cumulative_transform =
        <Matrix<4> as From<_>>::from(transform).multiply(&cumulative_transform);

    if opacity > 0.0 && !content_suppressed.contains(&layer) {
        // Reposition and scale the unit square (see SQUARE_POINTS) so it will
        // have the right size in this layer's co-ordinate space.
        let modelview =
            Matrix::<4>::from(&Matrix::scale_2d(bounds.size.width, bounds.size.height))
                .multiply(&Matrix::translate_3d(bounds.origin.x, bounds.origin.y, 0.0))
                .multiply(&cumulative_transform);

        let background = background_color.map(|color| {
            let CGColorHostObject { r, g, b, a, .. } = color;
            [
                r * a * opacity,
                g * a * opacity,
                b * a * opacity,
                a * opacity,
            ]
        });

        let content = collect_content(env, layer, opacity);

        if background.is_some() || content.is_some() {
            out.push(Quad {
                layer,
                modelview,
                background,
                content,
            });
        }
    }

    // Sort sublayers by zPosition for correct back-to-front compositing, as
    // the Core Animation compositor does.
    let sorted_sublayers = {
        let mut sublayers = env.objc.borrow::<CALayerHostObject>(layer).sublayers.clone();
        sublayers.sort_by(|&a, &b| {
            let z_a = env.objc.borrow::<CALayerHostObject>(a).z_position;
            let z_b = env.objc.borrow::<CALayerHostObject>(b).z_position;
            z_a.partial_cmp(&z_b).unwrap_or(std::cmp::Ordering::Equal)
        });
        sublayers
    };
    for sublayer in sorted_sublayers {
        collect_layer(
            env,
            animation_state,
            sublayer,
            cumulative_transform,
            opacity,
            content_suppressed,
            out,
        );
    }
}

/// Work out what a layer's content texture should contain, extracting the
/// pixels only if the cached texture is out of date.
fn collect_content(env: &mut Environment, layer: id, opacity: f32) -> Option<Content> {
    let (source, epoch, contents, cg_context, opaque) = {
        let host_obj = env.objc.borrow::<CALayerHostObject>(layer);
        // Precedence matches the Core Animation compositor, where a `contents`
        // image is uploaded last and therefore wins.
        let source = if host_obj.contents != nil {
            ContentSource::Image
        } else if host_obj.cg_context.is_some() || host_obj.presented_pixels.is_some() {
            ContentSource::Flipped
        } else {
            return None;
        };
        (
            source,
            host_obj.content_epoch,
            host_obj.contents,
            host_obj.cg_context,
            host_obj.opaque,
        )
    };

    let cached_epoch = env
        .framework_state
        .core_animation
        .overlay
        .textures
        .get(&layer)
        .map(|&(_texture, epoch)| epoch);
    let pixels = if cached_epoch == Some(epoch) {
        None
    } else if source == ContentSource::Image {
        let image = cg_image::borrow_image(&env.objc, contents);
        let (width, height) = image.dimensions();
        Some((image.pixels().to_vec(), width, height))
    } else if let Some(cg_context) = cg_context {
        // Make sure this is in sync with the code in ca_layer.rs that sets up
        // the context!
        let (width, height, data) = cg_bitmap_context::get_data(&env.objc, cg_context);
        let size = width * height * 4;
        Some((env.mem.bytes_at(data.cast(), size).to_vec(), width, height))
    } else {
        let host_obj = env.objc.borrow::<CALayerHostObject>(layer);
        let (pixels, width, height) = host_obj.presented_pixels.as_ref().unwrap();
        let mut pixels = pixels.clone();
        // The pixels are always RGBA, but if the layer is opaque then the
        // alpha channel is meant to be ignored, and glTexImage2D() has no
        // option to ignore it.
        if opaque {
            let mut i = 3;
            while i < pixels.len() {
                pixels[i] = 255;
                i += 4;
            }
        }
        Some((pixels, *width, *height))
    };

    Some(Content {
        source,
        opacity,
        pixels,
        epoch,
    })
}

/// Render a [Scene] into the offscreen overlay texture and leave that texture
/// bound to `GL_TEXTURE_2D`, ready to be blended over the guest frame by
/// [crate::gles::present::present_frame_overlay].
///
/// Returns [false] if the render target couldn't be set up, in which case
/// nothing was drawn and the caller must not present an overlay.
///
/// # Safety
///
/// The context `gles` belongs to must be current. The caller is responsible for
/// saving and restoring the GL state this touches; `present_renderbuffer`
/// already does so for everything below except the framebuffer binding, which
/// it restores at the very end anyway.
pub unsafe fn draw(gles: &mut dyn GLES, state: &mut State, scene: &mut Scene) -> bool {
    let (fb_width, fb_height) = scene.fb_size;

    // (Re)create the render target if it's missing or the screen size changed.
    if let Some((_texture, _framebuffer, width, height)) = state.target {
        if (width, height) != (fb_width, fb_height) {
            let (texture, framebuffer, _, _) = state.target.take().unwrap();
            gles.DeleteFramebuffersOES(1, &framebuffer);
            gles.DeleteTextures(1, &texture);
        }
    }
    let (target_texture, target_framebuffer) = match state.target {
        Some((texture, framebuffer, _, _)) => (texture, framebuffer),
        None => {
            let mut texture = 0;
            let mut framebuffer = 0;
            gles.GenTextures(1, &mut texture);
            gles.BindTexture(gles11::TEXTURE_2D, texture);
            gles.TexImage2D(
                gles11::TEXTURE_2D,
                0,
                gles11::RGBA as _,
                fb_width as _,
                fb_height as _,
                0,
                gles11::RGBA,
                gles11::UNSIGNED_BYTE,
                std::ptr::null(),
            );
            set_texture_parameters(gles);
            gles.GenFramebuffersOES(1, &mut framebuffer);
            gles.BindFramebufferOES(gles11::FRAMEBUFFER_OES, framebuffer);
            gles.FramebufferTexture2DOES(
                gles11::FRAMEBUFFER_OES,
                gles11::COLOR_ATTACHMENT0_OES,
                gles11::TEXTURE_2D,
                texture,
                0,
            );
            let status = gles.CheckFramebufferStatusOES(gles11::FRAMEBUFFER_OES);
            while gles.GetError() != 0 {}
            if status != gles11::FRAMEBUFFER_COMPLETE_OES {
                log!(
                    "Warning: couldn't create the {}x{} UIKit overlay render target \
                     (framebuffer status {:#x}); UIKit content will stay invisible.",
                    fb_width,
                    fb_height,
                    status
                );
                gles.DeleteFramebuffersOES(1, &framebuffer);
                gles.DeleteTextures(1, &texture);
                return false;
            }
            state.target = Some((texture, framebuffer, fb_width, fb_height));
            (texture, framebuffer)
        }
    };

    gles.BindFramebufferOES(gles11::FRAMEBUFFER_OES, target_framebuffer);
    gles.Viewport(0, 0, fb_width as _, fb_height as _);
    // Transparent, so the guest frame shows through everywhere the UI doesn't
    // cover.
    gles.ClearColor(0.0, 0.0, 0.0, 0.0);
    gles.Clear(gles11::COLOR_BUFFER_BIT);

    gles.MatrixMode(gles11::PROJECTION);
    // Scale down screen space to normalized device co-ordinates, shift the
    // origin to be at the top-left rather than the center, and flip the Y axis
    // (OpenGL's points up, Core Animation's points down).
    load_matrix(
        gles,
        Matrix::from(&Matrix::scale_2d(
            2.0 / scene.screen_size.0,
            -2.0 / scene.screen_size.1,
        ))
        .multiply(&Matrix::translate_3d(-1.0, 1.0, 0.0)),
    );
    gles.MatrixMode(gles11::TEXTURE);
    gles.LoadIdentity();
    gles.MatrixMode(gles11::MODELVIEW);

    // `glColor4f` has to reach the fragment for per-layer opacity to work, so
    // the REPLACE mode `present_renderbuffer` set up isn't usable here. It puts
    // the mode back when it restores the rest of the state.
    let modulate = [gles11::MODULATE; 1];
    gles.TexEnviv(
        gles11::TEXTURE_ENV,
        gles11::TEXTURE_ENV_MODE,
        modulate.as_ptr().cast(),
    );

    gles.Enable(gles11::BLEND);
    gles.BlendFunc(gles11::ONE, gles11::ONE_MINUS_SRC_ALPHA);
    // Client-side arrays throughout: `present_renderbuffer` doesn't save the
    // element array buffer binding, so no indexed drawing here.
    gles.BindBuffer(gles11::ARRAY_BUFFER, 0);
    gles.EnableClientState(gles11::VERTEX_ARRAY);
    gles.VertexPointer(
        2,
        gles11::FLOAT,
        0,
        SQUARE_POINTS.as_ptr() as *const GLvoid,
    );

    for quad in scene.quads.iter_mut() {
        load_matrix(gles, quad.modelview);

        if let Some([r, g, b, a]) = quad.background {
            gles.Disable(gles11::TEXTURE_2D);
            gles.DisableClientState(gles11::TEXTURE_COORD_ARRAY);
            gles.Color4f(r, g, b, a);
            gles.DrawArrays(gles11::TRIANGLE_STRIP, 0, 4);
        }

        let Some(content) = quad.content.take() else {
            continue;
        };

        let cached = state.textures.get(&quad.layer).copied();
        let texture = match cached {
            Some((texture, _epoch)) => texture,
            None => {
                let mut texture = 0;
                gles.GenTextures(1, &mut texture);
                texture
            }
        };
        gles.BindTexture(gles11::TEXTURE_2D, texture);
        if let Some((pixels, width, height)) = content.pixels {
            gles.TexImage2D(
                gles11::TEXTURE_2D,
                0,
                gles11::RGBA as _,
                width as _,
                height as _,
                0,
                gles11::RGBA,
                gles11::UNSIGNED_BYTE,
                pixels.as_ptr() as *const _,
            );
            set_texture_parameters(gles);
            state
                .textures
                .insert(quad.layer, (texture, content.epoch));
        } else if cached.is_none() {
            // Shouldn't happen: no cache entry means `collect` extracts pixels.
            state
                .textures
                .insert(quad.layer, (texture, content.epoch));
        }

        let opacity = content.opacity;
        gles.Color4f(opacity, opacity, opacity, opacity);
        gles.Enable(gles11::TEXTURE_2D);
        gles.EnableClientState(gles11::TEXTURE_COORD_ARRAY);
        gles.TexCoordPointer(
            2,
            gles11::FLOAT,
            0,
            match content.source {
                ContentSource::Image => BASIC_TEX_COORDS.as_ptr() as *const GLvoid,
                ContentSource::Flipped => FLIPPED_TEX_COORDS.as_ptr() as *const GLvoid,
            },
        );
        gles.DrawArrays(gles11::TRIANGLE_STRIP, 0, 4);
    }

    // Hand the finished overlay to the caller, bound and ready to present.
    gles.Color4f(1.0, 1.0, 1.0, 1.0);
    gles.BindTexture(gles11::TEXTURE_2D, target_texture);
    true
}

unsafe fn set_texture_parameters(gles: &mut dyn GLES) {
    gles.TexParameteri(
        gles11::TEXTURE_2D,
        gles11::TEXTURE_MIN_FILTER,
        gles11::LINEAR as _,
    );
    gles.TexParameteri(
        gles11::TEXTURE_2D,
        gles11::TEXTURE_MAG_FILTER,
        gles11::LINEAR as _,
    );
    gles.TexParameteri(
        gles11::TEXTURE_2D,
        gles11::TEXTURE_WRAP_S,
        gles11::CLAMP_TO_EDGE as _,
    );
    gles.TexParameteri(
        gles11::TEXTURE_2D,
        gles11::TEXTURE_WRAP_T,
        gles11::CLAMP_TO_EDGE as _,
    );
}

unsafe fn load_matrix(gles: &mut dyn GLES, matrix: Matrix<4>) {
    gles.LoadMatrixf(matrix.columns().as_ptr() as *const _);
}
