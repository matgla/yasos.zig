const maps = @import("integer_hash_map");

export fn hash_fd(key: u16) u64 {
    return (maps.IntegerContext(u16){}).hash(key);
}

export fn hash_pid(key: i32) u64 {
    return (maps.IntegerContext(i32){}).hash(key);
}

export fn hash_address(key: usize) u64 {
    return (maps.IntegerContext(usize){}).hash(key);
}

export fn hash_wide(key: u64) u64 {
    return (maps.IntegerContext(u64){}).hash(key);
}
