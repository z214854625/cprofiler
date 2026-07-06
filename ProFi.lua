--[[
	ProFi v2.2, based on ProFi v1.3 by Luke Perkin 2012.
	MIT Licence http://www.opensource.org/licenses/mit-license.php.

	v2.0 新增采样模式(sampling mode)，适合生产环境使用。
	v2.1 改为全局变量模式，支持热更新(dofile重新加载)。
	v2.2 新增 CallStack 聚合功能，按完整调用栈统计采样命中。
	原有精确模式(precise mode)保持完全向后兼容。

	=== 精确模式（原有，开发/测试用） ===
		ProFi:start()
		some_function()
		ProFi:stop()
		ProFi:writeReport( 'ProFi_precise.txt' )

	=== 采样模式（新增，适合生产环境） ===
		ProFi:startSampling( 10000, 20 ) -- 每10000条指令采样一次, 最大栈深20
		-- ... 运行业务逻辑 ...
		ProFi:stop()
		ProFi:writeReport( 'ProFi_sampling.txt' )

		--目前外网测试过5000是可以接受的范围，如果cpu非常高的情况下，建议改成10000左右
		--可以5000~10000调优下看看 2026.3.11
		print("ProFi 1--")
		ProFi:startSampling(5000, 20)
		DelayExecuteEx(120*1000, function()
			print("ProFi 2--")
			ProFi:stop()
			ProFi:writeReport("profile_sampling3000.txt")
		end)

	API:
	*Arguments are specified as: type/name/default.
		-- 精确模式 (原有)
		ProFi:start( string/once/nil )
		ProFi:stop()
		ProFi:checkMemory( number/interval/0, string/note/'' )
		ProFi:writeReport( string/filename/'ProFi.txt' )
		ProFi:reset()
		ProFi:setHookCount( number/hookCount/0 )
		ProFi:setGetTimeMethod( function/getTimeMethod/os.clock )
		ProFi:setInspect( string/methodName, number/levels/1 )

		-- 采样模式 (新增)
		ProFi:startSampling( number/sampleInterval/10000, number/maxStackDepth/20 )
		ProFi:stop()
		ProFi:writeReport( string/filename/'ProFi.txt' )
]]

-----------------------
-- Locals (常量和内部函数，热更时重新赋值):
-----------------------

-- 全局 ProFi 表，热更时保留已有实例
ProFi = ProFi or {}

local onDebugHook, onSamplingHook, sortByDurationDesc, sortByCallCount, sortBySampleCount, getTime
local DEFAULT_DEBUG_HOOK_COUNT  = 0
local DEFAULT_SAMPLE_INTERVAL   = 10000  -- 每10000条VM指令采样一次（游戏服务器Lua执行密度低，需要较小间隔）
local DEFAULT_MAX_STACK_DEPTH   = 20     -- 采样时最大栈深度
local DEFAULT_TOP_CALLSTACKS    = 50     -- CallStack 聚合报告中输出的 Top N 条数
local FORMAT_HEADER_LINE       = "| %-50s: %-40s: %-20s: %-12s: %-12s: %-12s|\n"
local FORMAT_OUTPUT_LINE       = "| %s: %-12s: %-12s: %-12s|\n"
local FORMAT_SAMPLING_HEADER   = "| %-50s: %-40s: %-20s: %-12s: %-12s|\n"
local FORMAT_SAMPLING_LINE     = "| %s: %-12s: %-12s|\n"
local FORMAT_INSPECTION_LINE   = "> %s: %-12s\n"
local FORMAT_TOTALTIME_LINE    = "| TOTAL TIME = %f\n"
local FORMAT_TOTALSAMPLES_LINE = "| TOTAL SAMPLES = %d, SAMPLE INTERVAL = %d instructions\n"
local FORMAT_MEMORY_LINE 	   = "| %-20s: %-16s: %-16s| %s\n"
local FORMAT_HIGH_MEMORY_LINE  = "H %-20s: %-16s: %-16sH %s\n"
local FORMAT_LOW_MEMORY_LINE   = "L %-20s: %-16s: %-16sL %s\n"
local FORMAT_TITLE             = "%-50.50s: %-40.40s: %-20s"
local FORMAT_LINENUM           = "%4i"
local FORMAT_TIME              = "%04.3f"
local FORMAT_RELATIVE          = "%03.2f%%"
local FORMAT_COUNT             = "%7i"
local FORMAT_KBYTES  		   = "%7i Kbytes"
local FORMAT_MBYTES  		   = "%7.1f Mbytes"
local FORMAT_MEMORY_HEADER1    = "\n=== HIGH & LOW MEMORY USAGE ===============================\n"
local FORMAT_MEMORY_HEADER2    = "=== MEMORY USAGE ==========================================\n"
local FORMAT_BANNER 		   = [[
###############################################################################################################
#####  ProFi, a lua profiler. This profile was generated on: %s
#####  ProFi is created by Luke Perkin 2012 under the MIT Licence, www.locofilm.co.uk
#####  Version 2.2 (global mode, hot-reloadable, with sampling, coroutine & callstack aggregation)
###############################################################################################################

]]

