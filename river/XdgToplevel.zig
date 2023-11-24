// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const std = @import("std");
const math = std.math;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Output = @import("Output.zig");
const Seat = @import("Seat.zig");
const Subsurface = @import("Subsurface.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");

const log = std.log.scoped(.xdg_shell);

/// The view this xdg toplevel implements
view: *View,

/// The corresponding wlroots object
xdg_toplevel: *wlr.XdgToplevel,

/// Set to true when the client acks the configure with serial View.pending_serial.
acked_pending_serial: bool = false,

// Listeners that are always active over the view's lifetime
destroy: wl.Listener(void) = wl.Listener(void).init(handleDestroy),
map: wl.Listener(void) = wl.Listener(void).init(handleMap),
unmap: wl.Listener(void) = wl.Listener(void).init(handleUnmap),
new_popup: wl.Listener(*wlr.XdgPopup) = wl.Listener(*wlr.XdgPopup).init(handleNewPopup),
new_subsurface: wl.Listener(*wlr.Subsurface) = wl.Listener(*wlr.Subsurface).init(handleNewSubsurface),

// Listeners that are only active while the view is mapped
ack_configure: wl.Listener(*wlr.XdgSurface.Configure) =
    wl.Listener(*wlr.XdgSurface.Configure).init(handleAckConfigure),
commit: wl.Listener(*wlr.Surface) = wl.Listener(*wlr.Surface).init(handleCommit),
request_fullscreen: wl.Listener(void) = wl.Listener(void).init(handleRequestFullscreen),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) =
    wl.Listener(*wlr.XdgToplevel.event.Move).init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) =
    wl.Listener(*wlr.XdgToplevel.event.Resize).init(handleRequestResize),
set_title: wl.Listener(void) = wl.Listener(void).init(handleSetTitle),
set_app_id: wl.Listener(void) = wl.Listener(void).init(handleSetAppId),

/// The View will add itself to the output's view stack on map
pub fn create(output: *Output, xdg_toplevel: *wlr.XdgToplevel) error{OutOfMemory}!void {
    const node = try util.gpa.create(ViewStack(View).Node);
    const view = &node.view;

    view.init(output, .{ .xdg_toplevel = .{
        .view = view,
        .xdg_toplevel = xdg_toplevel,
    } });

    const self = &node.view.impl.xdg_toplevel;
    xdg_toplevel.base.data = @intFromPtr(self);

    // Add listeners that are active over the view's entire lifetime
    xdg_toplevel.base.events.destroy.add(&self.destroy);
    xdg_toplevel.base.events.map.add(&self.map);
    xdg_toplevel.base.events.unmap.add(&self.unmap);
    xdg_toplevel.base.events.new_popup.add(&self.new_popup);
    xdg_toplevel.base.surface.events.new_subsurface.add(&self.new_subsurface);

    Subsurface.handleExisting(xdg_toplevel.base.surface, .{ .xdg_toplevel = self });
}

/// Returns true if a configure must be sent to ensure that the pending
/// dimensions are applied.
pub fn needsConfigure(self: Self) bool {
    const scheduled = &self.xdg_toplevel.scheduled;
    const state = &self.view.pending;

    // We avoid a special case for newly mapped views which we have not yet
    // configured by setting scheduled.width/height to the initial width/height
    // of the view in handleMap().
    return state.box.width != scheduled.width or state.box.height != scheduled.height;
}

/// Send a configure event, applying the pending state of the view.
pub fn configure(self: *Self) void {
    const state = &self.view.pending;
    self.view.pending_serial = self.xdg_toplevel.setSize(state.box.width, state.box.height);
    self.acked_pending_serial = false;
}

pub fn lastSetFullscreenState(self: Self) bool {
    return self.xdg_toplevel.scheduled.fullscreen;
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    self.xdg_toplevel.sendClose();
}

pub fn setActivated(self: Self, activated: bool) void {
    _ = self.xdg_toplevel.setActivated(activated);
}

pub fn setFullscreen(self: Self, fullscreen: bool) void {
    _ = self.xdg_toplevel.setFullscreen(fullscreen);
}

