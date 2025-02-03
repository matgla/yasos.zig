//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org|/licenses/>.
//

pub fn AtomicInterface(comptime ImplementationType: anytype) type {
    return struct {
        pub fn Atomic(comptime ValueType: anytype) type {
            return struct {
                const Self = @This();

                value: ValueType,

                pub fn create(value: ValueType) Self {
                    return Self{
                        .value = value,
                    };
                }

                pub fn load(self: Self) ValueType {
                    ImplementationType.lock(0);
                    defer ImplementationType.unlock(0);
                    return self.value;
                }

                pub fn store(self: *Self, new: ValueType) void {
                    ImplementationType.lock(0);
                    defer ImplementationType.unlock(0);
                    self.value = new;
                }

                pub fn increment(self: *Self) void {
                    ImplementationType.lock(0);
                    defer ImplementationType.unlock(0);
                    self.value += 1;
                }

                pub fn exchange(self: *Self, new: ValueType) ValueType {
                    var result = new;
                    ImplementationType.lock(0);
                    defer ImplementationType.unlock(0);
                    result = self.value;
                    self.value = new;
                    return result;
                }

                pub fn compare_exchange(self: *Self, expected: ValueType, new: ValueType) bool {
                    ImplementationType.lock(0);
                    defer ImplementationType.unlock(0);
                    if (self.value == expected) {
                        self.value = new;
                        return true;
                    }
                    // someone's modified in the time between
                    return false;
                }

                pub fn compare_not_equal_decrement(self: *Self, expected: ValueType) bool {
                    ImplementationType.lock(0);
                    defer ImplementationType.unlock(0);
                    if (self.value != expected) {
                        self.value -= 1;
                        return true;
                    }
                    return false;
                }
            };
        }
    };
}