-----------------------
-- Public Methods:
-----------------------

--[[
	Starts profiling any method that is called between this and ProFi:stop().
	Pass the parameter 'once' to so that this methodis only run once.
	Example:
		ProFi:start( 'once' )
]]
function ProFi:start( param )
	if param == 'once' then
		if self:shouldReturn() then
			return
		else
			self.should_run_once = true
		end
	end
	self.has_started  = true
	self.has_finished = false
	self.profilingMode = 'precise'
	self:resetReports( self.reports )
	self:startHooks()
	self.startTime = getTime()
end

--[[
	以采样模式启动性能分析（新增，适合生产环境）。
	基于VM指令计数的钩子，定期采样当前调用栈。
	开销极低，适合在生产环境长时间运行。

	参数: [sampleInterval:number:可选] 两次采样之间的VM指令数。
		   默认10000。游戏服务器大部分时间在C++事件循环中等待，
		   Lua代码只在事件触发时短暂执行，需要较小的间隔才能获得足够采样。
		   值越大开销越低，但采样数越少。
		   推荐: 1000（极高精度） ~ 100000（低开销）。
	参数: [maxStackDepth:number:可选] 每次采样捕获的最大栈帧数。
		   默认20。
	示例:
		ProFi:startSampling()              -- 使用默认值(10000)
		ProFi:startSampling(1000, 20)      -- 高精度模式，短时间分析用
		ProFi:startSampling(100000, 20)    -- 低开销模式，长时间运行用
]]
function ProFi:startSampling( sampleInterval, maxStackDepth )
	-- 如果上一次采样会话仍在运行，先清理旧钩子（防止重复热更导致旧协程钩子泄漏）
	if self.has_started and self.profilingMode == 'sampling' then
		self:stopSamplingHook()
	end
	self.has_started  = true
	self.has_finished = false
	self.profilingMode = 'sampling'
	self.sampleInterval = sampleInterval or DEFAULT_SAMPLE_INTERVAL
	self.maxStackDepth  = maxStackDepth or DEFAULT_MAX_STACK_DEPTH
	self.totalSamples   = 0
	self.samplingReports = {}
	self.samplingReportsByKey = {}
	-- CallStack 聚合数据
	self.callStackReports = {}
	self.callStackReportsByKey = {}
	self:startSamplingHook()
	self.startTime = getTime()
end

--[[
	Stops profiling.
]]
function ProFi:stop()
	if self:shouldReturn() then
		return
	end
	self.stopTime = getTime()
	if self.profilingMode == 'sampling' then
		self:stopSamplingHook()
	else
		self:stopHooks()
	end
	self.has_finished = true
end

