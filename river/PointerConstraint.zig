// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2021 The River Developers
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

const build_options = @import("build_options");
const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const pixman = @import("pixman");

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Cursor = @import("Cursor.zig");
const Seat = @import("Seat.zig");
const View = @import("View.zig");

constraint: *wlr.PointerConstraintV1,
cursor: *Cursor,

destroy: wl.Listener(*wlr.PointerConstraintV1) = wl.Listener(*wlr.PointerConstraintV1).init(handleDestroy),
set_region: wl.Listener(void) = wl.Listener(void).init(handleSetRegion),

pub fn init(self: *Self, constraint: *wlr.PointerConstraintV1) void {
    const seat = @as(*Seat, @ptrFromInt(constraint.seat.data));
    self.* = .{
        .constraint = constraint,
        .cursor = &seat.cursor,
    };

    self.constraint.data = @intFromPtr(self);

    self.constraint.events.destroy.add(&self.destroy);
    self.constraint.events.set_region.add(&self.set_region);

    if (seat.focused == .view and seat.focused.view.surface == self.constraint.surface) {
        self.setAsActive();
    }
}

pub fn setAsActive(self: *Self) void {
    if (self.cursor.constraint == self.constraint) return;

    if (self.cursor.constraint) |constraint| {
        constraint.sendDeactivated();
    }

    self.cursor.constraint = self.constraint;

    // TODO: This is the same hack sway uses to deal with the fact that this
    // function may be called in response to a surface commit but before the
    // the wlroots pointer constraints implementation's commit handler has been called.
    // This logic is duplicated from that commit handler.
    if (self.constraint.current.region.notEmpty()) {
        _ = self.constraint.region.intersect(&self.constraint.surface.input_region, &self.constraint.current.region);
    } else {
        _ = self.constraint.region.copy(&self.constraint.surface.input_region);
    }

    self.constrainToRegion();

    self.constraint.sendActivated();
}

fn constrainToRegion(self: *Self) void {
    if (self.cursor.constraint != self.constraint) return;
    if (View.fromWlrSurface(self.constraint.surface)) |view| {
        const output = view.output;
        var output_box: wlr.Box = undefined;
        server.root.output_layout.getBox(output.wlr_output, &output_box);

        const surface_lx = @as(f64, @floatFromInt(output_box.x + view.current.box.x - view.surface_box.x));
        const surface_ly = @as(f64, @floatFromInt(output_box.y + view.current.box.y - view.surface_box.y));

        const sx = @as(c_int, @intFromFloat(self.cursor.wlr_cursor.x - surface_lx));
        const sy = @as(c_int, @intFromFloat(self.cursor.wlr_cursor.y - surface_ly));

        // If the cursor is not already inside the constraint region, warp
        // it to an arbitrary point inside the constraint region.
        if (!self.constraint.region.containsPoint(sx, sy, null)) {
            const rects = self.constraint.region.rectangles();
            if (rects.len > 0) {
                const new_lx = surface_lx + @as(f64, @floatFromInt(rects[0].x1 + rects[0].x2)) / 2;
                const new_ly = surface_ly + @as(f64, @floatFromInt(rects[0].y1 + rects[0].y2)) / 2;
                self.cursor.wlr_cursor.warpClosest(null, new_lx, new_ly);
            }
        }
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), _: *wlr.PointerConstraintV1) void {
    const self = @fieldParentPtr(Self, "destroy", listener);

    self.destroy.link.remove();
    self.set_region.link.remove();

    if (self.cursor.constraint == self.constraint) {
        warpToHint(self.cursor);

        self.cursor.constraint = null;
    }

    util.gpa.destroy(self);
}

fn handleSetRegion(listener: *wl.Listener(void)) void {
    const self = @fieldParentPtr(Self, "set_region", listener);
    self.constrainToRegion();
}

pub fn warpToHint(cursor: *Cursor) void {
    if (cursor.constraint) |constraint| {
        if (constraint.current.committed.cursor_hint) {
            if (View.fromWlrSurface(constraint.surface)) |view| {
                const output = view.output;
                var output_box: wlr.Box = undefined;
                server.root.output_layout.getBox(output.wlr_output, &output_box);

                const surface_lx = @as(f64, @floatFromInt(output_box.x + view.current.box.x - view.surface_box.x));
                const surface_ly = @as(f64, @floatFromInt(output_box.y + view.current.box.y - view.surface_box.y));

                _ = cursor.wlr_cursor.warp(
                    null,
                    surface_lx + constraint.current.cursor_hint.x,
                    surface_ly + constraint.current.cursor_hint.y,
                );
            }
        }
    }
}
