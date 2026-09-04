// SPDX-FileCopyrightText: Copyright (c) 2022 merryhime <https://mary.rs>
// SPDX-License-Identifier: MIT

// Applesauce: this is oaknut's code_block.hpp with an iOS fallback added. It
// replaces the copy inside HyperHLE's dynarmic checkout at build time; see
// platform/ios/scripts/patch-oaknut.sh for why it is a whole file rather than
// a commit, and why the touchHLE core's dynarmic must NOT get it.
//
// The fork this project builds against reaches JIT memory through a "JIT
// server": prepare_jit_region() below executes `brk #0xf00d`, a breakpoint an
// attached debugger is expected to recognise, service by mapping an executable
// region into this process, and answer by putting the address in x0. StikDebug
// does exactly that from its universal.js script, and on iOS 18.4 and newer it
// is the only route left -- the kernel no longer lets a merely debugged
// process map its own executable memory.
//
// TrollStore's "Enable JIT" is not that. It sets CS_DEBUGGED on the process
// and detaches, which is all iOS 15-17 needs and all it ever did. Nothing is
// then listening for the breakpoint, so `brk #0xf00d` is delivered as an
// unhandled SIGTRAP and the process dies -- at the instant a game starts,
// which is the only time dynarmic builds its code block. That is the whole of
// "the game closes the moment it starts" on a TrollStore install.
//
// So the breakpoint is now attempted under a temporary SIGTRAP handler. If a
// JIT server answers, nothing changes. If none does, the trap is survived and
// the classic mmap route is used instead, and if that is not permitted either
// the constructor throws rather than taking the process down with it.

#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <new>

#if defined(_WIN32)
#    define NOMINMAX
#    include <windows.h>
#elif defined(__APPLE__)
#    include <TargetConditionals.h>
#    include <libkern/OSCacheControl.h>
#    include <mach/mach.h>
#    include <mach/vm_map.h>
#    include <pthread.h>
#    include <setjmp.h>
#    include <signal.h>
#    include <sys/mman.h>
#    include <unistd.h>
#else
#    include <sys/mman.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
// A stable syscall wrapper in libSystem, but not declared in the iOS SDK.
extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, std::size_t usersize);
#endif