function ProFi:checkMemory( interval, note )
	local time = getTime()
	local interval = interval or 0
	if self.lastCheckMemoryTime and time < self.lastCheckMemoryTime + interval then
		return
	end
	self.lastCheckMemoryTime = time
	local memoryReport = {
		['time']   = time;
		['memory'] = collectgarbage('count');
		['note']   = note or '';
	}
	table.insert( self.memoryReports, memoryReport )
	self:setHighestMemoryReport( memoryReport )
	self:setLowestMemoryReport( memoryReport )
end

--[[
	将给定的文件名附加时间戳。
	规则：在最后一个 '.' 之前插入 _YYYYMMDD_HHMMSS；无扩展名则直接追加。
	例：'ProFi.txt' -> 'ProFi_20260508_143022.txt'
	     'ProFi'     -> 'ProFi_20260508_143022'
]]
local function appendTimestampToFilename( filename )
	local timestamp = os.date('%Y%m%d_%H%M%S')
	-- 找最后一个 '.' 的位置（且其后不含路径分隔符，避免 './foo' 之类被误判）
	local dotPos = filename:find('%.[^%./\\]*$')
	if dotPos then
		return filename:sub(1, dotPos - 1) .. '_' .. timestamp .. filename:sub(dotPos)
	end
	return filename .. '_' .. timestamp
end

--[[
	Writes the profile report to a file.
	Param: [filename:string:optional] defaults to 'ProFi.txt' if not specified.
	文件名会自动追加时间戳，避免多次导出互相覆盖。
]]
function ProFi:writeReport( filename )
	if self.profilingMode == 'sampling' then
		if self.samplingReports and #self.samplingReports > 0 then
			filename = appendTimestampToFilename( filename or 'ProFi.txt' )
			table.sort( self.samplingReports, sortBySampleCount )
			self:writeReportsToFilename( filename )
			print( string.format("[ProFi]\t Sampling report written to %s", filename) )
		end
	else
		if #self.reports > 0 or #self.memoryReports > 0 then
			filename = appendTimestampToFilename( filename or 'ProFi.txt' )
			self:sortReportsWithSortMethod( self.reports, self.sortMethod )
			self:writeReportsToFilename( filename )
			print( string.format("[ProFi]\t Report written to %s", filename) )
		end
	end
end

--[[
	Resets any profile information stored.
]]
function ProFi:reset()
	self.reports = {}
	self.reportsByTitle = {}
	self.memoryReports  = {}
	self.highestMemoryReport = nil
	self.lowestMemoryReport  = nil
	self.has_started  = false
	self.has_finished = false
	self.should_run_once = false
	self.lastCheckMemoryTime = nil
	self.hookCount = self.hookCount or DEFAULT_DEBUG_HOOK_COUNT
	self.sortMethod = self.sortMethod or sortByDurationDesc
	self.inspect = nil
	self.profilingMode = nil
	-- 采样模式状态
	self.samplingReports = {}
	self.samplingReportsByKey = {}
	self.totalSamples = 0
	self.sampleInterval = DEFAULT_SAMPLE_INTERVAL
	self.maxStackDepth  = DEFAULT_MAX_STACK_DEPTH
	-- CallStack 聚合状态
	self.callStackReports = {}
	self.callStackReportsByKey = {}
	-- 协程采样状态
	self._hookedCoroutines = nil
end

--[[
	Set how often a hook is called.
	See http://pgl.yoyo.org/luai/i/debug.sethook for information.
	Param: [hookCount:number] if 0 ProFi counts every time a function is called.
	if 2 ProFi counts every other 2 function calls.
]]
function ProFi:setHookCount( hookCount )
	self.hookCount = hookCount
end

--[[
	Set how the report is sorted when written to file.
	Param: [sortType:string] either 'duration' or 'count'.
	'duration' sorts by the time a method took to run.
	'count' sorts by the number of times a method was called.
	'samples' 按采样命中次数排序（采样模式专用，采样模式下默认使用）。
]]
function ProFi:setSortMethod( sortType )
	if sortType == 'duration' then
		self.sortMethod = sortByDurationDesc
	elseif sortType == 'count' then
		self.sortMethod = sortByCallCount
	elseif sortType == 'samples' then
		self.sortMethod = sortBySampleCount
	end
