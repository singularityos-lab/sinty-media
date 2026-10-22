const std = @import("std");
const c = @import("../c.zig").c;

fn eq(p: [*c]const c.GLubyte, s: []const u8) bool {
    if (p == null) return false;
    return std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(p))), s);
}

pub fn apply(ctx: *c.GstGLContext) void {
    const gl = &ctx.gl_vtable[0];
    const vendor = gl.GetString.?(c.GL_VENDOR);
    const renderer = gl.GetString.?(c.GL_RENDERER);
    if (eq(vendor, "Imagination Technologies") and eq(renderer, "PowerVR SGX 544MP")) {
        gl.GenVertexArrays = null;
        gl.DeleteVertexArrays = null;
        gl.BindVertexArray = null;
        gl.IsVertexArray = null;
    }
    if (eq(vendor, "ARM") and eq(renderer, "Mali-G52") and gl.CheckFramebufferStatus != null) {
        var fbo: c.GLint = 0;
        gl.GetIntegerv.?(c.GL_FRAMEBUFFER_BINDING, &fbo);
        if (fbo != 0) gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
        if (gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
            gl.GenQueries = null;
            gl.BeginQuery = null;
            gl.EndQuery = null;
            gl.QueryCounter = null;
            gl.DeleteQueries = null;
            gl.IsQuery = null;
            gl.GetQueryiv = null;
            gl.GetQueryObjectiv = null;
            gl.GetQueryObjectuiv = null;
            gl.GetQueryObjecti64v = null;
            gl.GetQueryObjectui64v = null;
        }
        if (fbo != 0) gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, @bitCast(fbo));
    }
}