pub fn setResizing(self: Self, resizing: bool) void {
    _ = self.xdg_toplevel.setResizing(resizing);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*wlr.Surface {
    const view = self.view;
    return self.xdg_toplevel.base.surfaceAt(
        ox - @as(f64, @floatFromInt(view.current.box.x - view.surface_box.x)),
        oy - @as(f64, @floatFromInt(view.current.box.y - view.surface_box.y)),
        sx,
        sy,
    );
}

/// Return the current title of the toplevel if any.
pub fn getTitle(self: Self) ?[*:0]const u8 {
    return self.xdg_toplevel.title;
}

/// Return the current app_id of the toplevel if any .
pub fn getAppId(self: Self) ?[*:0]const u8 {
    return self.xdg_toplevel.app_id;
}

/// Return bounds on the dimensions of the toplevel.
pub fn getConstraints(self: Self) View.Constraints {
    const state = &self.xdg_toplevel.current;
    return .{
        .min_width = @max(state.min_width, 1),
        .max_width = if (state.max_width > 0) @as(u31, @intCast(state.max_width)) else math.maxInt(u31),
        .min_height = @max(state.min_height, 1),
        .max_height = if (state.max_height > 0) @as(u31, @intCast(state.max_height)) else math.maxInt(u31),
    };
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    // Remove listeners that are active for the entire lifetime of the view
    self.destroy.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();
    self.new_popup.link.remove();
    self.new_subsurface.link.remove();

    Subsurface.destroySubsurfaces(self.xdg_toplevel.base.surface);
    XdgPopup.destroyPopups(self.xdg_toplevel.base);

    self.view.destroy();
}

fn handleMap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "map", listener);
    const view = self.view;

    // Add listeners that are only active while mapped
    self.xdg_toplevel.base.events.ack_configure.add(&self.ack_configure);
    self.xdg_toplevel.base.surface.events.commit.add(&self.commit);
    self.xdg_toplevel.events.request_fullscreen.add(&self.request_fullscreen);
    self.xdg_toplevel.events.request_move.add(&self.request_move);
    self.xdg_toplevel.events.request_resize.add(&self.request_resize);
    self.xdg_toplevel.events.set_title.add(&self.set_title);
    self.xdg_toplevel.events.set_app_id.add(&self.set_app_id);

    // Use the view's initial size centered on the output as the default
    // floating dimensions
    var initial_box: wlr.Box = undefined;
    self.xdg_toplevel.base.getGeometry(&initial_box);

    view.float_box = .{
        .x = @divTrunc(@max(0, view.output.usable_box.width - initial_box.width), 2),
        .y = @divTrunc(@max(0, view.output.usable_box.height - initial_box.height), 2),
        .width = initial_box.width,
        .height = initial_box.height,
    };

    // We initialize these to avoid special-casing newly mapped views in
    // the check preformed in needsConfigure().
    self.xdg_toplevel.scheduled.width = initial_box.width;
    self.xdg_toplevel.scheduled.height = initial_box.height;

    view.surface = self.xdg_toplevel.base.surface;
    view.surface_box = initial_box;

    // Also use the view's  "natural" size as the initial regular dimensions,
    // for the case that it does not get arranged by a lyaout.
    view.pending.box = view.float_box;

    const state = &self.xdg_toplevel.current;
    const has_fixed_size = state.min_width != 0 and state.min_height != 0 and
        (state.min_width == state.max_width or state.min_height == state.max_height);

    if (self.xdg_toplevel.parent != null or has_fixed_size) {
        // If the self.xdg_toplevel has a parent or has a fixed size make it float
        view.pending.float = true;
    } else if (server.config.shouldFloat(view)) {
        view.pending.float = true;
    }

    self.view.pending.fullscreen = self.xdg_toplevel.requested.fullscreen;

    // If the view has an app_id or title which is not configured to use client
    // side decorations, inform it that it is tiled.
    if (server.config.csdAllowed(view)) {
        view.draw_borders = false;
    } else {
        _ = self.xdg_toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });
    }

    view.map() catch {
        log.err("out of memory", .{});
        self.xdg_toplevel.resource.getClient().postNoMemory();
    };
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "unmap", listener);

    // Remove listeners that are only active while mapped
    self.ack_configure.link.remove();
    self.commit.link.remove();
    self.request_fullscreen.link.remove();
    self.request_move.link.remove();
    self.request_resize.link.remove();
    self.set_title.link.remove();
    self.set_app_id.link.remove();

    self.view.unmap();
}