end

--[[
	By default the getTime method is os.clock (CPU time),
	If you wish to use other time methods pass it to this function.
	Param: [getTimeMethod:function]
]]
function ProFi:setGetTimeMethod( getTimeMethod )
	getTime = getTimeMethod
end

--[[
	Allows you to inspect a specific method.
	Will write to the report a list of methods that
	call this method you're inspecting, you can optionally
	provide a levels parameter to traceback a number of levels.
	Params: [methodName:string] the name of the method you wish to inspect.
	        [levels:number:optional] the amount of levels you wish to traceback, defaults to 1.
]]
function ProFi:setInspect( methodName, levels )
	if self.inspect then
		self.inspect.methodName = methodName
		self.inspect.levels = levels or 1
	else
		self.inspect = {
			['methodName'] = methodName;
			['levels'] = levels or 1;
		}
	end
end

-----------------------
-- Implementations methods:
-----------------------

function ProFi:shouldReturn( )
	return self.should_run_once and self.has_finished
end

function ProFi:getFuncReport( funcInfo )
	local title = self:getTitleFromFuncInfo( funcInfo )
	local funcReport = self.reportsByTitle[ title ]
	if not funcReport then
		funcReport = self:createFuncReport( funcInfo )
		self.reportsByTitle[ title ] = funcReport
		table.insert( self.reports, funcReport )
	end
	return funcReport
end

function ProFi:getTitleFromFuncInfo( funcInfo )
	local name        = funcInfo.name or self:findFuncName( funcInfo.func ) or 'anonymous'
	local source      = funcInfo.short_src or 'C_FUNC'
	local linedefined = funcInfo.linedefined or 0
	linedefined = string.format( FORMAT_LINENUM, linedefined )
	return string.format(FORMAT_TITLE, source, name, linedefined)
end

--[[
	Attempt to find the variable name that holds a given function object
	by scanning locals and upvalues up the call stack.
]]
function ProFi:findFuncName( func )
	if not func then return nil end
	-- scan stack frames (start from 4 to skip ProFi internals)
	for level = 4, 10 do
		local info = debug.getinfo( level, 'f' )
		if not info then break end
		-- check locals at this level
		local idx = 1
		while true do
			local ln, lv = debug.getlocal( level, idx )
			if not ln then break end
			if lv == func and ln:sub(1,1) ~= '(' then
				return ln
			end
			idx = idx + 1
		end
		-- check upvalues of the function at this level
		if info.func then
			local uid = 1
			while true do
				local un, uv = debug.getupvalue( info.func, uid )
				if not un then break end
				if uv == func then
					return un
				end
				uid = uid + 1
			end
		end
	end
	return nil
end

function ProFi:createFuncReport( funcInfo )
	local name = funcInfo.name or 'anonymous'
	local source = funcInfo.source or 'C Func'
	local linedefined = funcInfo.linedefined or 0
	local funcReport = {
		['title']         = self:getTitleFromFuncInfo( funcInfo );
		['count'] = 0;
		['timer']         = 0;
	}
	return funcReport
end

function ProFi:startHooks()
	debug.sethook( onDebugHook, 'cr', self.hookCount )
end

function ProFi:stopHooks()
	debug.sethook()
end

