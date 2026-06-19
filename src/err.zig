const std = @import("std");

pub const ZmuxError = error{
    OutOfMemory,
    InvalidColour,
    InvalidKey,
    InvalidConfig,
    InvalidCommand,
    GridFull,
    PaneNotFound,
    WindowNotFound,
    SessionNotFound,
    NoActiveSession,
    IpcError,
    TermError,
    ParseError,
};
