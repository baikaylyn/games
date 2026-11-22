#!/bin/bash
# 虐杀原形 · wow64cpu 崩溃缓解方案对照实验
#
# 背景：崩溃点在 wow64cpu.dll（Wine 的 32↔64 位模式切换层，基址 0x7BF20000，
# 偏移 0x1239 / 0x1135），Wine 官方判为 Rosetta 2 的问题（NOTOURBUG）。
# 同一崩溃的报告里给出两条实测有效的缓解：
#   1) 提高宿主栈上限  sh -c 'ulimit -s 65520; exec wine ...'
#   2) 启动前先跑一个 32 位 cmd.exe 热身（让 WoW64 的每进程初始化先完成一次）
#
# 用法：bash soak2.sh            # 跑完整四组
#       N=8 WAIT=30 bash soak2.sh
set -u

N="${N:-8}"
WAIT="${WAIT:-30}"
APP="$HOME/Games/Prototype/Prototype.app"
WINE="$APP/Contents/Resources/Wine/bin/wine"
WS="$APP/Contents/Resources/Wine/bin/wineserver"
GAME="$APP/Contents/Resources/Game"
export WINEPREFIX="$HOME/Library/Application Support/MacNativeGames/PROTOTYPE/prefix"
export WINEDEBUG="err+all,fps"
export WINE_CPU_TOPOLOGY="4:0,1,2,3"
export WINEDLLOVERRIDES="d3d9=b;winevulkan=d"

OUT="$HOME/Library/Logs/prototype-crashfix-$(date +%H%M%S)"
mkdir -p "$OUT"
echo "轮数=$N 每次观察=${WAIT}s  输出=$OUT"

cleanup() {
    "$WS" -k 2>/dev/null; sleep 1
    pkill -9 -f "$APP/Contents/Resources/Wine" 2>/dev/null
    pkill -9 -f "prototypef.exe" 2>/dev/null
    sleep 1
}

# 启动一次；参数 $1=组名 $2=栈上限KB（0=默认） $3=是否热身(1/0)
run_one() {
    local tag="$1" stack="$2" warm="$3" i="$4" log="$5"
    cleanup
    if [ "$warm" = "1" ]; then
        ( cd "$GAME" && "$WINE" cmd /c exit ) >/dev/null 2>&1
    fi
    if [ "$stack" != "0" ]; then
        ( cd "$GAME" && /bin/sh -c "ulimit -s $stack; exec \"$WINE\" explorer \"/desktop=Prototype,1280x720\" \"$GAME/prototypef.exe\"" ) > "$log" 2>&1 &
    else
        ( cd "$GAME" && "$WINE" explorer "/desktop=Prototype,1280x720" "$GAME/prototypef.exe" ) > "$log" 2>&1 &
    fi
    sleep "$WAIT"
    local alive=0
    pgrep -f prototypef.exe >/dev/null 2>&1 && alive=1
    if grep -q "wglSwapBuffers" "$log"; then
        echo "ok"
    elif grep -qE "page fault|starting debugger" "$log"; then
        echo "crash"
    elif grep -q "not in stack limits" "$log"; then
        echo "unwind"
    elif [ "$alive" = "1" ]; then
        echo "alive-noframe"
    else
        echo "dead"
    fi
}

declare -a NAMES=( "C0-现状" "C1-大栈" "C2-大栈+热身" "C3-只热身" )
declare -a STACKS=( 0 65520 65520 0 )
declare -a WARMS=( 0 0 1 1 )

for g in 0 1 2 3; do
    name="${NAMES[$g]}"; stack="${STACKS[$g]}"; warm="${WARMS[$g]}"
    ok=0; crash=0; other=0
    echo "===== ${name}（栈=${stack} 热身=${warm}）====="
    for i in $(seq 1 "$N"); do
        log="$OUT/${name}-run${i}.log"
        r=$(run_one "$name" "$stack" "$warm" "$i" "$log")
        case "$r" in
            ok)    ok=$((ok+1));;
            crash|unwind) crash=$((crash+1));;
            *)     other=$((other+1));;
        esac
        echo "  $i: $r"
    done
    echo "$name  成功=$ok 崩溃=$crash 其它=$other  共$N" | tee -a "$OUT/summary.txt"
done

cleanup
echo "===== 汇总 ====="
cat "$OUT/summary.txt"
echo "明细：$OUT"
