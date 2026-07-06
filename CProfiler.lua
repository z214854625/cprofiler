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

    无 cprofiler.so 时自动降级到 ProFi.lua 采样模式
]]

-----------------------
-- 全局表 (热更时保留)
-----------------------
CPManager = CPManager or {}

-----------------------
-- 常量 (热更时重新赋值, 新值立即生效)
-----------------------
local DEFAULT_INTERVAL  = 5000    -- 默认采样间隔
local DEFAULT_DEPTH     = 20      -- 默认最大栈深
local DEFAULT_DURATION  = 120     -- 默认采样时长(秒), 0=不自动停止
local REPORT_DIR        = "./"    -- 报告输出目录
local TOP_N_FLAT        = 10      -- 日志输出 Top N 函数
local TOP_N_CALLSTACKS  = 5       -- 日志输出 Top N 调用栈
local MIN_INTERVAL      = 100     -- 最小采样间隔 (防误操作)

-----------------------
-- C 模块加载 (仅首次 require, 后续热更跳过)
-----------------------
-- require 只执行一次 (dlopen 只加载一次 .so)
-- 热更时 cprofiler 局部变量已 upvalue 绑定, 不会重新 require
if not CPManager._cprofiler then
    --设置so路径
    if not string.find(package.cpath, "CommonLib/?.so", 1, true) then
        package.cpath = "../CommonLib/?.so;" .. package.cpath
    end
    --require
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

-----------------------
-- 内部: 获取当前活跃的 profiler
-----------------------
local function isActive()
    if CPManager._mode == "c" and cprofiler then
        return cprofiler.isactive()
    else
        -- ProFi.lua 模式
        return ProFi and ProFi.has_started and not ProFi.has_finished
    end
end

-----------------------
-- 公共接口
-----------------------

--[[
    启动采样

    参数:
        interval  - 采样间隔 (VM指令数), 默认 5000
        depth     - 最大栈深, 默认 20
        duration  - 自动停止时间(秒), 0=不自动停止, 默认 120

    返回: true/false, string
]]
function CPManager:start(interval, depth, duration)
    interval = interval or DEFAULT_INTERVAL
    depth    = depth or DEFAULT_DEPTH
    duration = duration or DEFAULT_DURATION

    -- 参数校验
    if interval < MIN_INTERVAL then
        return false, string.format("interval too small (<%d), will cause severe lag", MIN_INTERVAL)
    end
    if depth < 1 or depth > 64 then
        return false, "depth range: 1~64"
    end

    -- 如果已在运行, 先停止 (防止重复启动)
    if isActive() then
        self:stop()
    end

    -- 记录启动信息
    self._startInfo = {
        interval = interval,
        depth = depth,
        duration = duration,
        startTime = os.time(),
    }

    if self._mode == "c" and cprofiler then
        -- ---- C 模式 ----
        cprofiler.start(interval, depth)
    else
        -- ---- ProFi.lua 降级模式 ----
        if not ProFi then
            dofile("ProFi.lua")
        end
        ProFi:startSampling(interval, depth)
    end

    -- 设置自动停止定时器
    if duration > 0 then
        self._timerId = DelayExecuteEx(duration * 1000, function()
            print("[CPManager] Auto-stop timer triggered")
            CPManager:stop()
        end)
        self._startInfo.timerId = self._timerId
    end

    local mode = self._mode == "c" and "C(cprofiler.so)" or "Lua(ProFi.lua)"
    print(string.format("[CPManager] Started [%s]: interval=%d, depth=%d, duration=%ds",
        mode, interval, depth, duration))
    return true, "ok"
end

