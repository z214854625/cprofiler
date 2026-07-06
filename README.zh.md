
#一、说明
cprofiler 是ProFi.lua的c版本实现；
	
#二、目的：
	profiler 不会直接扰动 RNG（hook 不调用 math.random，RNG 状态独立于 VM 指令计数器），
	但 Lua 版可能通过 GC → __gc 终结器的间接路径扰动 RNG。C 版零 Lua 对象分配，彻底消除这个风险。如果战斗逻辑依赖 RNG 确定性，用 C 版最安全。
	
	下面是完整可编译的单文件 C 实现，功能对齐 ProFi.lua 的采样模式，包含 flat 统计 + CallStack 聚合 + 协程支持，零 Lua 对象分配

#三、关键设计点回顾
设计点											做法											为什么
lua_Debug 栈上分配						lua_Debug info; 局部变量					lua_getinfo 写入已有结构体，不创建 Lua table
lua_getinfo("Sn")						只请求 source + name						不请求 'f'(函数对象)、'L'(activelines table)，避免 Lua 分配
key 用 char[] 拼接						snprintf(buf, ...)							不产生 Lua 字符串对象，零 GC 压力
开放寻址哈希表							连续内存 calloc								cache-friendly，热点函数命中率高时几乎 1 次 cache line
排序推迟到 report/save					采样阶段只做 O(1) 查找+自增					钩子热路径不做 O(n log n) 排序
协程拦截用 registry ref					luaL_ref 保存原始函数						跨热更安全，不会丢失原始引用
coroutine.wrap 用 Lua 层包装			luaL_dostring 注入代码						C 层模拟 wrap 的 resume 行为容易出 bug，Lua 层更可靠

#四、与 ProFi.lua 的热更对比
维度				ProFi.lua						cprofiler + CPManager
热更方式			dofile("ProFi.lua")				dofile("cprofiler_manager.lua")
全局表				ProFi = ProFi or {}				CPManager = CPManager or {}
首次初始化			if not ProFi._initialized		if not CPManager._initialized
状态持久化			全局表字段						C 层 g_st 静态变量（更可靠）
协程拦截恢复		全局表 _rawCoroutineCreate		C 层 registry ref（更可靠）
热更时采样运行中	✅ 安全							✅ 安全（C 层不受影响）
.so 本身热更		N/A								❌ 不支持（需重启）

#五、so热更方案
缓解方案：如果不想重启，可以用版本化文件名：
-- 每次修改 .c 后, 编译为带版本号的 .so
-- cprofiler_v1.so, cprofiler_v2.so, ...
local version = 1
local cprofiler = require("cprofiler_v" .. version)
但这种方式会导致旧 g_st 的内存泄漏（旧 .so 卸载时如果 __attribute__((destructor)) 正常执行则不会）。实际上游戏服务器很少频繁改 C 扩展，这个场景不常见。