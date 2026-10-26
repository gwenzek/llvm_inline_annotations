noinline fn work(value: *volatile u32) void {
    value.* += 1;
}
pub fn main() void {
    var value: u32 = 0;
    work(&value);
}