fn handleAckConfigure(
    listener: *wl.Listener(*wlr.XdgSurface.Configure),
    acked_configure: *wlr.XdgSurface.Configure,
) void {
    const self = @fieldParentPtr(Self, "ack_configure", listener);
    if (self.view.pending_serial) |serial| {
        if (serial == acked_configure.serial) {
            self.acked_pending_serial = true;
        }
    }
}

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self = @fieldParentPtr(Self, "commit", listener);
    const view = self.view;

    var new_box: wlr.Box = undefined;
    self.xdg_toplevel.base.getGeometry(&new_box);

    // If we have sent a configure changing the size
    if (view.pending_serial != null) {
        // Update the stored dimensions of the surface
        view.surface_box = new_box;

        if (self.acked_pending_serial) {
            // If this commit is in response to our configure and the
            // transaction code is tracking this configure, notify it.
            // Otherwise, apply the pending state immediately.
            view.pending_serial = null;
            if (view.shouldTrackConfigure()) {
                server.root.notifyConfigured();
            } else {
                const self_tags_changed = view.pending.tags != view.current.tags;
                const urgent_tags_dirty = view.pending.urgent != view.current.urgent or
                    (view.pending.urgent and self_tags_changed);
                view.current = view.pending;
                if (self_tags_changed) view.output.sendViewTags();
                if (urgent_tags_dirty) view.output.sendUrgentTags();

                // This is necessary if this view was part of a transaction that didn't get completed
                // before some change occured that caused shouldTrackConfigure() to return false.
                view.dropSavedBuffers();

                view.output.damage.?.addWhole();
                server.input_manager.updateCursorState();
            }
        } else {
            // If the client has not yet acked our configure, we need to send a
            // frame done event so that it commits another buffer. These
            // buffers won't be rendered since we are still rendering our
            // stashed buffer from when the transaction started.
            view.sendFrameDone();
        }
    } else {
        view.output.damage.?.addWhole();
        const size_changed = !std.meta.eql(view.surface_box, new_box);
        view.surface_box = new_box;
        // If the client has decided to resize itself and the view is floating,
        // then respect that resize.
        if ((self.view.pending.float or self.view.output.pending.layout == null) and size_changed) {
            view.pending.box.width = new_box.width;
            view.pending.box.height = new_box.height;
            view.applyPending();
        }
    }
}

fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), wlr_xdg_popup: *wlr.XdgPopup) void {
    const self = @fieldParentPtr(Self, "new_popup", listener);
    XdgPopup.create(wlr_xdg_popup, .{ .xdg_toplevel = self });
}

fn handleNewSubsurface(listener: *wl.Listener(*wlr.Subsurface), new_wlr_subsurface: *wlr.Subsurface) void {
    const self = @fieldParentPtr(Self, "new_subsurface", listener);
    Subsurface.create(new_wlr_subsurface, .{ .xdg_toplevel = self });
}

/// Called when the client asks to be fullscreened. We always honor the request
/// for now, perhaps it should be denied in some cases in the future.
fn handleRequestFullscreen(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "request_fullscreen", listener);
    if (self.view.pending.fullscreen != self.xdg_toplevel.requested.fullscreen) {
        self.view.pending.fullscreen = self.xdg_toplevel.requested.fullscreen;
        self.view.applyPending();
    }
}

/// Called when the client asks to be moved via the cursor, for example when the
/// user drags CSD titlebars.
fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const self = @fieldParentPtr(Self, "request_move", listener);
    const seat = @as(*Seat, @ptrFromInt(event.seat.seat.data));
    if ((self.view.pending.float or self.view.output.pending.layout == null) and !self.view.pending.fullscreen)
        seat.cursor.enterMode(.move, self.view);
}

/// Called when the client asks to be resized via the cursor.
fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
    const self = @fieldParentPtr(Self, "request_resize", listener);
    const seat = @as(*Seat, @ptrFromInt(event.seat.seat.data));
    if ((self.view.pending.float or self.view.output.pending.layout == null) and !self.view.pending.fullscreen)
        seat.cursor.enterMode(.resize, self.view);
}

/// Called when the client sets / updates its title
fn handleSetTitle(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_title", listener);
    self.view.notifyTitle();
}

/// Called when the client sets / updates its app_id
fn handleSetAppId(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_app_id", listener);
    self.view.notifyAppId();
}
