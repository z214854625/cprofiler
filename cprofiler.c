/* ==========================================================================
 * cprofiler.c — C 层 Lua 采样 Profiler（单文件，零 GC 压力）
 *
 * 功能对齐 ProFi.lua v2.2 采样模式：
 *   - flat 统计：按 source:name:line 聚合采样命中
 *   - CallStack 聚合：按完整调用栈形态聚合
 *   - 协程支持：C 层拦截 coroutine.create / coroutine.wrap（ref 保存恢复）
 *
 * 编译:
 *   Linux:   gcc -O2 -shared -fPIC -o cprofiler.so cprofiler.c -I<lua_include> -llua
 *   macOS:   gcc -O2 -shared -fPIC -o cprofiler.so cprofiler.c -I<lua_include> -llua
 *   Windows: cl /O2 /LD cprofiler.c /I<lua_include> /link lua51.lib /OUT:cprofiler.dll
 *
 * Lua 用法:
 *   local cp = require("cprofiler")
 *   cp.start(5000, 20)
 *   -- ... 业务逻辑 ...
 *   cp.stop()
 *   cp.save("profile.txt")
 *   local data = cp.report()
 *
 * 兼容 Lua 5.1 / LuaJIT / 5.2 / 5.3 / 5.4
 *
 * 修复历史:
 *   v1: 初始版本
 *   v2: 修复 lua_resume 参数适配 Lua 5.4 (CP_RESUME 宏)
 *   v3: 修复 lua_sethook mask=0 → LUA_MASKCOUNT (钩子从未触发的致命 bug)
 *   v4: 修复采样遍历起点 level=1 → level=0 (漏掉正在运行的叶子函数)
 *   v5: 匿名帧 name 兜底 → "func@<linedefined>"
 *       (协程主函数被 resume 直接拉起, 无 Lua 调用指令可反推名字,
 *        info.name==NULL, 之前统一记为 anonymous 无法定位, 现按定义行兜底)
 * ========================================================================== */

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ======================================================================
 * 兼容宏: Lua 5.1 / LuaJIT vs 5.2 / 5.3 / 5.4
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

/* lua_resume 版本适配宏 */
#if LUA_VERSION_NUM < 502
  /* 5.1 / LuaJIT: lua_resume(co, nargs) */
  #define CP_RESUME(co, from, nargs, nres_ptr)  lua_resume(co, nargs)
#elif LUA_VERSION_NUM < 504
  /* 5.2 / 5.3: lua_resume(co, from, nargs) */
  #define CP_RESUME(co, from, nargs, nres_ptr)  lua_resume(co, from, nargs)
#else
  /* 5.4: lua_resume(co, from, nargs, &nres) */
  #define CP_RESUME(co, from, nargs, nres_ptr)  lua_resume(co, from, nargs, nres_ptr)
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
 * 0. 名字兜底: info.name 为空时用 "func@<linedefined>" 定位
 *    (协程主函数 / 匿名闭包被直接 resume 时 lua_getinfo("n") 拿不到名字)
 * ====================================================================== */
static const char *cp_resolve_name(const lua_Debug *info, char *buf, size_t buflen) {
    if (info->name != NULL && info->name[0] != '\0') {
        return info->name;
    }
    /* main chunk 用更直观的标记 */
    if (info->what != NULL && strcmp(info->what, "main") == 0) {
        snprintf(buf, buflen, "main_chunk@%d", info->linedefined);
    } else if (info->what != NULL && strcmp(info->what, "C") == 0) {
        snprintf(buf, buflen, "Cfunc");
    } else {
        snprintf(buf, buflen, "func@%d", info->linedefined);
    }
    return buf;
}

/* ======================================================================
 * 1. FNV-1a 哈希
 * ====================================================================== */