namespace oaknut {

#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
namespace detail {

struct ReusableJitRegion {
    std::uint32_t* memory = nullptr;
    std::uint32_t* writable_memory = nullptr;
    std::size_t size = 0;
    bool in_use = false;
};

inline ReusableJitRegion& reusable_jit_region()
{
    static ReusableJitRegion region;
    return region;
}

__attribute__((noinline, optnone, naked)) static void* prepare_jit_region(void*, std::size_t)
{
    __asm__ volatile(
        "mov x16, #1\n"
        "brk #0xf00d\n"
        "ret\n");
}

__attribute__((noinline, optnone, naked)) static void detach_jit_server()
{
    __asm__ volatile(
        "mov x16, #0\n"
        "brk #0xf00d\n"
        "ret\n");
}

// Where the SIGTRAP handler returns to when no JIT server answered the
// breakpoint. Accessors rather than namespace-scope variables so every
// translation unit shares one copy and none warns about an unused one.
inline sigjmp_buf& jit_probe_landing_pad()
{
    static sigjmp_buf pad;
    return pad;
}

inline volatile sig_atomic_t& jit_probe_is_running()
{
    static volatile sig_atomic_t running = 0;
    return running;
}

inline void jit_probe_trap_handler(int signal_number)
{
    if (jit_probe_is_running()) {
        jit_probe_is_running() = 0;
        // Returning normally would resume at the breakpoint and trap again,
        // forever. Unwinding back to the sigsetjmp below is the way out.
        siglongjmp(jit_probe_landing_pad(), 1);
    }

    // Someone else's trap. Put the default back and let it happen, so this
    // never swallows a real debugger breakpoint.
    struct sigaction fallback = {};
    fallback.sa_handler = SIG_DFL;
    sigemptyset(&fallback.sa_mask);
    sigaction(signal_number, &fallback, nullptr);
    raise(signal_number);
}

// prepare_jit_region(), but survivable when nothing is listening. Returns
// nullptr instead of killing the process.
inline void* try_prepare_jit_region(std::size_t size)
{
    struct sigaction ours = {};
    struct sigaction previous = {};
    ours.sa_handler = jit_probe_trap_handler;
    sigemptyset(&ours.sa_mask);
    ours.sa_flags = 0;

    if (sigaction(SIGTRAP, &ours, &previous) != 0)
        return nullptr;

    // volatile: siglongjmp leaves the value of anything the compiler kept in a
    // register indeterminate.
    void* volatile region = nullptr;
    if (sigsetjmp(jit_probe_landing_pad(), 1) == 0) {
        jit_probe_is_running() = 1;
        region = prepare_jit_region(nullptr, size);
    }
    jit_probe_is_running() = 0;

    sigaction(SIGTRAP, &previous, nullptr);
    return region;
}

inline bool process_is_debugged()
{
    constexpr unsigned int cs_ops_status = 0;
    constexpr unsigned int cs_debugged = 0x10000000;

    unsigned int flags = 0;
    if (csops(getpid(), cs_ops_status, &flags, sizeof(flags)) != 0)
        return false;
    return (flags & cs_debugged) != 0;
}

// Whether the kernel took PROT_EXEC away again. This is a refutation, not a
// proof: if the region cannot be queried at all, nothing has been learned and
// CS_DEBUGGED stays the answer, so an unexpected Mach failure does not turn
// into a refusal to run.
inline bool region_lost_its_executable_bit(void* region)
{
    vm_address_t address = reinterpret_cast<vm_address_t>(region);
    vm_size_t region_size = 0;
    natural_t depth = 0;
    vm_region_submap_short_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_SHORT_INFO_COUNT_64;

    if (vm_region_recurse_64(mach_task_self(),
                             &address,
                             &region_size,
                             &depth,
                             reinterpret_cast<vm_region_recurse_info_t>(&info),
                             &count)
        != KERN_SUCCESS) {
        return false;
    }
    return (info.protection & VM_PROT_EXECUTE) == 0;
}

// The route iOS 15-17 has always used: a process carrying dynamic-codesigning,
// or one a debugger has flagged CS_DEBUGGED, may map its own executable
// memory. This is what TrollStore's "Enable JIT" and AltJIT set up.
inline void* map_jit_region_directly(std::size_t size)
{
    // MAP_JIT is granted by the dynamic-codesigning entitlement and by nothing
    // else on iOS, so a mapping that succeeds with it is proof in itself that
    // this process is allowed to run code it wrote.
    void* region = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (region != MAP_FAILED)
        return region;

    // Without it there is no such proof: per mmap(2) iOS does not fail this
    // call when JIT is off, it quietly drops PROT_EXEC and hands back a
    // writable mapping. Trusting that would move the crash from here to the
    // first instruction dynarmic emits, which is worse -- so ask the kernel
    // whether this process is debugged, and read the protection back after.
    if (!process_is_debugged())
        return nullptr;

    region = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (region == MAP_FAILED)
        return nullptr;

    if (region_lost_its_executable_bit(region)) {
        munmap(region, size);
        return nullptr;
    }
    return region;
}

}  // namespace detail
#endif

class CodeBlock {
public:
    explicit CodeBlock(std::size_t size)
        : m_size(size)
    {
#if defined(_WIN32)
        m_memory = (std::uint32_t*)VirtualAlloc(nullptr, size, MEM_COMMIT, PAGE_EXECUTE_READWRITE);
#elif defined(__APPLE__)
#    if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        auto& reusable_region = detail::reusable_jit_region();
        if (reusable_region.memory != nullptr) {
            if (reusable_region.in_use || reusable_region.size != size)
                throw std::bad_alloc{};

            m_memory = reusable_region.memory;
            m_wmemory = reusable_region.writable_memory;
            reusable_region.in_use = true;
        } else if ((m_memory = (std::uint32_t*)detail::try_prepare_jit_region(size)) != nullptr) {
            // A JIT server answered. It hands back an executable mapping that
            // is deliberately not writable, so pair it with a second mapping
            // of the same pages that is.
            std::fprintf(stderr, "oaknut: JIT memory came from a JIT server (StikDebug).\n");

            vm_prot_t current_protection;
            vm_prot_t maximum_protection;
            kern_return_t result = vm_remap(mach_task_self(),
                                            reinterpret_cast<vm_address_t*>(&m_wmemory),
                                            size,
                                            0,
                                            VM_FLAGS_ANYWHERE | VM_FLAGS_RANDOM_ADDR,
                                            mach_task_self(),
                                            reinterpret_cast<mach_vm_address_t>(m_memory),
                                            false,
                                            &current_protection,
                                            &maximum_protection,
                                            VM_INHERIT_NONE);
            if (result != KERN_SUCCESS ||
                vm_protect(mach_task_self(),
                           reinterpret_cast<vm_address_t>(m_wmemory),
                           size,
                           false,
                           VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
                munmap(m_memory, size);
                throw std::bad_alloc{};
            }

            reusable_region = {m_memory, m_wmemory, size, true};
            m_should_detach_jit_server = true;
        } else {
            // No JIT server. The mapping is writable and executable at once,
            // so one address serves as both.
            m_memory = (std::uint32_t*)detail::map_jit_region_directly(size);
            if (m_memory == nullptr) {
                std::fprintf(stderr,
                             "oaknut: no JIT server answered and this process may not map "
                             "executable memory.\n"
                             "        JIT is off. Enable it and start the game again.\n");
                throw std::bad_alloc{};
            }
            std::fprintf(stderr, "oaknut: JIT memory came from mmap (TrollStore or AltJIT).\n");

            m_wmemory = m_memory;
            // Recorded the same way, so the destructor's early return covers
            // it and the single mapping is not unmapped twice.
            reusable_region = {m_memory, m_wmemory, size, true};
        }
#    elif TARGET_OS_IPHONE
        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
#    else
        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
#    endif
#elif defined(__NetBSD__)
        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_MPROTECT(PROT_READ | PROT_WRITE | PROT_EXEC), MAP_ANON | MAP_PRIVATE, -1, 0);
#elif defined(__OpenBSD__)
        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
#else
        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
#endif

#if defined(_WIN32)
        if (m_memory == nullptr)
#elif defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        if (m_memory == nullptr || m_wmemory == nullptr)
#else
        if (m_memory == MAP_FAILED)
#endif
            throw std::bad_alloc{};

#if !(defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR)
        m_wmemory = m_memory;
#endif
    }