function ProFi:startSamplingHook()
	-- 主线程设置采样钩子
	debug.sethook( onSamplingHook, '', self.sampleInterval )

	-- 协程采样支持：拦截 coroutine.create/wrap，自动对新协程设置采样钩子
	-- 使用弱引用表追踪协程，避免阻止GC回收
	self._hookedCoroutines = setmetatable({}, { __mode = 'k' })

	-- 保存原始协程函数到 ProFi 表上（跨热更持久化）
	if not self._rawCoroutineCreate then
		self._rawCoroutineCreate = coroutine.create
	end
	if not self._rawCoroutineWrap then
		self._rawCoroutineWrap = coroutine.wrap
	end

	local rawCreate = self._rawCoroutineCreate
	local rawWrap   = self._rawCoroutineWrap
	local interval  = self.sampleInterval
	local hookedCos = self._hookedCoroutines

	-- 替换 coroutine.create：创建协程后立即设置采样钩子
	coroutine.create = function( f )
		local co = rawCreate( f )
		debug.sethook( co, onSamplingHook, '', interval )
		hookedCos[co] = true
		return co
	end

	-- 替换 coroutine.wrap：内部创建的协程也设置采样钩子
	coroutine.wrap = function( f )
		local co = rawCreate( f )
		debug.sethook( co, onSamplingHook, '', interval )
		hookedCos[co] = true
		-- 模拟 coroutine.wrap 行为：返回一个 resume 函数
		return function( ... )
			local results = { coroutine.resume( co, ... ) }
			if not results[1] then
				error( results[2], 2 )
			end
			return table.unpack( results, 2 )
		end
	end
end

function ProFi:stopSamplingHook()
	-- 清除主线程钩子
	debug.sethook()

	-- 清除所有被追踪协程的钩子
	if self._hookedCoroutines then
		for co in pairs( self._hookedCoroutines ) do
			-- 仅对存活的协程清除钩子（dead状态的协程不需要处理）
			local status = coroutine.status( co )
			if status ~= 'dead' then
				debug.sethook( co, nil, '', 0 )
			end
		end
		self._hookedCoroutines = nil
	end

	-- 恢复原始 coroutine.create/wrap
	if self._rawCoroutineCreate then
		coroutine.create = self._rawCoroutineCreate
		self._rawCoroutineCreate = nil
	end
	if self._rawCoroutineWrap then
		coroutine.wrap = self._rawCoroutineWrap
		self._rawCoroutineWrap = nil
	end
end

