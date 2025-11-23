//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org|/licenses/>.
//

const std = @import("std");

fn type_to_spinlock_id(comptime T: anytype) u32 {
    const name = @typeName(T);
    var hash: u32 = 0;
    for (name) |c| {
        hash = hash * 31 + @as(u32, c);
    }
    return hash;
}

pub fn AtomicInterface(comptime ImplementationType: anytype) type {
    return struct {
        pub fn Atomic(comptime ValueType: anytype) type {
            return struct {
                const Self = @This();
                pub const spinlock_id = @mod(type_to_spinlock_id(ValueType), ImplementationType.number_of_spinlocks());
                value: ValueType,

                pub fn create(value: ValueType) Self {
                    return Self{
                        .value = value,
                    };
                }

                pub fn load(self: Self) ValueType {
                    ImplementationType.lock(spinlock_id);
                    defer ImplementationType.unlock(spinlock_id);
                    return self.value;
                }

                pub fn store(self: *Self, new: ValueType) bool {
                    if (!ImplementationType.lock(spinlock_id)) {
                        return false;
                    }
                    defer ImplementationType.unlock(spinlock_id);
                    self.value = new;
                    return true;
                }

                pub fn increment(self: *Self) bool {
                    if (!ImplementationType.lock(spinlock_id)) {
                        return false;
                    }
                    defer ImplementationType.unlock(spinlock_id);
                    self.value += 1;
                    return true;
                }

                pub fn exchange(self: *Self, new: ValueType) ValueType {
                    var result = new;
                    ImplementationType.lock(spinlock_id);
                    defer ImplementationType.unlock(spinlock_id);
                    result = self.value;
                    self.value = new;
                    return result;
                }

                pub fn compare_exchange(self: *Self, expected: ValueType, new: ValueType) bool {
                    ImplementationType.lock(spinlock_id);
                    defer ImplementationType.unlock(spinlock_id);
                    if (self.value == expected) {
                        self.value = new;
                        return true;
                    }
                    // someone's modified in the time between
                    return false;
                }

                pub fn compare_not_equal_decrement(self: *Self, expected: ValueType) bool {
                    if (!ImplementationType.lock(spinlock_id)) {
                        return false;
                    }
                    defer ImplementationType.unlock(spinlock_id);
                    if (self.value != expected) {
                        self.value -= 1;
                        return true;
                    }
                    return false;
                }
            };
        }

        comptime {
            if (Atomic(u32).spinlock_id == Atomic(u16).spinlock_id) {
                @compileError("Atomic types must use different spinlocks to improve performance");
            }
        }
    };
}