--[[
    停止采样并输出报告
]]
function CPManager:stop()
    if not isActive() then
        print("[CPManager] Not active, skip stop")
        return false
    end

    -- 取消定时器 (如果你们的框架有 CancelTimer 接口, 取消注释)
    -- if self._timerId and CancelTimer then
    --     CancelTimer(self._timerId)
    -- end
    self._timerId = nil

    local info = self._startInfo
    local filename = REPORT_DIR .. "cprofiler_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"

    if self._mode == "c" and cprofiler then
        -- ---- C 模式 ----
        cprofiler.stop()
        cprofiler.save(filename)

        -- 获取 Lua table 输出摘要
        local data = cprofiler.report()
        print(string.format("[CPManager] Stopped: total_samples=%d, flat_funcs=%d, callstacks=%d",
            data.total_samples, #data.flat, #data.callstacks))
        print("[CPManager] Report saved to: " .. filename)

        -- 输出 Top N 热点函数
        print(string.format("[CPManager] Top %d hot functions:", TOP_N_FLAT))
        for i = 1, math.min(TOP_N_FLAT, #data.flat) do
            local e = data.flat[i]
            print(string.format("  #%d  %s:%s:%d  %d samples (%.2f%%)",
                i, e.source, e.name, e.line, e.samples, e.relative))
        end

        -- 输出 Top N 调用栈
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
        -- ---- ProFi.lua 降级模式 ----
        ProFi:stop()
        ProFi:writeReport(filename)
        print("[CPManager] [ProFi mode] Report saved to: " .. filename)
    end

    self._startInfo = nil
    return true
end

--[[
    查询当前状态
]]
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
        print(string.format("[CPManager] Status: ACTIVE [%s] (started before hot-reload, info unavailable)", mode))
    end
end

--[[
    重置 (释放内存)
]]
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

-----------------------
-- GM 命令处理
-----------------------

--[[
    GM 命令分发

    用法:
        GMProfi_HandleCommand(player, "start", {"5000", "20", "120"})
        GMProfi_HandleCommand(player, "stop", {})
        GMProfi_HandleCommand(player, "status", {})
        GMProfi_HandleCommand(player, "reset", {})

    或者从字符串解析:
        local cmd, args = "start 5000 20 120"
        local parts = {}
        for w in cmd:gmatch("%S+") do parts[#parts+1] = w end
        local subcmd = table.remove(parts, 1)
        GMProfi_HandleCommand(player, subcmd, parts)
]]
function GMProfi_HandleCommand(player, command, args)
    -- 首次调用时确保已加载
    if not CPManager._initialized then
        print("[CPManager] Not initialized, skipping")
        return "? CPManager not initialized"
    end

    if command == "start" then
        local interval = tonumber(args[1]) or DEFAULT_INTERVAL
        local depth    = tonumber(args[2]) or DEFAULT_DEPTH
        local duration = tonumber(args[3]) or DEFAULT_DURATION
        local ok, msg = CPManager:start(interval, depth, duration)
        if ok then
            return string.format("? Profiler started: interval=%d, depth=%d, duration=%ds",
                interval, depth, duration)
        else
            return "? " .. msg
        end

    elseif command == "stop" then
        CPManager:stop()
        return "? Profiler stopped, report saved"

    elseif command == "status" then
        CPManager:status()
        return ""

    elseif command == "reset" then
        CPManager:reset()
        return "? Profiler reset"

    else
        return "? Unknown subcommand: " .. tostring(command) ..
               " (available: start, stop, status, reset)"
    end
end

--[[
    便捷: 从完整命令字符串解析并执行
    示例:
        GMProfi_ParseAndExecute(player, "profi start 5000 20 120")
        GMProfi_ParseAndExecute(player, "profi stop")
]]
function GMProfi_ParseAndExecute(player, cmdString)
    local parts = {}
    for w in (cmdString or ""):gmatch("%S+") do
        parts[#parts + 1] = w
    end
    if #parts == 0 then
        return "? Empty command"
    end
    -- 跳过 "profi" 前缀 (如果有的话)
    if parts[1]:lower() == "profi" then
        table.remove(parts, 1)
    end
    if #parts == 0 then
        return "? No subcommand. Usage: profi start|stop|status|reset [args]"
    end
    local subcmd = table.remove(parts, 1)
    return GMProfi_HandleCommand(player, subcmd, parts)
end

-----------------------
-- 初始化 (仅首次执行)
-----------------------
if not CPManager._initialized then
    CPManager._initialized = true
    local mode = CPManager._mode == "c" and "C(cprofiler.so)" or "Lua(ProFi.lua fallback)"
    print(string.format("[CPManager] Initialized, mode=%s", mode))
end