static unsigned int cp_hash(const char *s) {
    unsigned int h = 2166136261u;
    while (*s) {
        h ^= (unsigned char)*s++;
        h *= 16777619u;
    }
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
        if (strcmp(st->flats[h].key, key) == 0)
            return &st->flats[h];
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
        if (strcmp(st->css[h].key, key) == 0)
            return &st->css[h];
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
 *    v4: level 从 0 开始 (0=当前正在运行的函数)
 *    v5: name 用 cp_resolve_name 兜底
 * ====================================================================== */
static void cp_sampling_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    cp_state_t *st = &g_st;
    if (!st->active) return;

    st->total_samples++;

    lua_Debug info;
    char func_key[CP_KEY_LEN];
    char stack_key[CP_STACK_KEY_LEN];
    char namebuf[CP_NAME_LEN];
    int  stack_len = 0;

    char seen_keys[CP_MAX_STACK_DEPTH][CP_KEY_LEN];
    int  seen_count = 0;

    for (int level = 0; level <= st->max_depth; level++) {
        if (lua_getstack(L, level, &info) == 0)
            break;

        if (lua_getinfo(L, "Sn", &info) == 0)
            continue;

        const char *source = (info.short_src[0] != '\0') ? info.short_src : "[C]";
        const char *name   = cp_resolve_name(&info, namebuf, sizeof(namebuf));
        int line = info.linedefined;

        /* --- 1. flat 统计 --- */
        snprintf(func_key, CP_KEY_LEN, "%s:%s:%d", source, name, line);

        int already_seen = 0;
        for (int i = 0; i < seen_count; i++) {
            if (strcmp(seen_keys[i], func_key) == 0) {
                already_seen = 1;
                break;
            }
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

        /* --- 2. CallStack 聚合: 拼接完整栈 key --- */
        int n = snprintf(stack_key + stack_len,
                         CP_STACK_KEY_LEN - stack_len,
                         "%s|", func_key);
        if (n > 0) stack_len += n;
    }

    /* --- 3. CallStack 聚合统计 --- */
    if (stack_len > 0) {
        cp_cs_t *cs = cp_cs_get(st, stack_key);
        if (cs) {
            if (cs->samples == 0) {
                int fc = 0;
                for (int level = 0; level <= st->max_depth && fc < CP_MAX_STACK_DEPTH; level++) {
                    lua_Debug info2;
                    if (lua_getstack(L, level, &info2) == 0) break;
                    if (lua_getinfo(L, "Sn", &info2) == 0) continue;
                    const char *src2 = (info2.short_src[0] != '\0') ? info2.short_src : "[C]";
                    const char *nm2  = cp_resolve_name(&info2, namebuf, sizeof(namebuf));
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
    if (co && g_st.active) {
        lua_sethook(co, cp_sampling_hook, LUA_MASKCOUNT, g_st.sample_interval);
    }
    return 1;
}

static int cp_wrap_resume_fn(lua_State *L) {
    lua_State *co = lua_tothread(L, lua_upvalueindex(1));
    if (!co) {
        return luaL_error(L, "coroutine.wrap: invalid thread upvalue");
    }

    int nargs = lua_gettop(L);
    if (nargs > 0) {
        lua_xmove(L, co, nargs);
    }

    int nres = 0;
    int status = CP_RESUME(co, L, nargs, &nres);

#if LUA_VERSION_NUM >= 504
    /* 5.4: nres 由 lua_resume 填充 */
#else
    /* 5.1~5.3: 手动获取返回值数量 */
    nres = lua_gettop(co);
#endif

    if (nres > 0) {
        lua_xmove(co, L, nres);
    }

    if (status != LUA_OK && status != LUA_YIELD) {
        return lua_error(L);
    }

    return nres;
}

static int cp_wrapped_wrap(lua_State *L) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_st.co_create_ref);
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    lua_State *co = lua_tothread(L, -1);
    if (co && g_st.active) {
        lua_sethook(co, cp_sampling_hook, LUA_MASKCOUNT, g_st.sample_interval);
    }
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
 * 7. 排序辅助 (qsort, 降序)
 * ====================================================================== */
static int cp_flat_cmp(const void *a, const void *b) {
    const cp_flat_t *fa = (const cp_flat_t *)a;
    const cp_flat_t *fb = (const cp_flat_t *)b;
    return fb->samples - fa->samples;
}

static int cp_cs_cmp(const void *a, const void *b) {
    const cp_cs_t *ca = (const cp_cs_t *)a;
    const cp_cs_t *cb = (const cp_cs_t *)b;
    return cb->samples - ca->samples;
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
    if (st->max_depth > CP_MAX_STACK_DEPTH)
        st->max_depth = CP_MAX_STACK_DEPTH;

    /* 修复(v3): 必须用 LUA_MASKCOUNT, 不能用 0 */
    lua_sethook(L, cp_sampling_hook, LUA_MASKCOUNT, st->sample_interval);

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
    fprintf(stderr, "[cprofiler] reset\n");
    return 0;
}

static int cp_report(lua_State *L) {
    cp_state_t *st = &g_st;

    cp_flat_t *farr = NULL;
    if (st->flat_count > 0) {
        farr = (cp_flat_t *)malloc(st->flat_count * sizeof(cp_flat_t));
        int idx = 0;
        for (int i = 0; i < st->flat_cap; i++) {
            if (st->flats[i].used) {
                farr[idx++] = st->flats[i];
            }
        }
        qsort(farr, st->flat_count, sizeof(cp_flat_t), cp_flat_cmp);
    }

    cp_cs_t *carr = NULL;
    if (st->cs_count > 0) {
        carr = (cp_cs_t *)malloc(st->cs_count * sizeof(cp_cs_t));
        int idx = 0;
        for (int i = 0; i < st->cs_cap; i++) {
            if (st->css[i].used) {
                carr[idx++] = st->css[i];
            }
        }
        qsort(carr, st->cs_count, sizeof(cp_cs_t), cp_cs_cmp);
    }

    lua_newtable(L);

    lua_pushinteger(L, st->total_samples);
    lua_setfield(L, -2, "total_samples");

    lua_pushinteger(L, st->sample_interval);
    lua_setfield(L, -2, "interval");

    /* flat 列表 */
    lua_newtable(L);
    for (int i = 0; i < st->flat_count; i++) {
        cp_flat_t *e = &farr[i];
        lua_newtable(L);

        lua_pushstring(L, e->source);
        lua_setfield(L, -2, "source");

        lua_pushstring(L, e->name);
        lua_setfield(L, -2, "name");

        lua_pushinteger(L, e->linedefined);
        lua_setfield(L, -2, "line");

        lua_pushinteger(L, e->samples);
        lua_setfield(L, -2, "samples");

        double pct = st->total_samples > 0
            ? (double)e->samples / st->total_samples * 100.0 : 0.0;
        lua_pushnumber(L, pct);
        lua_setfield(L, -2, "relative");

        lua_pushinteger(L, e->depth);
        lua_setfield(L, -2, "depth");

        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "flat");

    /* callstack 列表 (Top N) */
    lua_newtable(L);
    int cs_n = st->cs_count < CP_TOP_CALLSTACKS ? st->cs_count : CP_TOP_CALLSTACKS;
    for (int i = 0; i < cs_n; i++) {
        cp_cs_t *cs = &carr[i];
        lua_newtable(L);

        lua_pushinteger(L, cs->samples);
        lua_setfield(L, -2, "samples");

        double pct = st->total_samples > 0
            ? (double)cs->samples / st->total_samples * 100.0 : 0.0;
        lua_pushnumber(L, pct);
        lua_setfield(L, -2, "relative");

        lua_newtable(L);
        for (int j = 0; j < cs->frame_count; j++) {
            lua_newtable(L);

            lua_pushstring(L, cs->frame_src[j]);
            lua_setfield(L, -2, "source");

            lua_pushstring(L, cs->frame_name[j]);
            lua_setfield(L, -2, "name");

            lua_pushinteger(L, cs->frame_line[j]);
            lua_setfield(L, -2, "line");

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
        for (int i = 0; i < st->flat_cap; i++) {
            if (st->flats[i].used) farr[idx++] = st->flats[i];
        }
        qsort(farr, st->flat_count, sizeof(cp_flat_t), cp_flat_cmp);
    }

    cp_cs_t *carr = NULL;
    if (st->cs_count > 0) {
        carr = (cp_cs_t *)malloc(st->cs_count * sizeof(cp_cs_t));
        int idx = 0;
        for (int i = 0; i < st->cs_cap; i++) {
            if (st->css[i].used) carr[idx++] = st->css[i];
        }
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
    fprintf(f, "##  cprofiler (C sampling profiler) v5\n");
    fprintf(f, "##################################################################\n\n");

    fprintf(f, "| TOTAL SAMPLES = %d, INTERVAL = %d VM instructions\n\n",
            st->total_samples, st->sample_interval);

    fprintf(f, "=== FLAT PROFILE (sorted by samples desc) ========================\n");
    fprintf(f, "%-50s %-40s %8s %8s %8s\n",
            "SOURCE", "FUNCTION", "LINE", "SAMPLES", "REL%");
    fprintf(f, "-----------------------------------------------------------------\n");
    for (int i = 0; i < st->flat_count; i++) {
        cp_flat_t *e = &farr[i];
        double pct = st->total_samples > 0
            ? (double)e->samples / st->total_samples * 100.0 : 0.0;
        fprintf(f, "%-50s %-40s %8d %8d %7.2f%%\n",
                e->source, e->name, e->linedefined, e->samples, pct);
    }

    int cs_n = st->cs_count < CP_TOP_CALLSTACKS ? st->cs_count : CP_TOP_CALLSTACKS;
    fprintf(f, "\n=== TOP %d CALL STACKS (%d unique stacks) =======================\n",
            cs_n, st->cs_count);
    for (int i = 0; i < cs_n; i++) {
        cp_cs_t *cs = &carr[i];
        double pct = st->total_samples > 0
            ? (double)cs->samples / st->total_samples * 100.0 : 0.0;
        fprintf(f, "\n--- Stack #%d: %d samples (%.2f%%) ---\n",
                i + 1, cs->samples, pct);
        for (int j = 0; j < cs->frame_count; j++) {
            for (int s = 0; s < j; s++) fprintf(f, "  ");
            fprintf(f, "%s:%d (%s)\n",
                    cs->frame_src[j], cs->frame_line[j], cs->frame_name[j]);
        }
    }
    fprintf(f, "\n================================================================\n");

    fclose(f);
    if (farr) free(farr);
    if (carr) free(carr);

    fprintf(stderr, "[cprofiler] report saved to %s\n", path);

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
    if (!g_st.flats) {
        cp_init_state(&g_st);
    }
    luaL_newlib(L, cp_funcs);
    return 1;
}

/* ======================================================================
 * 10. 库卸载时释放内存
 * ====================================================================== */
#if defined(__GNUC__)
__attribute__((destructor))
static void cp_dtor(void) {
    cp_free_state(&g_st);
}
#elif defined(_WIN32)
#include <windows.h>
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID lpReserved) {
    if (reason == DLL_PROCESS_DETACH) {
        cp_free_state(&g_st);
    }
    return TRUE;
}
#endif

/* END OF FILE */