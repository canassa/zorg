//! Helpers for auto_inline.zig that live in a different file, to check that a
//! function has one address no matter which file takes it.

pub fn triple(x: u32) u32 {
    return x * 3;
}

pub fn tripleAddress() *const fn (u32) u32 {
    return &triple;
}

pub fn callTriple(x: u32) u32 {
    return triple(x) + 1;
}
