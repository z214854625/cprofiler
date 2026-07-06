# C 层 Lua 采样 Profiler 完整技术文档

> 基于 ProFi.lua v2.2 的 C 层改进实现，面向游戏服务器生产环境。
> 零 GC 压力、零 RNG 扰动、热更友好、协程全支持。

---

## 目录

1. [Lua RNG 基础](#1-lua-rng-基础)
2. [无入侵 Profiler 原理：Debug Hook 机制](#2-无入侵-profiler-原理debug-hook-机制)
3. [采样间隔评估：5000 合理吗](#3-采样间隔评估5000-合理吗)
4. [C 层采样钩子完整实现方案](#4-c-层采样钩子完整实现方案)
5. [RNG 扰动分析](#5-rng-扰动分析)
6. [协程支持优化：coroutine.wrap 纯 C 实现](#6-协程支持优化coroutinewrap-纯-c-实现)
7. [完整 C 代码：cprofiler.c](#7-完整-c-代码cprofilerc)
8. [热更框架集成：cprofiler_manager.lua](#8-热更框架集成cprofiler_managerlua)
9. [编译与使用指南](#9-编译与使用指南)
10. [与 ProFi.lua 的功能对齐](#10-与-profilua-的功能对齐)

---

## 1. Lua RNG 基础

### 什么是 Lua RNG

**RNG** = **Random Number Generator**（随机数生成器）。Lua 中的 RNG 指的就是通过 `math` 标准库提供的**伪随机数生成机制**。

关键点：Lua 本身没有自带的随机数算法，它直接调用底层 C 标准库的 `rand()` 函数。所以在不同平台上，Lua 的随机数质量和行为可能不同。

### 核心 API

| 函数 | 作用 |
|------|------|
| `math.randomseed(n)` | 设置随机数种子 |
| `math.random()` / `math.random(n)` / `math.random(m, n)` | 生成随机数 |

```lua
math.random()       -- 返回 [0, 1) 的浮点数
math.random(6)      -- 返回 [1, 6] 的整数
math.random(10, 20) -- 返回 [10, 20] 的整数
```

### 种子问题（最常踩的坑）

```lua
math.randomseed(os.time())   -- 用当前时间做种子
print(math.random(1, 100))
```

**问题**：`os.time()` 是秒级的，如果短时间内多次启动程序，种子几乎一样，产生的随机序列会非常相似。

**常见解决办法**——把时间数值反转，低位变高位：

```lua
local seed = os.time()
local reversed = tonumber(string.reverse(tostring(seed)))
math.randomseed(reversed)
math.random(); math.random(); math.random()  -- 丢弃前几个
```

### 底层算法

Lua 底层用的是 **LCG（线性同余法）**，这也是 C 标准库 `rand()` 使用的算法：

- **伪随机**：给定相同种子，序列完全可重现
- **可预测**：如果知道种子和算法常数，可以推算出后续所有"随机"数
- **周期有限**：序列到一定长度后会重复

### 在游戏服务器中的注意事项

1. **确定性需求**：如果战斗逻辑用 Lua RNG（暴击、掉落等），相同的种子 → 相同的结果序列。这既是优势（可复现 bug）也是风险（玩家可能逆向推算）。

2. **跨平台一致性**：Windows 和 Linux 的 C 库 `rand()` 实现不同，同样的种子在两个平台上序列不同。

3. **多协程安全**：`math.random` 是全局状态，多协程并发调用时没有锁保护，不会崩溃但序列不可预期。

4. **Lua 5.4+ 变化**：5.4 引入了独立的随机数生成器，`math.randomseed` 可以接收多个参数，且对种子做了更好的散列处理。

---

## 2. 无入侵 Profiler 原理：Debug Hook 机制

无入侵的关键在于 **Lua 虚拟机自带的调试钩子（Debug Hook）**，它允许你在不修改任何业务代码的前提下，从外部"旁路"观察函数执行。

### 核心 API

```lua
debug.sethook(hookFunction, mask, count)
```

| 参数 | 说明 |
|------|------|
| `hookFunction` | 钩子回调函数，事件触发时被调用 |
| `mask` | 事件掩码：`"c"`=call, `"r"`=return, `"l"`=line, `""`=仅count |
| `count` | 每多少条 VM 指令触发一次（仅 count 模式有效） |

### 两种模式对比

#### 精确模式（Precise Mode）—— 开发/测试用

**原理**：监听 `call` 和 `return` 事件，在 call 时记录时间戳，return 时计算差值累加。

```lua
debug.sethook( onDebugHook, 'cr', self.hookCount )  -- 监听 call + return
```

- **优点**：精确到每个函数的实际耗时和调用次数
- **缺点**：每次函数调用/返回都触发钩子 → **开销巨大**，生产环境不可用

#### 采样模式（Sampling Mode）—— 生产环境用 ✅

**原理**：不监听 call/return，而是每 N 条 VM 指令触发一次，在那一刻**快照当前调用栈**。命中次数越多 = CPU 占比越高。

```lua
debug.sethook( onSamplingHook, '', self.sampleInterval )  -- mask为空, 仅靠count触发
```

**为什么开销低？**
- 不是每次函数调用都触发，而是每 5000~10000 条指令才触发一次
- 每次触发只做 `debug.getinfo` + 字符串拼接 + 哈希查找，没有计时函数调用
- `debug.getinfo` 用 `'Sn'` 标志（只要 source + name），不获取函数对象等重信息

### 采样原理示意

```
VM 指令流: 指令1 → 指令2 → ... → 指令5000 → 📸 快照1: 栈=[funcA→funcB→funcC]
                                   指令5001 → ... → 指令10000 → 📸 快照2: 栈=[funcA→funcD]

聚合统计:
  funcA: 2次命中 (100%)
  funcB: 1次命中 (50%)
  funcC: 1次命中 (50%)
  funcD: 1次命中 (50%)
```

---

## 3. 采样间隔评估：5000 合理吗

### 单次采样的成本

每次采样钩子执行的工作：

| 步骤 | 操作 | 估算开销 |
|------|------|----------|
| 1 | `totalSamples + 1` | ~1ns |
| 2 | 循环 `debug.getinfo(level, 'Sn')` × 最多 20 层 | **~5-15μs**（主要开销） |
| 3 | 每层字符串拼接 key + `seen` 表查找 | ~0.5μs × 20 |
| 4 | 可能触发 `recordSample`（首次时创建表） | ~0.2μs |
| 5 | `table.concat` 拼 callStackKey + 聚合表查找 | ~1μs |

**单次采样总开销 ≈ 10~20μs（Lua版）**

> `debug.getinfo` 是最大开销项，它每次调用都会**创建一个新 table** 返回，20 层 = 20 次内存分配 + GC 压力。

### 不同间隔的 CPU 开销占比

假设 Lua/LuaJIT 单条 VM 指令约 ~20ns：

| 采样间隔 | 每 N 条指令的 Lua 执行时间 | 单次采样开销 | 采样开销占比 |
|----------|--------------------------|------------|------------|
| 1000 | ~20μs | ~15μs | **~75%** 🔴 不可接受 |
| 3000 | ~60μs | ~15μs | **~25%** 🟡 偏高 |
| 5000 | ~100μs | ~15μs | **~15%** 🟡 可接受 |
| 10000 | ~200μs | ~15μs | **~7.5%** 🟢 舒适 |
| 20000 | ~400μs | ~15μs | **~3.7%** 🟢 几乎无感 |
| 50000 | ~1ms | ~15μs | **~1.5%** 🟢 无感 |

### 游戏服务器的关键特性：脉冲式执行

游戏服务器的大部分时间在 C++ 事件循环中等待（网络 IO、定时器），Lua 代码只在事件触发时短暂爆发执行。这意味着：
- VM 指令不是匀速产生的，而是在脉冲期间密集产生
- `count` 是按 VM 指令数触发的，所以采样只会在 Lua 脉冲期间发生
- C++ 等待期间不会触发采样 → 没有浪费的采样

### 结论

**5000 在短时采集（~120秒）场景下是合理的，但不适合长时间常驻。**

| 场景 | 推荐间隔 | 理由 |
|------|---------|------|
| **本地开发/测试排查** | 1000~2000 | 开发机不在乎开销，需要高精度定位 |
| **生产短时采集（~120秒）** | **3000~5000** | 短时可接受 |
| **生产中等时长（5~10分钟）** | **8000~10000** | 降低长时间 GC 压力 |
| **生产常驻监控** | **20000~50000** | 几乎无感，够看宏观趋势 |

### 优化方向

1. **降低 maxStackDepth**：从 20 降到 10，开销直接减半
2. **用 C 扩展替代 debug.getinfo**：零 GC 压力，开销降到 ~2-3μs
3. **动态采样率**：CPU 低时用小间隔，CPU 高时自动放大间隔

---

## 4. C 层采样钩子完整实现方案

### 为什么需要 C 层实现

| 瓶颈 | 原因 | C 版如何解决 |
|------|------|-------------|
| `debug.getinfo` 每次创建 Lua table | 20 层栈 = 20 次内存分配 → GC 压力 | `lua_getstack` + `lua_getinfo` 写入**栈上 `lua_Debug` 结构体**，零分配 |
| 字符串拼接 key 在 Lua 中做 | 每次 `source..':'..name..':'..line` 产生临时字符串 | C 中用 `snprintf` 写入**预分配缓冲区** |
| 哈希表是 Lua table | 插入/查找走 Lua 元方法链 | C 中用**自定义开放寻址哈希表**，一次 `malloc` |
| 钩子函数本身是 Lua 函数 | 每次触发要经过 Lua 解释器调度 | C 函数直接被 VM 调用，无解释器开销 |

**综合效果**：单次采样从 ~15μs 降到 ~2-3μs，且**零 GC 压力**。

### 核心架构

```
┌─────────────────────────────────────────────────┐
│               C 层采样 Profiler 架构               │
├─────────────────────────────────────────────────┤
│  Lua 接口层 (luaopen_cprofiler)                   │
│    profiler.start(interval, depth)                │
│    profiler.stop()                                │
│    profiler.report() / profiler.save(path)        │
├─────────────────────────────────────────────────┤
│  C 钩子层                                         │
│    sampling_hook(L, ar)                           │
│      → lua_getstack 遍历调用栈                     │
│      → lua_getinfo "Sn" 写入 lua_Debug            │
│      → 自定义哈希表查找/插入                        │
│      → 命中计数 +1                                 │
├─────────────────────────────────────────────────┤
│  C 数据层                                         │
│    开放寻址哈希表 prof_entry_t entries[]           │
│    key: source:name:linedefined                   │
├─────────────────────────────────────────────────┤
│  C 输出层                                         │
│    按 samples 降序排序                             │
│    格式化输出: Lua table 或文件                    │
└─────────────────────────────────────────────────┘
```

### 关键设计决策

#### ① 为什么用开放寻址而不是链表法哈希

开放寻址法数据连续存放，cache-friendly。游戏服务器采样场景下，热点函数高度集中（通常前 20 个函数占 80%+ 采样），开放寻址的缓存友好性优势明显。

#### ② 为什么 `lua_getinfo` 只传 `"Sn"`

```c
// "S" → source, short_src, linedefined, lastlinedefined, what
// "n" → name, namewhat
//
// 不请求的字段：
// "f" → func: 会把函数对象压入 Lua 栈，增加 GC root
// "l" → currentline: 采样精度到函数级就够了
// "L" → activelines: 会创建一个 Lua table！绝对不要
```

#### ③ 为什么不在钩子中做排序

采样阶段只做"查找 + 计数"（O(1)），排序推迟到 report/save 时（一次性 qsort），不影响采样热路径。

---

## 5. RNG 扰动分析

### 直接结论

| | 是否扰动 RNG | 原因 |
|---|---|---|
| **C 版采样 profiler** | ❌ **不扰动** | 零 Lua 对象操作，不触发 GC，不调用 `math.random` |
| **Lua 版采样 profiler (ProFi.lua)** | ⚠️ **理论上有极低概率间接扰动** | `debug.getinfo` 创建临时 table → 可能触发 GC → 如果 `__gc` 终结器调用了 `math.random` 则会消耗 RNG 状态 |
| **精确模式 (call/return hook)** | ⚠️ **更严重** | 每次函数调用都触发，临时 table 产生量巨大 |

### 为什么不会直接扰动

RNG 状态与 VM 指令计数器是完全独立的：
- `debug.sethook(hook, '', count)` 的 count 机制是 VM 指令计数器递减，达到 0 时调用 hook
- `math.random()` 底层调用的是 C 的 `rand()`，其状态维护在 C 运行时的全局静态变量中
- **hook 函数的执行不消耗 RNG 状态** — 除非 hook 内部主动调用了 `math.random()`

ProFi.lua 的采样钩子代码中**没有任何 `math.random` 调用**，所以 RNG 状态不会被消耗。

### 唯一的间接扰动路径：GC → `__gc` 终结器 → `math.random`

```
采样钩子执行 → debug.getinfo 创建临时 table → 累积 → 触发 GC?
  → GC 遍历所有对象 → 有 __gc 终结器?
    → 调用 __gc 元方法 → __gc 内调用了 math.random?
      → 🔴 RNG 状态被消耗！后续 math.random 序列偏移
```

### C 版为什么没有这个问题

```c
// C 版采样钩子：零 Lua 对象分配
static void sampling_hook(lua_State *L, lua_Debug *ar) {
    lua_Debug info;              // 栈上结构体，不分配
    char key_buf[256];           // 栈上缓冲区，不分配
    for (int level = 1; level <= max_depth; level++) {
        lua_getstack(L, level, &info);  // 写入栈上结构体，不分配
        lua_getinfo(L, "Sn", &info);    // 填充已有结构体，不分配
        snprintf(key_buf, ...);         // 写入栈上缓冲区，不分配
        // 哈希表操作全在 C 层，不经过 Lua GC
    }
}
// → 全程零 Lua 对象创建 → 不触发 GC → 不可能间接触发 __gc → 不扰动 RNG
```

### 验证方法

```lua
-- 测试脚本：验证 profiler 对 RNG 序列的影响
math.randomseed(12345)
local baseline = {}
for i = 1, 1000 do baseline[i] = math.random(1, 10000) end

ProFi:startSampling(5000, 20)
math.randomseed(12345)
local with_profiler = {}
for i = 1, 1000 do with_profiler[i] = math.random(1, 10000) end
ProFi:stop()

local mismatch = 0
for i = 1, 1000 do
    if baseline[i] ~= with_profiler[i] then
        mismatch = mismatch + 1
    end
end

if mismatch == 0 then
    print("[RNG Test] ✅ PASS: profiler does NOT disturb RNG sequence")
else
    print(string.format("[RNG Test] ❌ FAIL: %d/%d mismatches", mismatch, 1000))
end
```

---

## 6. 协程支持优化：coroutine.wrap 纯 C 实现

### 旧方案 vs 新方案

**旧方案**（已废弃）：用 `luaL_dostring` 注入 Lua 代码替换 `coroutine.wrap`
- ❌ 依赖动态代码执行权限
- ❌ 某些服务器禁用 `luaL_dostring`

**新方案**（当前版本）：完全用 C 层 `luaL_ref` / `lua_rawgeti` / `lua_pushcclosure` 实现
- ✅ 纯 C API，不依赖动态代码执行
- ✅ 跨版本稳定

### 实现原理

`coroutine.wrap(f)` 的语义是：创建协程 → 返回一个函数，调用该函数等价于 `coroutine.resume(co, ...)`。

C 版拆成两个函数：

| C 函数 | 职责 | 对应 Lua 概念 |
|--------|------|--------------|
| `cp_wrapped_wrap` | 工厂函数：用原始 `create` 创建协程 + 挂钩，返回 C 闭包 | `coroutine.wrap(f)` |
| `cp_wrap_resume_fn` | 闭包实体：`lua_xmove` 移参数 + `lua_resume` + 移回返回值 | `coroutine.resume(co, ...)` |

### 关键代码片段

```c
/* wrap 的 resume 闭包函数, upvalue[1] = 协程 */
static int cp_wrap_resume_fn(lua_State *L) {
    lua_State *co = lua_tothread(L, lua_upvalueindex(1));
    int nargs = lua_gettop(L);
    if (nargs > 0) lua_xmove(L, co, nargs);        /* 参数: L → co */

#if LUA_VERSION_NUM >= 502
    int status = lua_resume(co, L, nargs);           /* 5.2+ 多一个 from 参数 */
#else
    int status = lua_resume(co, nargs);              /* 5.1 / LuaJIT */
#endif

    int nres = lua_gettop(co);
    if (nres > 0) lua_xmove(co, L, nres);           /* 返回值: co → L */

    if (status != LUA_OK && status != LUA_YIELD)
        return lua_error(L);
    return nres;
}

/* wrap 工厂: 用原始 create 建协程, 挂钩, 返回 C 闭包 */
static int cp_wrapped_wrap(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    lua_State *co = lua_tothread(L, -1);
    if (co && g_st.active)
        lua_sethook(co, cp_sampling_hook, 0, g_st.sample_interval);
    lua_pushcclosure(L, cp_wrap_resume_fn, 1);  /* co 作为 upvalue */
    return 1;
}

/* 恢复: 直接从 registry ref 取回原始函数 */
static void cp_unhook_coroutines(lua_State *L) {
    lua_getglobal(L, "coroutine");
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    lua_setfield(L, -2, "create");
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_wrap_ref);
    lua_setfield(L, -2, "wrap");
    lua_pop(L, 1);
    luaL_unref(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    luaL_unref(L, LUA_REGISTRYINDEX, g_st.co_wrap_ref);
    g_st.co_hooked = 0;
}
```

### 协程拦截/恢复完整流程

```
cp.start() → cp_hook_coroutines:
  1. getglobal("coroutine")
  2. getfield("create") → luaL_ref → co_create_ref
  3. getfield("wrap") → luaL_ref → co_wrap_ref
  4. setfield("create", cp_wrapped_create)
  5. setfield("wrap", cp_wrapped_wrap)

用户创建协程:
  coroutine.create(f) → cp_wrapped_create(L)
    → lua_rawgeti(co_create_ref) → 原始 create
    → lua_call → 创建协程 co
    → lua_sethook(co, hook, 0, interval)
    → 返回 co (已挂钩)

  coroutine.wrap(f) → cp_wrapped_wrap(L)
    → lua_rawgeti(co_create_ref) → 原始 create
    → lua_call → 创建协程 co
    → lua_sethook(co, hook, 0, interval)
    → lua_pushcclosure(cp_wrap_resume_fn, 1)
    → 返回 resume 闭包

用户调用 wrap 返回的函数:
  resume_fn(args...) → cp_wrap_resume_fn(L)
    → lua_xmove(L, co, nargs)
    → lua_resume(co, ...)
    → lua_xmove(co, L, nres)
    → 返回值

cp.stop() → cp_unhook_coroutines:
  1. lua_rawgeti(co_create_ref) → setfield("create", 原始 create)
  2. lua_rawgeti(co_wrap_ref) → setfield("wrap", 原始 wrap)
  3. luaL_unref(co_create_ref)
  4. luaL_unref(co_wrap_ref)
```

---

## 7. 完整 C 代码：cprofiler.c

> 以下为完整可编译的单文件 C 实现，功能对齐 ProFi.lua v2.2 采样模式，包含 flat 统计 + CallStack 聚合 + 协程支持（create + wrap 全 C 实现），零 Lua 对象分配。

```c
/* ==========================================================================
 * cprofiler.c — C 层 Lua 采样 Profiler（单文件，零 GC 压力）
 *
 * 功能对齐 ProFi.lua v2.2 采样模式：
 *   - flat 统计：按 source:name:line 聚合采样命中
 *   - CallStack 聚合：按完整调用栈形态聚合
 *   - 协程支持：C 层拦截 coroutine.create / coroutine.wrap
 *     原始函数用 luaL_ref 保存到 registry，恢复时 lua_rawgeti + setfield
 *     不使用 luaL_dostring，不依赖动态代码执行
 *
 * 编译:
 *   Linux:   gcc -O2 -shared -fPIC -o cprofiler.so cprofiler.c -I<lua_include> -llua
 *   macOS:   gcc -O2 -shared -fPIC -o cprofiler.so cprofiler.c -I<lua_include> -llua
 *   Windows: cl /O2 /LD cprofiler.c /I<lua_include> /link lua51.lib /OUT:cprofiler.dll
 *
 * 兼容 Lua 5.1 / LuaJIT / 5.2 / 5.3 / 5.4
 * ========================================================================== */

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ======================================================================
 * 兼容宏: Lua 5.1 / LuaJIT vs 5.2+
 * ====================================================================== */

#if LUA_VERSION_NUM < 502
  #define luaL_newlib(L, t)  luaL_register(L, "cprofiler", t)
  static lua_Integer cp_optinteger(lua_State *L, int idx, lua_Integer d) {
      if (lua_isnumber(L, idx)) return (lua_Integer)lua_tonumber(L, idx);
      return d;
  }
  #define luaL_optinteger cp_optinteger
  #ifndef LUA_OK
    #define LUA_OK 0
  #endif
#endif

/* ======================================================================
 * 常量
 * ====================================================================== */

#define CP_MAX_STACK_DEPTH   64
#define CP_KEY_LEN           256
#define CP_STACK_KEY_LEN     (CP_KEY_LEN * CP_MAX_STACK_DEPTH)
#define CP_SRC_LEN           128
#define CP_NAME_LEN          64
#define CP_INITIAL_CAPACITY  4096
#define CP_MAX_CAPACITY      (1 << 22)
#define CP_TOP_CALLSTACKS    50
#define CP_LOAD_FACTOR_PCT   70

/* ======================================================================
 * 数据结构
 * ====================================================================== */

typedef struct {
    char  key[CP_KEY_LEN];
    char  source[CP_SRC_LEN];
    char  name[CP_NAME_LEN];
    int   linedefined;
    int   samples;
    int   depth;
    int   used;
} cp_flat_t;

typedef struct {
    char  key[CP_STACK_KEY_LEN];
    int   samples;
    int   frame_count;
    char  frame_src[CP_MAX_STACK_DEPTH][CP_SRC_LEN];
    char  frame_name[CP_MAX_STACK_DEPTH][CP_NAME_LEN];
    int   frame_line[CP_MAX_STACK_DEPTH];
    int   used;
} cp_cs_t;

typedef struct {
    cp_flat_t *flats;
    int  flat_cap;
    int  flat_count;
    cp_cs_t   *css;
    int  cs_cap;
    int  cs_count;
    int  total_samples;
    int  sample_interval;
    int  max_depth;
    int  active;
    int  co_create_ref;
    int  co_wrap_ref;
    int  co_hooked;
} cp_state_t;

static cp_state_t g_st;

/* ======================================================================
 * 1. FNV-1a 哈希
 * ====================================================================== */
static unsigned int cp_hash(const char *s) {
    unsigned int h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
    return h;
}

/* ======================================================================
 * 2. flat 哈希表 (开放寻址, 线性探测)
 * ====================================================================== */
static int cp_flat_rehash(cp_state_t *st) {
    int new_cap = st->flat_cap * 2;
    if (new_cap > CP_MAX_CAPACITY) return -1;
    cp_flat_t *nf = (cp_flat_t *)calloc(new_cap, sizeof(cp_flat_t));
    if (!nf) return -1;
    cp_flat_t *old = st->flats;
    int old_cap = st->flat_cap;
    st->flats = nf;
    st->flat_cap = new_cap;
    st->flat_count = 0;
    for (int i = 0; i < old_cap; i++) {
        if (!old[i].used) continue;
        unsigned int h = cp_hash(old[i].key) & (new_cap - 1);
        while (nf[h].used) h = (h + 1) & (new_cap - 1);
        nf[h] = old[i];
        st->flat_count++;
    }
    free(old);
    return 0;
}

static cp_flat_t *cp_flat_get(cp_state_t *st, const char *key) {
    if (st->flat_count * 100 > st->flat_cap * CP_LOAD_FACTOR_PCT) {
        if (cp_flat_rehash(st) != 0) return NULL;
    }
    unsigned int h = cp_hash(key) & (st->flat_cap - 1);
    while (st->flats[h].used) {
        if (strcmp(st->flats[h].key, key) == 0) return &st->flats[h];
        h = (h + 1) & (st->flat_cap - 1);
    }
    cp_flat_t *e = &st->flats[h];
    memset(e, 0, sizeof(*e));
    strncpy(e->key, key, CP_KEY_LEN - 1);
    e->used = 1;
    st->flat_count++;
    return e;
}

/* ======================================================================
 * 3. callstack 哈希表
 * ====================================================================== */
static int cp_cs_rehash(cp_state_t *st) {
    int new_cap = st->cs_cap * 2;
    if (new_cap > CP_MAX_CAPACITY) return -1;
    cp_cs_t *nc = (cp_cs_t *)calloc(new_cap, sizeof(cp_cs_t));
    if (!nc) return -1;
    cp_cs_t *old = st->css;
    int old_cap = st->cs_cap;
    st->css = nc;
    st->cs_cap = new_cap;
    st->cs_count = 0;
    for (int i = 0; i < old_cap; i++) {
        if (!old[i].used) continue;
        unsigned int h = cp_hash(old[i].key) & (new_cap - 1);
        while (nc[h].used) h = (h + 1) & (new_cap - 1);
        nc[h] = old[i];
        st->cs_count++;
    }
    free(old);
    return 0;
}

static cp_cs_t *cp_cs_get(cp_state_t *st, const char *key) {
    if (st->cs_count * 100 > st->cs_cap * CP_LOAD_FACTOR_PCT) {
        if (cp_cs_rehash(st) != 0) return NULL;
    }
    unsigned int h = cp_hash(key) & (st->cs_cap - 1);
    while (st->css[h].used) {
        if (strcmp(st->css[h].key, key) == 0) return &st->css[h];
        h = (h + 1) & (st->cs_cap - 1);
    }
    cp_cs_t *e = &st->css[h];
    memset(e, 0, sizeof(*e));
    strncpy(e->key, key, CP_STACK_KEY_LEN - 1);
    e->used = 1;
    st->cs_count++;
    return e;
}

/* ======================================================================
 * 4. 采样钩子 — 核心热路径, 零 Lua 对象分配
 * ====================================================================== */
static void cp_sampling_hook(lua_State *L, lua_Debug *ar) {
    cp_state_t *st = &g_st;
    if (!st->active) return;
    st->total_samples++;
    lua_Debug info;
    char func_key[CP_KEY_LEN];
    char stack_key[CP_STACK_KEY_LEN];
    int  stack_len = 0;
    char seen_keys[CP_MAX_STACK_DEPTH][CP_KEY_LEN];
    int  seen_count = 0;
    for (int level = 1; level <= st->max_depth; level++) {
        if (lua_getstack(L, level, &info) == 0) break;
        if (lua_getinfo(L, "Sn", &info) == 0) continue;
        const char *source = (info.short_src[0] != '\0') ? info.short_src : "[C]";
        const char *name   = (info.name != NULL) ? info.name : "anonymous";
        int line = info.linedefined;
        snprintf(func_key, CP_KEY_LEN, "%s:%s:%d", source, name, line);
        int already_seen = 0;
        for (int i = 0; i < seen_count; i++) {
            if (strcmp(seen_keys[i], func_key) == 0) { already_seen = 1; break; }
        }
        if (!already_seen && seen_count < CP_MAX_STACK_DEPTH) {
            strncpy(seen_keys[seen_count], func_key, CP_KEY_LEN - 1);
            seen_count++;
            cp_flat_t *fe = cp_flat_get(st, func_key);
            if (fe) {
                if (fe->samples == 0) {
                    strncpy(fe->source, source, CP_SRC_LEN - 1);
                    strncpy(fe->name, name, CP_NAME_LEN - 1);
                    fe->linedefined = line;
                    fe->depth = level;
                }
                fe->samples++;
            }
        }
        int n = snprintf(stack_key + stack_len,
                         CP_STACK_KEY_LEN - stack_len, "%s|", func_key);
        if (n > 0) stack_len += n;
    }
    if (stack_len > 0) {
        cp_cs_t *cs = cp_cs_get(st, stack_key);
        if (cs) {
            if (cs->samples == 0) {
                int fc = 0;
                for (int level = 1; level <= st->max_depth && fc < CP_MAX_STACK_DEPTH; level++) {
                    lua_Debug info2;
                    if (lua_getstack(L, level, &info2) == 0) break;
                    if (lua_getinfo(L, "Sn", &info2) == 0) continue;
                    const char *src2 = (info2.short_src[0] != '\0') ? info2.short_src : "[C]";
                    const char *nm2  = (info2.name != NULL) ? info2.name : "anonymous";
                    strncpy(cs->frame_src[fc], src2, CP_SRC_LEN - 1);
                    strncpy(cs->frame_name[fc], nm2, CP_NAME_LEN - 1);
                    cs->frame_line[fc] = info2.linedefined;
                    fc++;
                }
                cs->frame_count = fc;
            }
            cs->samples++;
        }
    }
}

/* ======================================================================
 * 5. 协程支持: C 层拦截 coroutine.create / coroutine.wrap
 * ====================================================================== */
static int cp_wrapped_create(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    lua_State *co = lua_tothread(L, -1);
    if (co && g_st.active)
        lua_sethook(co, cp_sampling_hook, 0, g_st.sample_interval);
    return 1;
}

static int cp_wrap_resume_fn(lua_State *L) {
    lua_State *co = lua_tothread(L, lua_upvalueindex(1));
    if (!co) return luaL_error(L, "coroutine.wrap: invalid thread upvalue");
    int nargs = lua_gettop(L);
    if (nargs > 0) lua_xmove(L, co, nargs);
#if LUA_VERSION_NUM >= 502
    int status = lua_resume(co, L, nargs);
#else
    int status = lua_resume(co, nargs);
#endif
    int nres = lua_gettop(co);
    if (nres > 0) lua_xmove(co, L, nres);
    if (status != LUA_OK && status != LUA_YIELD)
        return lua_error(L);
    return nres;
}

static int cp_wrapped_wrap(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    lua_State *co = lua_tothread(L, -1);
    if (co && g_st.active)
        lua_sethook(co, cp_sampling_hook, 0, g_st.sample_interval);
    lua_pushcclosure(L, cp_wrap_resume_fn, 1);
    return 1;
}

static void cp_hook_coroutines(lua_State *L) {
    if (g_st.co_hooked) return;
    lua_getglobal(L, "coroutine");
    lua_getfield(L, -1, "create");
    g_st.co_create_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_getfield(L, -1, "wrap");
    g_st.co_wrap_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_pop(L, 1);
    lua_getglobal(L, "coroutine");
    lua_pushcfunction(L, cp_wrapped_create);
    lua_setfield(L, -2, "create");
    lua_pop(L, 1);
    lua_getglobal(L, "coroutine");
    lua_pushcfunction(L, cp_wrapped_wrap);
    lua_setfield(L, -2, "wrap");
    lua_pop(L, 1);
    g_st.co_hooked = 1;
}

static void cp_unhook_coroutines(lua_State *L) {
    if (!g_st.co_hooked) return;
    lua_getglobal(L, "coroutine");
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    lua_setfield(L, -2, "create");
    lua_pop(L, 1);
    lua_getglobal(L, "coroutine");
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_wrap_ref);
    lua_setfield(L, -2, "wrap");
    lua_pop(L, 1);
    luaL_unref(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    g_st.co_create_ref = LUA_NOREF;
    luaL_unref(L, LUA_REGISTRYINDEX, g_st.co_wrap_ref);
    g_st.co_wrap_ref = LUA_NOREF;
    g_st.co_hooked = 0;
}

/* ======================================================================
 * 6. 状态管理
 * ====================================================================== */
static void cp_init_state(cp_state_t *st) {
    st->flat_cap = CP_INITIAL_CAPACITY;
    st->flats = (cp_flat_t *)calloc(st->flat_cap, sizeof(cp_flat_t));
    st->flat_count = 0;
    st->cs_cap = CP_INITIAL_CAPACITY;
    st->css = (cp_cs_t *)calloc(st->cs_cap, sizeof(cp_cs_t));
    st->cs_count = 0;
    st->total_samples = 0;
    st->sample_interval = 10000;
    st->max_depth = 20;
    st->active = 0;
    st->co_create_ref = LUA_NOREF;
    st->co_wrap_ref = LUA_NOREF;
    st->co_hooked = 0;
}

static void cp_free_state(cp_state_t *st) {
    if (st->flats) { free(st->flats); st->flats = NULL; }
    if (st->css)   { free(st->css);   st->css = NULL;   }
    st->flat_cap = 0;
    st->cs_cap = 0;
    st->flat_count = 0;
    st->cs_count = 0;
}

static void cp_clear_data(cp_state_t *st) {
    if (st->flats) memset(st->flats, 0, st->flat_cap * sizeof(cp_flat_t));
    if (st->css)   memset(st->css,   0, st->cs_cap * sizeof(cp_cs_t));
    st->flat_count = 0;
    st->cs_count = 0;
    st->total_samples = 0;
}

/* ======================================================================
 * 7. 排序辅助
 * ====================================================================== */
static int cp_flat_cmp(const void *a, const void *b) {
    return ((const cp_flat_t *)b)->samples - ((const cp_flat_t *)a)->samples;
}
static int cp_cs_cmp(const void *a, const void *b) {
    return ((const cp_cs_t *)b)->samples - ((const cp_cs_t *)a)->samples;
}

/* ======================================================================
 * 8. Lua 接口
 * ====================================================================== */
static int cp_start(lua_State *L) {
    cp_state_t *st = &g_st;
    if (st->active) {
        lua_sethook(L, NULL, 0, 0);
        cp_unhook_coroutines(L);
        st->active = 0;
    }
    if (!st->flats) cp_init_state(st);
    cp_clear_data(st);
    st->sample_interval = (int)luaL_optinteger(L, 1, 10000);
    st->max_depth = (int)luaL_optinteger(L, 2, 20);
    if (st->max_depth > CP_MAX_STACK_DEPTH) st->max_depth = CP_MAX_STACK_DEPTH;
    lua_sethook(L, cp_sampling_hook, 0, st->sample_interval);
    cp_hook_coroutines(L);
    st->active = 1;
    fprintf(stderr, "[cprofiler] started: interval=%d, maxDepth=%d\n",
            st->sample_interval, st->max_depth);
    return 0;
}

static int cp_stop(lua_State *L) {
    cp_state_t *st = &g_st;
    if (!st->active) return 0;
    lua_sethook(L, NULL, 0, 0);
    cp_unhook_coroutines(L);
    st->active = 0;
    fprintf(stderr, "[cprofiler] stopped: total_samples=%d, flat_funcs=%d, callstacks=%d\n",
            st->total_samples, st->flat_count, st->cs_count);
    return 0;
}

static int cp_reset(lua_State *L) {
    cp_state_t *st = &g_st;
    if (st->active) {
        lua_sethook(L, NULL, 0, 0);
        cp_unhook_coroutines(L);
        st->active = 0;
    }
    cp_free_state(st);
    cp_init_state(st);
    return 0;
}

static int cp_report(lua_State *L) {
    cp_state_t *st = &g_st;
    cp_flat_t *farr = NULL;
    if (st->flat_count > 0) {
        farr = (cp_flat_t *)malloc(st->flat_count * sizeof(cp_flat_t));
        int idx = 0;
        for (int i = 0; i < st->flat_cap; i++)
            if (st->flats[i].used) farr[idx++] = st->flats[i];
        qsort(farr, st->flat_count, sizeof(cp_flat_t), cp_flat_cmp);
    }
    cp_cs_t *carr = NULL;
    if (st->cs_count > 0) {
        carr = (cp_cs_t *)malloc(st->cs_count * sizeof(cp_cs_t));
        int idx = 0;
        for (int i = 0; i < st->cs_cap; i++)
            if (st->css[i].used) carr[idx++] = st->css[i];
        qsort(carr, st->cs_count, sizeof(cp_cs_t), cp_cs_cmp);
    }
    lua_newtable(L);
    lua_pushinteger(L, st->total_samples);
    lua_setfield(L, -2, "total_samples");
    lua_pushinteger(L, st->sample_interval);
    lua_setfield(L, -2, "interval");
    lua_newtable(L);
    for (int i = 0; i < st->flat_count; i++) {
        cp_flat_t *e = &farr[i];
        lua_newtable(L);
        lua_pushstring(L, e->source); lua_setfield(L, -2, "source");
        lua_pushstring(L, e->name); lua_setfield(L, -2, "name");
        lua_pushinteger(L, e->linedefined); lua_setfield(L, -2, "line");
        lua_pushinteger(L, e->samples); lua_setfield(L, -2, "samples");
        double pct = st->total_samples > 0 ? (double)e->samples / st->total_samples * 100.0 : 0.0;
        lua_pushnumber(L, pct); lua_setfield(L, -2, "relative");
        lua_pushinteger(L, e->depth); lua_setfield(L, -2, "depth");
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "flat");
    lua_newtable(L);
    int cs_n = st->cs_count < CP_TOP_CALLSTACKS ? st->cs_count : CP_TOP_CALLSTACKS;
    for (int i = 0; i < cs_n; i++) {
        cp_cs_t *cs = &carr[i];
        lua_newtable(L);
        lua_pushinteger(L, cs->samples); lua_setfield(L, -2, "samples");
        double pct = st->total_samples > 0 ? (double)cs->samples / st->total_samples * 100.0 : 0.0;
        lua_pushnumber(L, pct); lua_setfield(L, -2, "relative");
        lua_newtable(L);
        for (int j = 0; j < cs->frame_count; j++) {
            lua_newtable(L);
            lua_pushstring(L, cs->frame_src[j]); lua_setfield(L, -2, "source");
            lua_pushstring(L, cs->frame_name[j]); lua_setfield(L, -2, "name");
            lua_pushinteger(L, cs->frame_line[j]); lua_setfield(L, -2, "line");
            lua_rawseti(L, -2, j + 1);
        }
        lua_setfield(L, -2, "frames");
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "callstacks");
    if (farr) free(farr);
    if (carr) free(carr);
    return 1;
}

static int cp_save(lua_State *L) {
    cp_state_t *st = &g_st;
    const char *path = luaL_optstring(L, 1, "cprofiler_report.txt");
    cp_flat_t *farr = NULL;
    if (st->flat_count > 0) {
        farr = (cp_flat_t *)malloc(st->flat_count * sizeof(cp_flat_t));
        int idx = 0;
        for (int i = 0; i < st->flat_cap; i++)
            if (st->flats[i].used) farr[idx++] = st->flats[i];
        qsort(farr, st->flat_count, sizeof(cp_flat_t), cp_flat_cmp);
    }
    cp_cs_t *carr = NULL;
    if (st->cs_count > 0) {
        carr = (cp_cs_t *)malloc(st->cs_count * sizeof(cp_cs_t));
        int idx = 0;
        for (int i = 0; i < st->cs_cap; i++)
            if (st->css[i].used) carr[idx++] = st->css[i];
        qsort(carr, st->cs_count, sizeof(cp_cs_t), cp_cs_cmp);
    }
    FILE *f = fopen(path, "w");
    if (!f) {
        if (farr) free(farr);
        if (carr) free(carr);
        lua_pushnil(L);
        lua_pushstring(L, "cannot open file");
        return 2;
    }
    fprintf(f, "##################################################################\n");
    fprintf(f, "##  cprofiler (C sampling profiler)\n");
    fprintf(f, "##################################################################\n\n");
    fprintf(f, "| TOTAL SAMPLES = %d, INTERVAL = %d VM instructions\n\n",
            st->total_samples, st->sample_interval);
    fprintf(f, "=== FLAT PROFILE (sorted by samples desc) ========================\n");
    fprintf(f, "%-50s %-40s %8s %8s %8s\n", "SOURCE", "FUNCTION", "LINE", "SAMPLES", "REL%");
    fprintf(f, "-----------------------------------------------------------------\n");
    for (int i = 0; i < st->flat_count; i++) {
        cp_flat_t *e = &farr[i];
        double pct = st->total_samples > 0 ? (double)e->samples / st->total_samples * 100.0 : 0.0;
        fprintf(f, "%-50s %-40s %8d %8d %7.2f%%\n",
                e->source, e->name, e->linedefined, e->samples, pct);
    }
    int cs_n = st->cs_count < CP_TOP_CALLSTACKS ? st->cs_count : CP_TOP_CALLSTACKS;
    fprintf(f, "\n=== TOP %d CALL STACKS (%d unique stacks) =======================\n", cs_n, st->cs_count);
    for (int i = 0; i < cs_n; i++) {
        cp_cs_t *cs = &carr[i];
        double pct = st->total_samples > 0 ? (double)cs->samples / st->total_samples * 100.0 : 0.0;
        fprintf(f, "\n--- Stack #%d: %d samples (%.2f%%) ---\n", i + 1, cs->samples, pct);
        for (int j = 0; j < cs->frame_count; j++) {
            for (int s = 0; s < j; s++) fprintf(f, "  ");
            fprintf(f, "%s:%d (%s)\n", cs->frame_src[j], cs->frame_line[j], cs->frame_name[j]);
        }
    }
    fprintf(f, "\n================================================================\n");
    fclose(f);
    if (farr) free(farr);
    if (carr) free(carr);
    lua_pushboolean(L, 1);
    return 1;
}

static int cp_isactive(lua_State *L) {
    lua_pushboolean(L, g_st.active);
    return 1;
}

/* ======================================================================
 * 9. 模块注册
 * ====================================================================== */
static const luaL_Reg cp_funcs[] = {
    {"start",    cp_start},
    {"stop",     cp_stop},
    {"reset",    cp_reset},
    {"report",   cp_report},
    {"save",     cp_save},
    {"isactive", cp_isactive},
    {NULL, NULL}
};

int luaopen_cprofiler(lua_State *L) {
    if (!g_st.flats) cp_init_state(&g_st);
    luaL_newlib(L, cp_funcs);
    return 1;
}

/* ======================================================================
 * 10. 库卸载时释放内存
 * ====================================================================== */
#if defined(__GNUC__)
__attribute__((destructor))
static void cp_dtor(void) { cp_free_state(&g_st); }
#elif defined(_WIN32)
#include <windows.h>
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    if (reason == DLL_PROCESS_DETACH) cp_free_state(&g_st);
    return TRUE;
}
#endif
```

---

## 8. 热更框架集成：cprofiler_manager.lua

> 合并 CPManager 封装 + GM 命令 + ProFi.lua 降级兼容，单文件可热更。

```lua
--[[
    cprofiler_manager.lua — C profiler 热更封装 + GM 命令 (单文件)

    热更方式: dofile("cprofiler_manager.lua")
    设计原则: 对齐 ProFi.lua 的热更模式
      - 全局表 CPManager = CPManager or {}
      - _initialized 防止重复初始化
      - C 层 .so 不参与热更, require 只执行一次
      - 与 ProFi.lua 共存: 互斥启动, 可降级

    GM 命令:
        !profi start [interval] [depth] [duration]   启动采样
        !profi stop                                   停止并输出报告
        !profi status                                 查看状态
        !profi reset                                  重置
]]

CPManager = CPManager or {}

local DEFAULT_INTERVAL  = 5000
local DEFAULT_DEPTH     = 20
local DEFAULT_DURATION  = 120
local REPORT_DIR        = "./"
local TOP_N_FLAT        = 10
local TOP_N_CALLSTACKS  = 5
local MIN_INTERVAL      = 100

if not CPManager._cprofiler then
    local ok, mod = pcall(require, "cprofiler")
    if ok then
        CPManager._cprofiler = mod
        CPManager._mode = "c"
        print("[CPManager] C profiler loaded (cprofiler.so)")
    else
        print("[CPManager] cprofiler.so not found: " .. tostring(mod))
        print("[CPManager] Falling back to ProFi.lua sampling mode")
        CPManager._cprofiler = nil
        CPManager._mode = "lua"
    end
end

local cprofiler = CPManager._cprofiler

local function isActive()
    if CPManager._mode == "c" and cprofiler then
        return cprofiler.isactive()
    else
        return ProFi and ProFi.has_started and not ProFi.has_finished
    end
end

function CPManager:start(interval, depth, duration)
    interval = interval or DEFAULT_INTERVAL
    depth    = depth or DEFAULT_DEPTH
    duration = duration or DEFAULT_DURATION
    if interval < MIN_INTERVAL then
        return false, string.format("interval too small (<%d)", MIN_INTERVAL)
    end
    if depth < 1 or depth > 64 then
        return false, "depth range: 1~64"
    end
    if isActive() then self:stop() end
    self._startInfo = {
        interval = interval, depth = depth,
        duration = duration, startTime = os.time(),
    }
    if self._mode == "c" and cprofiler then
        cprofiler.start(interval, depth)
    else
        if not ProFi then dofile("ProFi.lua") end
        ProFi:startSampling(interval, depth)
    end
    if duration > 0 then
        self._timerId = DelayExecuteEx(duration * 1000, function()
            print("[CPManager] Auto-stop timer triggered")
            CPManager:stop()
        end)
    end
    local mode = self._mode == "c" and "C(cprofiler.so)" or "Lua(ProFi.lua)"
    print(string.format("[CPManager] Started [%s]: interval=%d, depth=%d, duration=%ds",
        mode, interval, depth, duration))
    return true, "ok"
end

function CPManager:stop()
    if not isActive() then return false end
    self._timerId = nil
    local filename = REPORT_DIR .. "cprofiler_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
    if self._mode == "c" and cprofiler then
        cprofiler.stop()
        cprofiler.save(filename)
        local data = cprofiler.report()
        print(string.format("[CPManager] Stopped: total_samples=%d, flat_funcs=%d, callstacks=%d",
            data.total_samples, #data.flat, #data.callstacks))
        print("[CPManager] Report saved to: " .. filename)
        print(string.format("[CPManager] Top %d hot functions:", TOP_N_FLAT))
        for i = 1, math.min(TOP_N_FLAT, #data.flat) do
            local e = data.flat[i]
            print(string.format("  #%d  %s:%s:%d  %d samples (%.2f%%)",
                i, e.source, e.name, e.line, e.samples, e.relative))
        end
        print(string.format("[CPManager] Top %d call stacks:", TOP_N_CALLSTACKS))
        for i = 1, math.min(TOP_N_CALLSTACKS, #data.callstacks) do
            local cs = data.callstacks[i]
            print(string.format("  #%d  %d samples (%.2f%%)", i, cs.samples, cs.relative))
            for j = 1, #cs.frames do
                local f = cs.frames[j]
                local indent = string.rep("    ", j)
                print(string.format("%s%s:%d (%s)", indent, f.source, f.line, f.name))
            end
        end
    else
        ProFi:stop()
        ProFi:writeReport(filename)
        print("[CPManager] [ProFi mode] Report saved to: " .. filename)
    end
    self._startInfo = nil
    return true
end

function CPManager:status()
    if not isActive() then
        print("[CPManager] Status: INACTIVE")
        return
    end
    local info = self._startInfo
    local mode = self._mode == "c" and "C(cprofiler.so)" or "Lua(ProFi.lua)"
    if info then
        local elapsed = os.time() - info.startTime
        print(string.format("[CPManager] Status: ACTIVE [%s] | interval=%d, depth=%d, elapsed=%ds/%ds",
            mode, info.interval, info.depth, elapsed, info.duration))
    else
        print(string.format("[CPManager] Status: ACTIVE [%s] (started before hot-reload)", mode))
    end
end

function CPManager:reset()
    if self._mode == "c" and cprofiler then
        cprofiler.reset()
    elseif ProFi then
        ProFi:reset()
    end
    self._startInfo = nil
    self._timerId = nil
    print("[CPManager] Reset")
end

function GMProfi_HandleCommand(player, command, args)
    if not CPManager._initialized then return "❌ CPManager not initialized" end
    if command == "start" then
        local interval = tonumber(args[1]) or DEFAULT_INTERVAL
        local depth    = tonumber(args[2]) or DEFAULT_DEPTH
        local duration = tonumber(args[3]) or DEFAULT_DURATION
        local ok, msg = CPManager:start(interval, depth, duration)
        if ok then
            return string.format("✅ Profiler started: interval=%d, depth=%d, duration=%ds",
                interval, depth, duration)
        else
            return "❌ " .. msg
        end
    elseif command == "stop" then
        CPManager:stop()
        return "✅ Profiler stopped, report saved"
    elseif command == "status" then
        CPManager:status()
        return ""
    elseif command == "reset" then
        CPManager:reset()
        return "✅ Profiler reset"
    else
        return "❌ Unknown subcommand: " .. tostring(command)
    end
end

function GMProfi_ParseAndExecute(player, cmdString)
    local parts = {}
    for w in (cmdString or ""):gmatch("%S+") do parts[#parts + 1] = w end
    if #parts == 0 then return "❌ Empty command" end
    if parts[1]:lower() == "profi" then table.remove(parts, 1) end
    if #parts == 0 then return "❌ No subcommand" end
    local subcmd = table.remove(parts, 1)
    return GMProfi_HandleCommand(player, subcmd, parts)
end

if not CPManager._initialized then
    CPManager._initialized = true
    local mode = CPManager._mode == "c" and "C(cprofiler.so)" or "Lua(ProFi.lua fallback)"
    print(string.format("[CPManager] Initialized, mode=%s", mode))
end

return CPManager
```

---

## 9. 编译与使用指南

### 编译

```bash
# Linux / macOS
gcc -O2 -shared -fPIC -o cprofiler.so cprofiler.c -I/path/to/lua/include -llua

# LuaJIT 环境
gcc -O2 -shared -fPIC -o cprofiler.so cprofiler.c -I/path/to/luajit/include -lluajit-5.1

# Windows
cl /O2 /LD cprofiler.c /I<path/to/lua/include> /link lua51.lib /OUT:cprofiler.dll
```

### 部署步骤

1. 编译 `cprofiler.so`，放到 Lua `package.cpath` 能找到的目录
2. 放置 `cprofiler_manager.lua` 到 Lua `package.path` 能找到的目录
3. 服务器启动时加载：`dofile("cprofiler_manager.lua")`
4. GM 命令触发：`!profi start 5000 20 120`
5. 120 秒后自动停止，报告输出到当前目录
6. 需要改参数时：`dofile("cprofiler_manager.lua")` 热更，新参数立即生效

### GM 命令

```
!profi start [interval] [depth] [duration]   启动采样
!profi stop                                   停止并输出报告
!profi status                                 查看状态
!profi reset                                  重置
```

### 热更安全性

| 组件 | 热更后状态 | 原因 |
|------|-----------|------|
| C 层 `g_st` | **不变** | C 静态变量，不受 Lua 热更影响 |
| `g_st.active` | **仍为 1** | 采样继续运行 |
| 主线程 hook | **不变** | `lua_sethook` 设置在 C 层 |
| 协程拦截 | **不变** | `coroutine.create/wrap` 已被 C 函数替换 |
| `CPManager` 全局表 | **保留** | `CPManager = CPManager or {}` |
| 定时器 | **保留** | 闭包引用全局表，热更后新代码生效 |

**结论：采样运行中热更完全安全，不需要停止采样。**

---

## 10. 与 ProFi.lua 的功能对齐

| 功能 | ProFi.lua | C 版 (cprofiler) |
|------|-----------|------------------|
| flat 统计 | ✅ `recordSample` | ✅ `cp_flat_get` |
| CallStack 聚合 | ✅ `callStackReportsByKey` | ✅ `cp_cs_get` |
| 协程支持 | ✅ 拦截 `coroutine.create/wrap` | ✅ 同 (纯 C ref) |
| 报告文件 | ✅ `writeReport` | ✅ `cp.save` |
| Lua table 输出 | ❌ 仅文件 | ✅ `cp.report` |
| 热更新友好 | ✅ 全局表 + dofile | ✅ C 层不参与热更 |
| 单次采样开销 | ~15μs (depth=20) | ~3μs (depth=20) |
| GC 压力 | 每采样 20+ table 分配 | **零分配** |
| RNG 扰动风险 | 理论上有 (GC→__gc) | **零** |
| coroutine.wrap 恢复 | Lua 全局表 | C 层 registry ref |
| 降级兼容 | N/A | ✅ 无 .so 时 fallback 到 ProFi.lua |

### 性能对比

| 指标 | 纯 Lua 版 (depth=20) | C 版 (depth=20) | C 版 (depth=10) |
|------|---------------------|-----------------|-----------------|
| 单次采样开销 | ~15μs | ~3μs | ~1.5μs |
| 每采样 Lua 对象分配 | 20+ table | 0 | 0 |
| GC 压力 | 高 | **零** | **零** |
| 5000 间隔 CPU 占比 | ~15% | ~3% | ~1.5% |
| 10000 间隔 CPU 占比 | ~7.5% | ~1.5% | ~0.75% |

---

## 附录：ProFi.lua 原始代码

ProFi.lua v2.2 的完整代码已在项目工程中，此处不再重复粘贴。关键信息：

- **版本**: v2.2 (global mode, hot-reloadable, with sampling, coroutine & callstack aggregation)
- **热更方式**: `dofile("ProFi.lua")`，全局表 `ProFi = ProFi or {}`
- **精确模式**: `ProFi:start()` / `ProFi:stop()` / `ProFi:writeReport()`
- **采样模式**: `ProFi:startSampling(interval, depth)` / `ProFi:stop()` / `ProFi:writeReport()`
- **协程拦截**: `self._rawCoroutineCreate` / `self._rawCoroutineWrap` 保存原始函数
- **外网验证间隔**: 5000 (2026.3.11 验证可接受)

---

*文档生成时间: 2026-07-04*
*作者: 冰冰 (冰川网络 AI 助理)*
*项目: X-Clash 服务器组 Lua Profiler 技术方案*