    ~CodeBlock()
    {
        if (m_memory == nullptr)
            return;

#if defined(_WIN32)
        VirtualFree((void*)m_memory, 0, MEM_RELEASE);
#else
#    if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        auto& reusable_region = detail::reusable_jit_region();
        if (reusable_region.memory == m_memory && reusable_region.writable_memory == m_wmemory) {
            reusable_region.in_use = false;
            return;
        }
        munmap(m_wmemory, m_size);
#    endif
        munmap(m_memory, m_size);
#endif
    }

    CodeBlock(const CodeBlock&) = delete;
    CodeBlock& operator=(const CodeBlock&) = delete;
    CodeBlock(CodeBlock&&) = delete;
    CodeBlock& operator=(CodeBlock&&) = delete;

    std::uint32_t* ptr() const
    {
        return m_memory;
    }

    std::uint32_t* wptr() const
    {
        return m_wmemory;
    }

    std::uint32_t* xptr() const
    {
        return m_memory;
    }

    void protect()
    {
#if defined(__APPLE__) && !TARGET_OS_IPHONE
        pthread_jit_write_protect_np(1);
#elif defined(__APPLE__) && TARGET_OS_IPHONE && TARGET_OS_SIMULATOR
        mprotect(m_memory, m_size, PROT_READ | PROT_EXEC);
#elif defined(__NetBSD__) || defined(__OpenBSD__)
        mprotect(m_memory, m_size, PROT_READ | PROT_EXEC);
#endif
    }

    void unprotect()
    {
#if defined(__APPLE__) && !TARGET_OS_IPHONE
        pthread_jit_write_protect_np(0);
#elif defined(__APPLE__) && TARGET_OS_IPHONE && TARGET_OS_SIMULATOR
        mprotect(m_memory, m_size, PROT_READ | PROT_WRITE);
#elif defined(__NetBSD__) || defined(__OpenBSD__)
        mprotect(m_memory, m_size, PROT_READ | PROT_WRITE);
#endif
    }

    void detach_jit_server()
    {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        // Only ever set when a JIT server actually answered; the mmap fallback
        // has no server to tell anything to.
        if (m_should_detach_jit_server) {
            m_should_detach_jit_server = false;
            detail::detach_jit_server();
        }
#endif
    }

    void invalidate(std::uint32_t* mem, std::size_t size)
    {
#if defined(__APPLE__)
        sys_icache_invalidate(mem, size);
#elif defined(_WIN32)
        FlushInstructionCache(GetCurrentProcess(), mem, size);
#else
        static std::size_t icache_line_size = 0x10000, dcache_line_size = 0x10000;

        std::uint64_t ctr;
        __asm__ volatile("mrs %0, ctr_el0"
                         : "=r"(ctr));

        const std::size_t isize = icache_line_size = std::min<std::size_t>(icache_line_size, 4 << ((ctr >> 0) & 0xf));
        const std::size_t dsize = dcache_line_size = std::min<std::size_t>(dcache_line_size, 4 << ((ctr >> 16) & 0xf));

        const std::uintptr_t end = (std::uintptr_t)mem + size;

        for (std::uintptr_t addr = ((std::uintptr_t)mem) & ~(dsize - 1); addr < end; addr += dsize) {
            __asm__ volatile("dc cvau, %0"
                             :
                             : "r"(addr)
                             : "memory");
        }
        __asm__ volatile("dsb ish\n"
                         :
                         :
                         : "memory");

        for (std::uintptr_t addr = ((std::uintptr_t)mem) & ~(isize - 1); addr < end; addr += isize) {
            __asm__ volatile("ic ivau, %0"
                             :
                             : "r"(addr)
                             : "memory");
        }
        __asm__ volatile("dsb ish\nisb\n"
                         :
                         :
                         : "memory");
#endif
    }

    void invalidate_all()
    {
        invalidate(m_memory, m_size);
    }

protected:
    std::uint32_t* m_memory = nullptr;
    std::uint32_t* m_wmemory = nullptr;
    std::size_t m_size = 0;
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    bool m_should_detach_jit_server = false;
#endif
};

}  // namespace oaknut
