#include "cell_rt.h"

#include <string>
#include <vector>

// C++ helpers for Cell host: containers + probe used by the Zig CLI.

extern "C" int cell_cxx_probe(void) {
    std::vector<int> v{1, 2, 3};
    std::string s = "cell-cxx";
    return static_cast<int>(v.size() + s.size());
}

namespace cell {

template <typename T>
class Unique {
    T *ptr_;
public:
    explicit Unique(T *p = nullptr) : ptr_(p) {}
    ~Unique() { delete ptr_; }
    Unique(const Unique &) = delete;
    Unique &operator=(const Unique &) = delete;
    Unique(Unique &&o) noexcept : ptr_(o.ptr_) { o.ptr_ = nullptr; }
    T *get() const { return ptr_; }
    T *release() {
        T *p = ptr_;
        ptr_ = nullptr;
        return p;
    }
};

} // namespace cell