--[[
	记录一次采样命中，通过 source+name+linedefined 唯一标识函数。
	针对最小开销进行了优化:
	  - 使用简单的字符串key做哈希查找
	  - 避免不必要的字符串格式化
	  - 每次采样不调用 getTime 计时
]]
function ProFi:recordSample( source, name, linedefined )
	local key = source .. ':' .. (name or '') .. ':' .. linedefined
	local report = self.samplingReportsByKey[key]
	if not report then
		local lineStr = string.format( FORMAT_LINENUM, linedefined )
		report = {
			['title']   = string.format(FORMAT_TITLE, source, name or 'anonymous', lineStr);
			['samples'] = 0;
			['source']  = source;
			['name']    = name or 'anonymous';
			['linedefined'] = linedefined;
		}
		self.samplingReportsByKey[key] = report
		self.samplingReports[#self.samplingReports + 1] = report
	end
	report.samples = report.samples + 1
end

function ProFi:sortReportsWithSortMethod( reports, sortMethod )
	if reports then
		table.sort( reports, sortMethod )
	end
end

function ProFi:writeReportsToFilename( filename )
	local file, err = io.open( filename, 'w' )
	assert( file, err )
	self:writeBannerToFile( file )
	if self.profilingMode == 'sampling' then
		if self.samplingReports and #self.samplingReports > 0 then
			self:writeSamplingReportsToFile( self.samplingReports, file )
		end
		if self.callStackReports and #self.callStackReports > 0 then
			self:writeCallStackReportsToFile( self.callStackReports, file )
		end
	else
		if #self.reports > 0 then
			self:writeProfilingReportsToFile( self.reports, file )
		end
	end
	if #self.memoryReports > 0 then
		self:writeMemoryReportsToFile( self.memoryReports, file )
	end
	file:close()
end

function ProFi:writeProfilingReportsToFile( reports, file )
	local totalTime = self.stopTime - self.startTime
	local totalTimeOutput =  string.format(FORMAT_TOTALTIME_LINE, totalTime)
	file:write( totalTimeOutput )
	local header = string.format( FORMAT_HEADER_LINE, "FILE", "FUNCTION", "LINE", "TIME", "RELATIVE", "CALLED" )
	file:write( header )
 	for i, funcReport in ipairs( reports ) do
		local timer         = string.format(FORMAT_TIME, funcReport.timer)
		local count         = string.format(FORMAT_COUNT, funcReport.count)
		local relTime 		= string.format(FORMAT_RELATIVE, (funcReport.timer / totalTime) * 100 )
		local outputLine    = string.format(FORMAT_OUTPUT_LINE, funcReport.title, timer, relTime, count )
		file:write( outputLine )
		if funcReport.inspections then
			self:writeInpsectionsToFile( funcReport.inspections, file )
		end
	end
end

function ProFi:writeSamplingReportsToFile( reports, file )
	local totalTime = self.stopTime - self.startTime
	local totalTimeOutput = string.format(FORMAT_TOTALTIME_LINE, totalTime)
	file:write( totalTimeOutput )
	local samplesLine = string.format(FORMAT_TOTALSAMPLES_LINE, self.totalSamples, self.sampleInterval)
	file:write( samplesLine )
	local header = string.format( FORMAT_SAMPLING_HEADER, "FILE", "FUNCTION", "LINE", "SAMPLES", "RELATIVE" )
	file:write( header )
	for i, report in ipairs( reports ) do
		local samples   = string.format(FORMAT_COUNT, report.samples)
		local relTime   = string.format(FORMAT_RELATIVE, (report.samples / self.totalSamples) * 100)
		local outputLine = string.format(FORMAT_SAMPLING_LINE, report.title, samples, relTime)
		file:write( outputLine )
	end
end

--[[
	输出 CallStack 聚合报告：按采样命中次数降序排列的 Top N 完整调用栈。
	每条记录展示一个完整的调用栈及其被采样命中的次数和百分比。
	栈帧从栈顶（当前执行函数）到栈底（最外层调用者）排列。
]]
function ProFi:writeCallStackReportsToFile( reports, file, topN )
	topN = topN or DEFAULT_TOP_CALLSTACKS
	table.sort( reports, sortBySampleCount )
	local count = math.min( topN, #reports )
	file:write( string.format("\n=== TOP %d CALL STACKS (共 %d 种不同调用栈) =============================\n", count, #reports) )
	for i = 1, count do
		local csReport = reports[i]
		local relPct = string.format( FORMAT_RELATIVE, (csReport.samples / self.totalSamples) * 100 )
		file:write( string.format("--- Stack #%d: %d samples (%s) ---\n", i, csReport.samples, relPct) )
		-- 输出栈帧：从栈顶到栈底，使用缩进显示调用层级
		local frames = csReport.frames
		for j = 1, #frames do
			local f = frames[j]
			local indent = string.rep('  ', j - 1)
			file:write( string.format("%s%s:%d (%s)\n", indent, f.source, f.linedefined, f.name) )
		end
		file:write('\n')
	end
	file:write( "=======================================================================\n\n" )
end

function ProFi:writeMemoryReportsToFile( reports, file )
	file:write( FORMAT_MEMORY_HEADER1 )
	self:writeHighestMemoryReportToFile( file )
	self:writeLowestMemoryReportToFile( file )
	file:write( FORMAT_MEMORY_HEADER2 )
	for i, memoryReport in ipairs( reports ) do
		local outputLine = self:formatMemoryReportWithFormatter( memoryReport, FORMAT_MEMORY_LINE )
		file:write( outputLine )
	end
end

function ProFi:writeHighestMemoryReportToFile( file )
	local memoryReport = self.highestMemoryReport
	local outputLine   = self:formatMemoryReportWithFormatter( memoryReport, FORMAT_HIGH_MEMORY_LINE )
	file:write( outputLine )
end

function ProFi:writeLowestMemoryReportToFile( file )
	local memoryReport = self.lowestMemoryReport
	local outputLine   = self:formatMemoryReportWithFormatter( memoryReport, FORMAT_LOW_MEMORY_LINE )
	file:write( outputLine )
end

function ProFi:formatMemoryReportWithFormatter( memoryReport, formatter )
	local time       = string.format(FORMAT_TIME, memoryReport.time)
	local kbytes     = string.format(FORMAT_KBYTES, memoryReport.memory)
	local mbytes     = string.format(FORMAT_MBYTES, memoryReport.memory/1024)
	local outputLine = string.format(formatter, time, kbytes, mbytes, memoryReport.note)
	return outputLine
end

function ProFi:writeBannerToFile( file )
	local banner = string.format(FORMAT_BANNER, os.date())
	file:write( banner )
end

function ProFi:writeInpsectionsToFile( inspections, file )
	local inspectionsList = self:sortInspectionsIntoList( inspections )
	file:write('\n==^ INSPECT ^======================================================================================================== COUNT ===\n')
	for i, inspection in ipairs( inspectionsList ) do
		local line 			= string.format(FORMAT_LINENUM, inspection.line)
		local title 		= string.format(FORMAT_TITLE, inspection.source, inspection.name, line)
		local count 		= string.format(FORMAT_COUNT, inspection.count)
		local outputLine    = string.format(FORMAT_INSPECTION_LINE, title, count )
		file:write( outputLine )
	end
	file:write('===============================================================================================================================\n\n')
end

function ProFi:sortInspectionsIntoList( inspections )
	local inspectionsList = {}
	for k, inspection in pairs(inspections) do
		inspectionsList[#inspectionsList+1] = inspection
	end
	table.sort( inspectionsList, sortByCallCount )
	return inspectionsList
end

function ProFi:resetReports( reports )
	for i, report in ipairs( reports ) do
		report.timer = 0
		report.count = 0
		report.inspections = nil
	end
end

function ProFi:shouldInspect( funcInfo )
	return self.inspect and self.inspect.methodName == funcInfo.name
end

function ProFi:getInspectionsFromReport( funcReport )
	local inspections = funcReport.inspections
	if not inspections then
		inspections = {}
		funcReport.inspections = inspections
	end
	return inspections
end

function ProFi:getInspectionWithKeyFromInspections( key, inspections )
	local inspection = inspections[key]
	if not inspection then
		inspection = {
			['count']  = 0;
		}
		inspections[key] = inspection
	end
	return inspection
end

function ProFi:doInspection( inspect, funcReport )
	local inspections = self:getInspectionsFromReport( funcReport )
	local levels = 5 + inspect.levels
	local currentLevel = 5
	while currentLevel < levels do
		local funcInfo = debug.getinfo( currentLevel, 'nSlf' )
		if funcInfo then
			local source = funcInfo.short_src or '[C]'
			local name = funcInfo.name or 'anonymous'
			local line = funcInfo.linedefined
			local key = source..name..line
			local inspection = self:getInspectionWithKeyFromInspections( key, inspections )
			inspection.source = source
			inspection.name = name
			inspection.line = line
			inspection.count = inspection.count + 1
			currentLevel = currentLevel + 1
		else
			break
		end
	end
end

function ProFi:onFunctionCall( funcInfo )
	local funcReport = ProFi:getFuncReport( funcInfo )
	funcReport.callTime = getTime()
	funcReport.count = funcReport.count + 1
	if self:shouldInspect( funcInfo ) then
		self:doInspection( self.inspect, funcReport )
	end
end

function ProFi:onFunctionReturn( funcInfo )
	local funcReport = ProFi:getFuncReport( funcInfo )
	if funcReport.callTime then
		funcReport.timer = funcReport.timer + (getTime() - funcReport.callTime)
	end
end

function ProFi:setHighestMemoryReport( memoryReport )
	if not self.highestMemoryReport then
		self.highestMemoryReport = memoryReport
	else
		if memoryReport.memory > self.highestMemoryReport.memory then
			self.highestMemoryReport = memoryReport
		end
	end
end

function ProFi:setLowestMemoryReport( memoryReport )
	if not self.lowestMemoryReport then
		self.lowestMemoryReport = memoryReport
	else
		if memoryReport.memory < self.lowestMemoryReport.memory then
			self.lowestMemoryReport = memoryReport
		end
	end
end

-----------------------
-- Local Functions (每次加载时重新赋值，热更后新代码立即生效):
-----------------------

getTime = os.clock

--[[
	精确模式钩子（原有）：每次函数调用/返回都触发。
]]
onDebugHook = function( hookType )
	local funcInfo = debug.getinfo( 2, 'nSlf' )
	if hookType == "call" then
		ProFi:onFunctionCall( funcInfo )
	elseif hookType == "return" then
		ProFi:onFunctionReturn( funcInfo )
	end
end

--[[
	采样模式钩子：每隔N条VM指令触发一次。
	遍历当前调用栈，记录正在执行的函数。
	针对最小开销进行了优化:
	  - 仅使用 'Sn' 标志（获取源文件+函数名，不获取函数对象）
	  - 使用简单字符串拼接作为key
	  - 每次采样不调用计时函数，不扫描 findFuncName
	  - 通过 maxStackDepth 限制栈遍历深度
]]
onSamplingHook = function()
	local maxDepth = ProFi.maxStackDepth
	ProFi.totalSamples = ProFi.totalSamples + 1
	-- 从第2层开始遍历调用栈（跳过本钩子函数）
	-- 使用 'Sn' 标志: S = source/short_src/linedefined, n = name/namewhat
	local level = 2
	local seen = {}  -- 避免同一次采样中重复计数同一函数（递归去重）
	local stackKeys = {}  -- CallStack 聚合用：收集每层的 key
	local stackFrames = {}  -- CallStack 聚合用：收集每层的描述信息
	local frameCount = 0
	while level < maxDepth + 2 do
		local info = debug.getinfo( level, 'Sn' )
		if not info then break end
		local source = info.short_src or '[C]'
		local name = info.name or 'anonymous'
		local linedefined = info.linedefined or 0
		-- 去重：递归函数在同一次采样中只计数一次（flat 统计用）
		local key = source .. ':' .. name .. ':' .. linedefined
		if not seen[key] then
			seen[key] = true
			ProFi:recordSample( source, name, linedefined )
		end
		-- CallStack 聚合：每层都记录（包含递归，保留完整栈形态）
		frameCount = frameCount + 1
		stackKeys[frameCount] = key
		stackFrames[frameCount] = { source = source, name = name, linedefined = linedefined }
		level = level + 1
	end
	-- CallStack 聚合：将完整调用栈作为一个整体记录
	if frameCount > 0 then
		local callStackKey = table.concat( stackKeys, '|' )
		local csReports = ProFi.callStackReportsByKey
		local csReport = csReports[callStackKey]
		if not csReport then
			csReport = {
				['key']     = callStackKey;
				['frames']  = stackFrames;
				['samples'] = 0;
			}
			csReports[callStackKey] = csReport
			local csList = ProFi.callStackReports
			csList[#csList + 1] = csReport
		end
		csReport.samples = csReport.samples + 1
	end
end

sortByDurationDesc = function( a, b )
	return a.timer > b.timer
end

sortByCallCount = function( a, b )
	return a.count > b.count
end

sortBySampleCount = function( a, b )
	return a.samples > b.samples
end

-----------------------
-- 初始化（仅首次加载时执行 reset，热更时保留运行状态）:
-----------------------

if not ProFi._initialized then
	ProFi:reset()
	ProFi._initialized = true
end

return ProFi
