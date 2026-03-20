const std = @import("std");

const zx = @import("../root.zig");
const ctxs = @import("../contexts.zig");
const server = @import("server/Server.zig");

pub const Event = ctxs.ServerEventContext;

// Legacy --- will be renamed
pub const SerilizableAppMeta = server.SerilizableAppMeta;
pub const ServerMeta = server.ServerMeta;

// Legacy -- may be kept
pub const Request = @import("core/Request.zig");
pub const Response = @import("core/Response.zig");
