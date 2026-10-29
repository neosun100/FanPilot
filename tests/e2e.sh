#!/usr/bin/env bash
# e2e.sh —— FanPilot 端到端 + 回归测试
#
# 与 install/verify.sh 的分工：
#   verify.sh  = 「装好之后现在是否健康」（状态快照 + 反向断言）
#   e2e.sh     = 「一条完整的用户路径走得通吗」+ **每个修过的 bug 一条回归**
#
# 设计原则：
#   · 每条回归测试都注明它守的是**哪个真实发生过的 bug**，否则没人知道能不能删
#   · 判**当前事实**（回读），不判「我执行了命令」
#   · 会改真实配置，结束时**无条件恢复**（trap）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="/usr/local/etc/fanpilot/fanpilot.conf"
STATUS="/var/run/fanpilot.status.json"
BIN="/usr/local/sbin/fanpilotd"
FANCTL="${ROOT}/src/fanctl"
APPBIN="${ROOT}/app/.build/release/FanPilotMenu"

PASS=0; FAIL=0; SKIP=0
ok(){   printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
skip(){ printf '  ⏭  %s\n' "$1"; SKIP=$((SKIP+1)); }
grp(){  printf '\n── %s\n' "$1"; }

# ⚠️ 代码级判据必须**排除注释行**，否则会命中「解释这个 bug 的注释」而误报。
#    本项目已被这条咬过：R3 与 R9 初版都在匹配自己写的注释（NewMac cpu-limiter 坑7 同款）。
# 剥 shell 注释（# 开头）
nocomment_sh(){ sed 's/[[:space:]]*#.*$//' "$1"; }
# 剥 Swift 注释（// 与 /// 开头的整行）
nocomment_swift(){ sed 's|^[[:space:]]*///*.*$||' "$1"; }

[ "$(id -u)" = "0" ] || { echo "需要 root：sudo $0" >&2; exit 2; }

# 控制台用户：写配置后要把属主还回去（本脚本以 root 跑）
CONSOLE_USER_G="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || echo root)"

BACKUP="$(mktemp)"
cp "${CONF}" "${BACKUP}" 2>/dev/null || true

# 本脚本派生的所有长驻进程 PID。**必须记，否则被信号打断时它们会变成孤儿。**
SPAWNED=""

# 有界运行：绝不让可能阻塞的守护把测试挂住，并登记 PID 以便清理。
# 🩸 2026-09-14 实测代价：R4 裸启动一个守护 ⇒ e2e 挂死 ⇒ pkill 脚本后守护孤儿化，
#    在后台写了 6 小时 SMC。
run_bounded(){
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! i=0
  SPAWNED="${SPAWNED} ${pid}"
  while kill -0 "${pid}" 2>/dev/null; do
    i=$((i+1))
    if [ "${i}" -gt $(( secs * 10 )) ]; then
      kill -TERM "${pid}" 2>/dev/null; sleep 1; kill -KILL "${pid}" 2>/dev/null
      return 124                                   # 124 = 超时（与 GNU timeout 一致）
    fi
    sleep 0.1
  done
  wait "${pid}" 2>/dev/null; return $?
}

restore(){
  # 🔴 顺序：**先杀派生进程，再恢复配置**。反了的话野守护会读到恢复后的配置继续写 SMC。
  for p in ${SPAWNED}; do kill -TERM "${p}" 2>/dev/null; done
  sleep 1
  for p in ${SPAWNED}; do kill -KILL "${p}" 2>/dev/null; done
  # 兜底扫描：PID 登记可能遗漏（例如派生后、登记前脚本就被打断）。
  # 判据用**命令行特征**（--status /tmp/e2e-），绝不会误杀 launchd 管的真守护。
  pkill -f 'fanpilotd .*--status /tmp/e2e-' 2>/dev/null || true

  if [ -s "${BACKUP}" ]; then
    cp "${BACKUP}" "${CONF}"
    chown "${CONSOLE_USER_G}" "${CONF}" 2>/dev/null || true   # 同上：别留下 root 属主
    sleep 12     # cp 是原地写（不触发目录事件）⇒ 靠下一次巡检的 stat 兜底，≤ check_interval
  fi
  rm -f "${BACKUP}" /tmp/e2e-*.conf /tmp/e2e-*.json /tmp/e2e-*.png
}
# 🔴 必须包含 INT/TERM：只写 EXIT 的话，`pkill` 发来的 SIGTERM 会直接干掉 shell，
#    EXIT trap 根本不执行 ⇒ 子进程全部孤儿化。这正是 2026-09-14 事故的第三层原因。
trap restore EXIT INT TERM

# 读状态文件里的一个数字字段（不解析配置文件 —— 那份带人写的注释）
stat_num(){ sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9.-]*\).*/\1/p" "${STATUS}" | head -1; }
# 读字符串字段（如 fan_mode / temp_source）。同样只读**机器写的** JSON，不碰配置文件
stat_str(){ sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${STATUS}" | head -1; }
# 写配置里一个 key（原子写，模拟菜单栏 App 的行为）
set_key(){
  local k="$1" v="$2" tmp="${CONF}.e2etmp"
  awk -v k="$k" -v v="$v" '
    { line=$0; t=$0; gsub(/^[ \t]+/,"",t)
      if (index(t,k)==1 && index(t,"=")>0 && !done) {
        c=""; if (index(line,"#")>0) c="    " substr(line,index(line,"#"))
        print k " = " v c; done=1
      } else print line }
    END { if (!done) print k " = " v }' "${CONF}" > "${tmp}"
  mv "${tmp}" "${CONF}"
  # 🩸 本脚本以 root 运行，临时文件由 root 创建，mv 之后配置属主会变成 root
  #    ⇒ 菜单栏 App（无特权）再也写不了它 —— **测试把它所测试的功能弄坏了**。
  #    实测踩过：用户点「转速下限」直接弹 Permission denied，而 verify/e2e 双双通过。
  #    所以每次写完都必须把属主还回控制台用户。
  chown "${CONSOLE_USER_G}" "${CONF}" 2>/dev/null || true
}
wait_reload(){ sleep 2; }   # 守护监视配置目录、即刻重载；2s 足够（1.x 轮询要 7s）

fan_target(){ "${FANCTL}" kv 2>/dev/null | sed -n "s/^fan$1_target=//p" | cut -d. -f1; }
# 某百分比在风扇 f 上的期望目标 —— 镜像 fl_fan_target（四舍五入到 1 RPM，夹硬件范围）
# 🩸 2026-10-28：测试把转速降到 60% ⇒ 本来就热的机器真被测到全核平均 90.2°C、紧急打满，4 条判据误报。
#    ⇒ ① 测试档位一律**高于**使用者的 90%（95/96/94），测试期间风扇只会更快 ② 紧急态下期望值 = 硬件上限
exp_target(){
  local mx mn; mx="$(stat_fan_field "$1" max)"; mn="$(stat_fan_field "$1" min)"
  if [ "$(stat_str mode)" = "emergency" ]; then echo "${mx}"; return; fi
  awk -v p="$2" -v mx="${mx}" -v mn="${mn}" 'BEGIN{t=int(mx*p/100+0.5); if(t<mn)t=mn; if(t>mx)t=mx; print t}'; }
stat_fan_field(){ awk -v f="$1" -v k="\"$2\"" -F'[:,]' '/"id": /{id=$2+0; for(i=1;i<=NF;i++) if($i ~ k"$" || $i ~ " "k) {v=$(i+1)+0}; if(id==f){print v; exit}}' "${STATUS}"; }
fan_md(){     "${FANCTL}" kv 2>/dev/null | sed -n "s/^fan$1_mode=//p"; }
reload_count(){ grep -c '生效配置' /var/log/fanpilotd.log 2>/dev/null || echo 0; }   # 行首现在是时间戳

DAEMON_UP=0
pgrep -x fanpilotd >/dev/null 2>&1 && DAEMON_UP=1

# ═══════════════════════════════════════════════════════════════════
grp "E2E-1 用户路径：从菜单改定速 → 即刻生效（无需 reload、无需密码）"
if [ "${DAEMON_UP}" = "1" ]; then
  set_key percent 95
  wait_reload
  t0="$(fan_target 0)"; t1="$(fan_target 1)"; x0="$(exp_target 0 95)"; x1="$(exp_target 1 95)"
  [ "${t0}" = "${x0}" ] && [ "${t1}" = "${x1}" ] && [ "${t0}" != "${t1}" ] \
    && ok "percent = 95 → 2s 内 SMC 目标 ${t0}/${t1}（两风扇按各自上限折算，即刻生效）" \
    || bad "SMC 目标 ${t0}/${t1}，期望 ${x0}/${x1} —— 自动重载或折算有误"
  [ "$(fan_md 0)$(fan_md 1)" = "11" ] && ok "两风扇手动模式" || bad "风扇未处于手动模式"
else
  skip "真守护未运行，跳过活体用户路径"
fi

# ═══════════════════════════════════════════════════════════════════
grp "回归 R1 —— 配置目录不可写导致改设置静默失败"
# 真实 bug：只 chown 了配置**文件**没 chown 目录，原子写要在同目录建临时文件 ⇒ Permission denied
CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || echo root)"
downer="$(/usr/bin/stat -f '%Su' "$(dirname "${CONF}")" 2>/dev/null)"
[ "${downer}" = "${CONSOLE_USER}" ] && ok "配置**目录**属主是 ${CONSOLE_USER}（原子写可用）" \
                                   || bad "配置目录属主是 ${downer}，App 无法原子写"
sudo -u "${CONSOLE_USER}" test -w "$(dirname "${CONF}")" \
  && ok "控制台用户对配置目录有写权限" || bad "控制台用户不能写配置目录"

grp "回归 R2 —— GNU coreutils 抢占 stat/awk"
# 真实 bug：`stat -f '%Su'` 被 GNU stat 抢占（-f 在 GNU 里是查文件系统），静默返回 fs 信息当用户名
n="$(grep -c "/usr/bin/stat -f" "${ROOT}/install/install.sh" || true)"
[ "${n}" != "0" ] && ok "install.sh 用 /usr/bin/stat 绝对路径（防 GNU 抢占）" \
                  || bad "install.sh 用了裸 stat —— GNU coreutils 会静默返回错值"

grp "回归 R3 —— verify 解析中文输出（BSD awk 非多字节安全）"
# 真实 bug：`$i=="目标"` 对几乎每个字段返回真 ⇒ 2 个风扇被数成 12 个
if [ -x "${FANCTL}" ]; then
  kvn="$("${FANCTL}" kv 2>/dev/null | grep -c '^fan[0-9]*_mode=' || true)"
  [ "${kvn}" = "2" ] && ok "fanctl kv 提供纯 ASCII 机器可读输出（2 个风扇）" \
                     || bad "fanctl kv 输出异常（${kvn} 个风扇）"
  # 剥掉注释后再判：否则会命中「不要解析 fanctl status」这句注释本身
  gz="$(nocomment_sh "${ROOT}/install/verify.sh" | grep -c 'FANCTL}" status' || true)"
  [ "${gz}" = "0" ] && ok "verify.sh 不再解析中文 status 输出（已剥注释后判定）" \
                    || bad "verify.sh 仍在解析中文输出（会被 BSD awk 咬）"
fi

grp "回归 R4 —— 单实例锁（双实例抢写 SMC）"
# 真实 bug：前台实例与 launchd 实例同时跑，各自算曲线抢写同一组寄存器，目标互踩且不报错
#
# 🩸🩸 本测试**自己**造成过一次真事故（2026-09-14），三层都错了，逐层修：
#   ① 前置条件没断言：本测试的语义是「真守护在跑时第二个实例必须被拒」。
#      真守护没跑时 flock 无人占用 ⇒ 这条命令不是"被拒"而是**成为真守护并阻塞**，
#      语义完全翻转 —— 从"验证拒绝"变成"制造一个野守护"。
#   ② 无界运行：它在前台不带超时地跑一个长驻守护 ⇒ 整套 e2e 挂死。
#   ③ 没有子进程清理：我 pkill 掉 e2e.sh 后，它派生的守护被**孤儿化**（PPID=1），
#      在后台写了 6 小时 SMC，与 Macs Fan Control 抢寄存器
#      ⇒ 使用者看到转速在 3300 与 2500 之间来回拉锯，且两边都不报错。
#
# ⭐ 通解：**测试若要启动长驻进程，必须同时满足三条** ——
#    前置条件显式断言 · 有界（用 --oneshot 或超时）· 退出时无条件清理（trap 含信号）。
if ! pgrep -x fanpilotd >/dev/null 2>&1; then
  skip "真守护未运行 ⇒ 本测试语义不成立（会变成启动野守护），跳过（这不是失败）"
else
  # ⭐ 用 --oneshot 而不是裸启动：它同样在**打开 SMC 之前**争 flock，
  #    所以照样能验证锁；但即使抢到锁也只跑一个周期就退出 ⇒
  #    结构上根本不可能挂死或留下孤儿，而不是靠超时去补救。
  run_bounded 15 "${BIN}" --config "${CONF}" --status /tmp/e2e-dup.json --oneshot
  rc=$?
  [ "${rc}" = "4" ] && ok "第二个实例被 flock 拒绝（退出码 4）" \
                    || bad "第二个实例未被拒（退出码 ${rc}）—— 会抢写 SMC"
  [ "$(pgrep -x fanpilotd | grep -c .)" = "1" ] && ok "实例数恒为 1" || bad "存在多个实例"
fi

grp "回归 R5 —— 安全阈值被配置绕过"
# 真实 bug（1.x）：emergency_temp 设 200 ⇒ 紧急保护被整个禁用
EVIL=/tmp/e2e-evil.conf
printf 'emergency_temp = 200\ncheck_interval = 0.01\npercent = 500\n' > "${EVIL}"
e="$("${BIN}" --config "${EVIL}" --check-config 2>/dev/null)"
chk_clamp(){
  local got; got="$(printf '%s\n' "$e" | awk -F= -v k="$1" '$1==k{print $2;exit}')"
  awk -v a="${got:-0}" -v b="$2" 'BEGIN{exit !(a-b<0.01 && b-a<0.01)}' \
    && ok "$1 被夹到 $2" || bad "$1=${got:-读不到}，期望 $2 —— 阈值可被绕过"
}
chk_clamp emergency_temp 95
chk_clamp check_interval 5
chk_clamp percent 100
chk_clamp fan0_effective_target "$(printf '%s\n' "$e" | sed -n 's/^fan0_hw_max=//p')"
chk_clamp fan1_effective_target "$(printf '%s\n' "$e" | sed -n 's/^fan1_hw_max=//p')"

grp "回归 R6 —— --check-config 显示模板而非生效值"
# 真实 bug（1.x）：check-config 在读到硬件范围前就 return ⇒ 看起来能验其实验不到
hw="$(printf '%s\n' "$e" | grep -c '^fan[01]_hw_max=' || true)"
[ "${hw}" = "2" ] && ok "check-config 报告两风扇各自的硬件上限" || bad "check-config 未报告硬件上限"
l0="$(printf '%s\n' "$e" | sed -n 's/^fan0_effective_target=//p')"
l1="$(printf '%s\n' "$e" | sed -n 's/^fan1_effective_target=//p')"
[ -n "${l0}" ] && [ -n "${l1}" ] && [ "${l0}" != "${l1}" ] \
  && ok "超上限时两风扇生效目标不同（${l0} / ${l1}）—— 各自夹到自己的上限" \
  || bad "两风扇生效目标相同（${l0}/${l1}）—— 硬件范围没有逐风扇读取"

grp "回归 R7 —— 菜单栏宽度横跳 / emoji 变黑块 / 靠上对齐"
if [ -x "${APPBIN}" ]; then
  ws=""
  for st in normal emergency fault firmware; do
    out="$("${APPBIN}" --render-preview "/tmp/e2e-${st}.png" "57°C" "2384" "${st}" 2>/dev/null)"
    w="$(printf '%s' "${out}" | sed -n 's/.*图像=(\([0-9.]*\),.*/\1/p')"
    ws="${ws} ${w}"
  done
  uniqn="$(printf '%s\n' ${ws} | sort -u | grep -c . || true)"
  [ "${uniqn}" = "1" ] && ok "4 种状态菜单栏宽度一致（${ws} ）—— 不横跳" \
                       || bad "宽度不一致（${ws} ）—— 菜单栏会横跳"
  # 宽度不得回退到过去的臃肿值（34/38pt）
  w1="$(printf '%s\n' ${ws} | head -1)"
  # 上限 26 → 46：2026-10-28 使用者三次调整 —— 温度写全「°C」、转速在上温度在下、温度放大到 13pt
  #   （「上下左右空间还比较宽裕」）。46 = 现值 42 + 余量，防止无意中继续变宽
  awk -v w="${w1}" 'BEGIN{exit !(w<=46)}' && ok "宽度 ${w1}pt ≤ 46pt（使用者认可的 13pt 温度版）" \
                                          || bad "宽度 ${w1}pt 过宽，挤占菜单栏"
  # 🩸 状态标记不得与数字重叠（实测踩过：4 位转速占满全宽时，
  #    画在左侧空隙的标记直接压在数字上，数字读不出来）。
  #    判据：用**最宽内容**渲染紧急态，检查文字墨迹与贴底标记条之间必须有空行。
  "${APPBIN}" --render-preview /tmp/e2e-collide.png "100°C" "5777" emergency >/dev/null 2>&1
  if [ -f /tmp/e2e-collide.png ] && command -v uv >/dev/null 2>&1; then
    gap="$(uv run --with pillow --no-project python -c "
from PIL import Image
im=Image.open('/tmp/e2e-collide.png').convert('L'); W,H=im.size; px=im.load()
# 只看文字区（跳过左侧）与整宽区，找出有墨迹的行
rows=[y for y in range(H) if sum(1 for x in range(W) if px[x,y]<128) > 0]
if not rows: print(-1); raise SystemExit
# 贴底标记条 = 最底部连续的整宽墨迹带；文字在其上方
bot=max(rows)
band=bot
while band-1 in rows: band-=1
text=[y for y in rows if y < band]
print((band-max(text)-1) if text else -1)
" 2>/dev/null)"
    if [ "${gap:-0}" -ge 1 ] 2>/dev/null; then
      ok "状态标记与数字之间有 ${gap}px 空隙（最宽内容 100°/5777 下不重叠）"
    else
      bad "状态标记与数字重叠（间隙 ${gap:-?}）" "4 位转速时标记会压在数字上"
    fi
  fi

  # emoji 不得出现在菜单栏渲染路径（模板模式会变纯黑块）
  em="$(grep -cE 'setTitle\([^)]*[🔥⚠️]' "${ROOT}/app/Sources/FanPilotMenu/main.swift" || true)"
  [ "${em}" = "0" ] && ok "菜单栏渲染路径无 emoji（模板模式下会变黑块）" \
                    || bad "菜单栏又出现 emoji —— 模板着色会变纯黑块"
else
  skip "App 未编译，跳过菜单栏回归（cd app && swift build -c release）"
fi

grp "回归 R8 —— 菜单打开时内容冻结"
# 真实 bug：Timer 默认只加到 .default 模式，菜单打开时进入 NSEventTrackingRunLoopMode
#          ⇒ timer 不触发，菜单里的数字冻在打开那一刻
n="$(grep -c 'forMode: .common' "${ROOT}/app/Sources/FanPilotMenu/main.swift" || true)"
[ "${n}" != "0" ] && ok "刷新 Timer 加在 .common 模式（菜单打开时仍更新）" \
                  || bad "Timer 未加 .common —— 菜单打开时内容会冻结"
n2="$(grep -c 'func menuWillOpen' "${ROOT}/app/Sources/FanPilotMenu/main.swift" || true)"
[ "${n2}" != "0" ] && ok "实现 menuWillOpen（打开瞬间先刷一次）" || bad "缺 menuWillOpen"

grp "回归 R10 —— 逻辑在两处重复（守护与 fanlogic.h 分叉）"
for fn in fl_cfg_load fl_fan_target fl_emergency_step fl_needs_rewrite fl_is_external_change fl_bucket_take fl_fight_note fl_should_take_over fl_is_core_temp_key; do
  n="$(grep -c "${fn}" "${ROOT}/src/fanpilotd.c" || true)"
  [ "${n}" != "0" ] && ok "守护使用 ${fn}（单一来源 fanlogic.h）" \
                    || bad "守护未使用 ${fn}（逻辑可能又复制了一份）"
done
dup="$(grep -cE '^static (void|int) (cfg_load|parse_curve|parse_src)\(' "${ROOT}/src/fanpilotd.c" || true)"
[ "${dup}" = "0" ] && ok "守护内无重复的配置解析实现" || bad "守护内仍有重复实现 —— 必然分叉"

grp "回归 R11 —— 菜单槽位错位（骨架槽位数 ≠ set() 调用数）"
# 真实 bug（2026-09-14）：只加了 set() 没加骨架槽位 ⇒ 菜单整体串一格、最后一行被静默丢弃
if [ -x "${APPBIN}" ]; then
  if dm="$("${APPBIN}" --dump-menu 2>&1)"; then
    ok "--dump-menu 槽位契约成立（$(printf '%s' "${dm}" | sed -n 's/^槽位 \(.*\)$/\1/p')）"
  else
    bad "--dump-menu 报告槽位不匹配：$(printf '%s' "${dm}" | tail -1)"
  fi
  if [ "${DAEMON_UP}" = "1" ]; then
    for L in 最高核心 全核平均 固定转速 自定义百分比; do
      [ "$(printf '%s\n' "${dm}" | grep -c "${L}" || true)" != "0" ] \
        && ok "菜单含「${L}」" || bad "菜单缺「${L}」"
    done
    ne="$(printf '%s\n' "${dm}" | grep -c '紧急判据 ≥' || true)"
    [ "${ne}" = "1" ] && ok "恰好一行温度被标为「紧急判据」，且带阈值" \
                      || bad "「紧急判据」标记有 ${ne} 处（应为 1）"
    nchk="$(printf '%s\n' "${dm}" | grep -c '\[✓\]' || true)"
    [ "${nchk}" -le 1 ] && ok "定速档最多一个被勾选（${nchk}）" || bad "多个定速档同时被勾选"
  fi
  # 2.0 删掉的概念不得残留在菜单（翻新不追加）
  left="$(nocomment_swift "${ROOT}/app/Sources/FanPilotMenu/main.swift" | grep -cE '转速下限|温度口径|自适应|曲线输入|平滑后' || true)"
  [ "${left}" = "0" ] && ok "菜单无 1.x 曲线概念残留（已剥注释）" || bad "菜单仍有 ${left} 处曲线概念残留"
else
  skip "菜单栏 App 未构建，跳过 R11"
fi

grp "回归 R12 —— 睡眠时不交还固件（风扇整夜转）"
# 真实 bug（2026-09-14）：合盖 44 分钟，F*md=1 锁存 ⇒ 风扇按 3822 RPM 转了一整夜
# ⭐ 判效果不判接线：--selftest-pm 投喂 WillSleep，回读 SMC 看 F*md 是否真变 0
DBIN="${ROOT}/src/fanpilotd"
if [ -x "${DBIN}" ]; then
  st="$("${DBIN}" --selftest-pm 2>&1)"; rc=$?
  kv(){ printf '%s\n' "${st}" | sed -n "s/^$1=//p"; }
  [ "$(kv pm_registered)" = "1" ] && ok "IORegisterForSystemPower 注册成功" \
                                 || bad "电源通知注册失败 —— 睡眠交接不可能生效"
  a0="$(kv fan0_md_after)"; a1="$(kv fan1_md_after)"
  [ "${a0}" = "0" ] && [ "${a1}" = "0" ] && ok "WillSleep 后两风扇 F*md 真变 0（已交还固件）" \
                                         || bad "WillSleep 后 F*md 仍是 ${a0}/${a1}"
  [ "$(kv darkwake_stays_firmware)" = "1" ] \
    && ok "⭐DarkWake（能力 0x09，无显示）收到「已唤醒」后风扇仍归固件（md=$(kv darkwake_fan0_md)/$(kv darkwake_fan1_md)）" \
    || bad "DarkWake 时风扇被接管 —— 合盖放包里会每小时冲一次定速（本机约每小时一次 DarkWake）"
  [ -n "$(kv system_caps)" ] && [ "$(kv system_caps)" != "-1" ] \
    && ok "读得到系统能力（System Capabilities = $(kv system_caps)）—— 能区分 DarkWake" \
    || bad "读不到系统能力 —— 无法区分 DarkWake，会按完全唤醒接管"
  [ "${rc}" = "0" ] && ok "--selftest-pm pass" || bad "--selftest-pm 失败"
  if [ "${DAEMON_UP}" = "1" ]; then
    # 自愈：自检交还后，在跑的守护下一次巡检（≤10s）必须重新接管
    sleep 12
    [ "$(fan_md 0)" = "1" ] && ok "≤12s 后守护已重新接管（自检不留副作用）" \
                            || bad "守护未重新接管（fan0_mode=$(fan_md 0)）"
  fi
  cnt_c(){ sed -E 's|^[[:space:]]*//.*$||' "${ROOT}/src/fanpilotd.c" | grep -c "$1" || true; }
  [ "$(cnt_c IOAllowPowerChange)" != "0" ] && ok "有 IOAllowPowerChange 应答（不拖慢系统睡眠）" \
                                           || bad "缺 IOAllowPowerChange —— 每次睡眠被拖 30 秒"
  [ "$(cnt_c IOCancelPowerChange)" = "0" ] && ok "⭐反向：绝不 IOCancelPowerChange" \
                                           || bad "出现 IOCancelPowerChange —— 无权否决睡眠"
  # 🩸 2.0 新增：WillSleep 之后、真睡着之前的几秒内，巡检不得把 md 写回 1
  [ "$(cnt_c 'if (g_sleeping)')" != "0" ] && ok "睡前窗口内巡检不重新接管（g_sleeping 闸门）" \
                                          || bad "缺 g_sleeping 闸门 —— 交还后可能又被巡检写回手动"
else
  skip "守护未构建，跳过 R12"
fi

grp "回归 R13 —— 🔴 稳态写 SMC 必须为 0（使用者头号约束：写入风暴曾导致死机）"
if [ "${DAEMON_UP}" = "1" ]; then
  # 🩸 2026-10-28：使用者在测试中途从菜单改了档（窗口内出现一次「生效配置 90%」重载）⇒ 2 次写入被误判为失败。
  #    窗口内若发生配置重载 = 外部操作干扰，重测一次（最多 2 次），不把人的操作算成守护的错。
  for attempt in 1 2; do
    r1="$(reload_count)"; w1="$(stat_num writes_total)"; ts1="$(stat_num ts)"; sleep 35
    w2="$(stat_num writes_total)"; ts2="$(stat_num ts)"; r2="$(reload_count)"
    [ "${r2}" = "${r1}" ] && break
    printf '  ↻ 窗口内发生 %s 次配置重载（外部操作），重测\n' "$(( r2 - r1 ))"
  done
  d=$(( ${w2:-0} - ${w1:-0} ))
  [ "${d}" = "0" ] && ok "⭐稳态 35 秒（≥3 次巡检）写 SMC ${d} 次" \
                   || bad "稳态 35 秒写 SMC ${d} 次 —— 定速必须写一次就不再动"
  [ "${ts2:-0}" -gt "${ts1:-0}" ] && ok "⭐反向：同一窗口内巡检仍在进行（ts ${ts1}→${ts2}）—— 0 次不是卡死" \
                                  || bad "ts 未前进 —— 上面的 0 次可能是守护卡死的假绿"
else
  skip "真守护未运行，跳过 R13"
fi

grp "回归 R15 —— 配置目录噪音触发重载风暴（2026-10-28 开发中实测 23s 4074 次）"
# 真实 bug：配置与状态文件同在 /tmp ⇒ 写状态 → 目录事件 → 重载 → 写状态 … 自触发
# ⭐ 判据：往配置目录里狂造 50 次与配置无关的变化，重载次数必须不变
if [ "${DAEMON_UP}" = "1" ]; then
  r1="$(reload_count)"; w1="$(stat_num writes_total)"
  for i in $(seq 50); do : > "$(dirname "${CONF}")/.e2e-noise-${i}"; rm -f "$(dirname "${CONF}")/.e2e-noise-${i}"; done
  sleep 2
  r2="$(reload_count)"; w2="$(stat_num writes_total)"
  [ "${r2}" = "${r1}" ] && ok "⭐目录噪音 100 次事件 → 重载 0 次（只认配置文件身份变化）" \
                        || bad "目录噪音触发了 $(( r2 - r1 )) 次重载 —— 重载风暴回归"
  [ "${w2}" = "${w1}" ] && ok "目录噪音期间写 SMC 0 次" || bad "目录噪音期间写了 SMC $(( w2 - w1 )) 次"
  # 反向对照：真改配置必须恰好触发重载（否则上面的 0 可能是监视失效的假绿）
  set_key percent 96; wait_reload
  r3="$(reload_count)"
  [ "${r3}" -gt "${r2}" ] && ok "⭐反向：真改配置触发了重载（$(( r3 - r2 )) 次）—— 监视没失效" \
                          || bad "真改配置也没重载 —— 目录监视失效"
  # 🩸「重载了」是代理量：初版这条绿着，而 SMC 目标根本没变（容差吃掉了 50 RPM 的改动）
  [ "$(fan_target 0)" = "$(exp_target 0 96)" ] && ok "⭐SMC 目标真的变成 $(exp_target 0 96)（判硬件事实，不判「重载了」）" \
                                 || bad "重载了但 SMC 目标是 $(fan_target 0)，不是 $(exp_target 0 96)"
  e_before="$(stat_num external_overrides)"
  # 原地写（不改目录项）：只能靠巡检时的 stat 兜底 —— 必须在一个巡检周期内生效
  sed 's/^percent = .*/percent = 94/' "${CONF}" > /tmp/e2e-inplace.conf && cat /tmp/e2e-inplace.conf > "${CONF}"
  sleep 12
  [ "$(fan_target 0)" = "$(exp_target 0 94)" ] && ok "原地写配置（cp/nano 式）在一个巡检周期内生效" \
                                 || bad "原地写配置 12s 后仍未生效（目标 $(fan_target 0)）"
  [ "$(stat_num external_overrides)" = "${e_before}" ] \
    && ok "[回归] 使用者原地改配置**不**被算成外部抢写（否则 3 次就错误让步）" \
    || bad "原地改配置被算成外部改动（${e_before} → $(stat_num external_overrides)）"
  set_key percent 96; wait_reload
else
  skip "真守护未运行，跳过 R15"
fi

grp "回归 R16 —— 与别的风扇程序抢写（2026-09-14 事故形态：3300↔2500 拉锯）"
# ⭐ 用 fanctl 扮演「别的风扇程序」反复改目标，FanPilot 必须：先纠正、再让步、绝不无限拉锯
if [ "${DAEMON_UP}" = "1" ]; then
  e0="$(stat_num external_overrides)"
  "${FANCTL}" rpm 0 2222 >/dev/null 2>&1
  sleep 12
  [ "$(fan_target 0)" = "$(exp_target 0 96)" ] && ok "外部改动被下一次巡检纠正（2222 → $(exp_target 0 96)）" \
                                 || bad "外部改动未被纠正（目标 $(fan_target 0)）"
  e1="$(stat_num external_overrides)"
  [ "${e1:-0}" -gt "${e0:-0}" ] && ok "外部改动被计数并留痕（${e0}→${e1}）" || bad "外部改动未计数"
  "${FANCTL}" rpm 0 2222 >/dev/null 2>&1; sleep 11
  "${FANCTL}" rpm 0 2222 >/dev/null 2>&1; sleep 11
  m="$(stat_str mode)"
  [ "${m}" = "yielded_external_writer" ] && ok "⭐10 分钟内第 3 次被改 → 让步（mode=${m}），不再拉锯" \
                                         || bad "第 3 次被改后 mode=${m} —— 会无限互相纠正"
  w1="$(stat_num writes_total)"; "${FANCTL}" rpm 0 2333 >/dev/null 2>&1; sleep 11; w2="$(stat_num writes_total)"
  [ "${w2}" = "${w1}" ] && ok "让步期间再被改也写 SMC 0 次" || bad "让步期间仍写了 $(( w2 - w1 )) 次"
  # 使用者显式改设置 = 结束让步
  set_key percent 95; wait_reload
  m="$(stat_str mode)"
  { [ "${m}" = "normal" ] || [ "${m}" = "emergency" ]; } && [ "$(fan_target 0)" = "$(exp_target 0 95)" ] \
    && ok "使用者改设置后立刻结束让步并接管（目标 $(fan_target 0)）" \
    || bad "改设置后仍在让步（mode=$(stat_str mode)）"
else
  skip "真守护未运行，跳过 R16"
fi

grp "回归 R17 —— 菜单栏 App 每次刷新都 fork launchctl（1.x：≈4.3 万次进程/天）"
SW="${ROOT}/app/Sources/FanPilotMenu/main.swift"
calls="$(nocomment_swift "${SW}" | grep -n 'refreshLoginItem()' | grep -vc 'func refreshLoginItem' || true)"
inopen="$(nocomment_swift "${SW}" | awk '/func menuWillOpen/{f=1} f&&/refreshLoginItem\(\)/{c++} f&&/^    }/{f=0} END{print c+0}')"
intoggle="$(nocomment_swift "${SW}" | awk '/func toggleLogin/{f=1} f&&/refreshLoginItem\(\)/{c++} f&&/^    }/{f=0} END{print c+0}')"
[ "${calls}" = "$(( inopen + intoggle ))" ] && [ "${inopen}" = "1" ] \
  && ok "会 fork 子进程的自启查询只在打开菜单/点开关时调用（${calls} 处）" \
  || bad "refreshLoginItem 在别处被调用（共 ${calls}，菜单打开 ${inopen}，开关 ${intoggle}）—— 又会每次刷新 fork"
iv="$(nocomment_swift "${SW}" | sed -n 's/.*Timer(timeInterval: \([0-9.]*\).*/\1/p' | head -1)"
awk -v v="${iv:-0}" 'BEGIN{exit !(v>=10)}' && ok "App 刷新间隔 ${iv}s ≥ 10s（= 守护巡检间隔）" \
                                          || bad "App 刷新间隔 ${iv}s 过短 —— 只是重复读同一份文件"
[ "$(nocomment_swift "${SW}" | grep -c 'guard key != lastTitle')" != "0" ] \
  && ok "菜单栏内容不变时不重绘" || bad "每次刷新都重绘菜单栏图像"
[ "$(nocomment_swift "${SW}" | grep -c 'a.window.level = .floating')" != "0" ] \
  && ok "弹窗先置顶再 runModal（不会藏到窗口后面让菜单「卡死」）" || bad "裸 runModal"

grp "回归 R18 —— 会自己不断重来的那一类（重启风暴 / 重复实例）"
# 🩸 与 R15（23s 4074 次重载）同一类：机制本身没坏，但在某种条件下会无限重复自己
PL=/Library/LaunchDaemons/com.newmac.fanpilotd.plist
ti="$(awk '/<key>ThrottleInterval<\/key>/{getline; gsub(/[^0-9]/,""); print}' "${PL}" 2>/dev/null)"
[ "${ti:-0}" -ge 10 ] && ok "已装 plist 的 ThrottleInterval = ${ti}s（启动持续失败时不会每秒重扫 3669 个 SMC 键）" \
                      || bad "ThrottleInterval = ${ti:-缺失} —— 启动失败时会形成重启风暴（1.x 是 1s）"
APPX=/Applications/FanPilot.app/Contents/MacOS/FanPilot
if [ -x "${APPX}" ] && pgrep -x FanPilot >/dev/null 2>&1 && [ "${CONSOLE_USER_G}" != "root" ]; then
  # 活体：以控制台用户再起一个 App，3 秒后必须只剩一个（「开机自启」开关会触发这种情况）
  sudo -u "${CONSOLE_USER_G}" "${APPX}" >/dev/null 2>&1 &
  SPAWNED="${SPAWNED} $!"
  sleep 3
  n="$(pgrep -x FanPilot | grep -c . || true)"
  [ "${n}" = "1" ] && ok "⭐活体：再启动一个 App 会自动退出（实例数恒为 1）" \
                   || bad "存在 ${n} 个 FanPilot 实例 —— 菜单栏重复图标、资源翻倍"
else
  skip "菜单栏 App 未运行，跳过单实例活体验证"
fi
cnt_c(){ sed -E 's|^[[:space:]]*//.*$||' "${ROOT}/src/fanpilotd.c" | grep -c "$1" || true; }
[ "$(cnt_c 'kCFRunLoopRunFinished')" != "0" ] \
  && ok "主循环处理 run loop 立即返回的情形（不会变成 100% CPU 忙等）" \
  || bad "主循环未处理 kCFRunLoopRunFinished —— 无事件源时会忙等"

grp "回归 R19 —— App 盯 status.json：跟得上、且不会被别的文件唤醒（刷新风暴）"
# 🩸 只盯这一个文件、不盯 /var/run 目录 —— 盯目录会被别的程序反复唤醒（与 R15 同一类）
APPX=/Applications/FanPilot.app/Contents/MacOS/FanPilot
if [ "${DAEMON_UP}" = "1" ] && pgrep -x FanPilot >/dev/null 2>&1; then
  P="$(pgrep -x FanPilot | head -1)"
  rpt(){ kill -USR1 "${P}"; sleep 0.5; sed -n "s/.*\"$1\": \([0-9.a-z]*\).*/\1/p" /tmp/fanpilot-ui.json; }
  [ "$(rpt watching_status)" = "true" ] && ok "App 正在监听 status.json" || bad "App 没有监听 status.json"
  c1="$(rpt refresh_count)"
  # 往 /var/run 里狂造 50 次无关变化：盯的是单个文件，refresh 不得因此增加
  for i in $(seq 50); do : > /var/run/.e2e-noise; rm -f /var/run/.e2e-noise; done
  sleep 1; c2="$(rpt refresh_count)"
  [ "$(( c2 - c1 ))" -le 1 ] && ok "⭐/var/run 里 100 次无关事件 → App 刷新 $(( c2 - c1 )) 次（只盯单个文件）" \
                           || bad "/var/run 噪音触发了 $(( c2 - c1 )) 次刷新 —— 盯成了目录"
  # 跟得上：守护写完 ≤ 1s 内 App 读到的就是最新 ts（连续 3 次巡检）
  okn=0
  for i in 1 2 3; do
    sleep "$(stat_num check_interval | cut -d. -f1)"; sleep 0.5
    # 🩸 先读守护 ts、再让 App 自报，判「App 看到的 ≥ 自报前已存在的」。
    #    初版反过来（先自报、再读 ts）：守护恰好在那 0.5s 内又写一次就误判（2026-10-28 实测 2/3）。
    before="$(stat_num ts)"
    seen="$(rpt last_seen_status_ts | cut -d. -f1)"
    [ "${seen:-0}" -ge "${before:-1}" ] && okn=$((okn+1))
  done
  [ "${okn}" = "3" ] && ok "⭐连续 3 次巡检，App 显示的都是守护最新一次写入（屏幕延迟 ≤ 巡检间隔）" \
                     || bad "只有 ${okn}/3 次跟上守护的最新写入 —— 监听失效或没重挂"
else
  skip "守护或菜单栏 App 未运行，跳过 R19"
fi

grp "回归 R20 —— 紧急打满 / 解除被当成「外部改动」⇒ 让步 30 分钟、风扇卡在最高速（2026-10-29 真事故）"
# 🩸 每次紧急进出，守护都把「SMC 回读 ≠ 新目标」记成外部改动，一进一出凑满 3 次 ⇒ 让步，停在自己写的上限。
# ⭐ 判据看 external_overrides 的**增量**：每次改配置都会清空抢写计数，只看「有没有让步」测不出这个 bug。
if [ "${DAEMON_UP}" = "1" ]; then
  avg="$(stat_num temp_average_c | cut -d. -f1)"
  if [ "${avg:-0}" -ge 71 ] && [ "${avg:-0}" -lt 85 ]; then
    e0="$(stat_num external_overrides)"
    set_key emergency_temp 70; sleep 7
    m1="$(stat_str mode)"; e1="$(stat_num external_overrides)"
    set_key emergency_temp 90; sleep 7
    m_hold="$(stat_str mode)"
    # 打满后至少保持 60 s 才解除（2.1.3：防过热路径的写入风暴）⇒ 最多再等 75 s
    for _ in $(seq 15); do [ "$(stat_str mode)" = "normal" ] && break; sleep 5; done
    m2="$(stat_str mode)"; e2="$(stat_num external_overrides)"
    [ "${m_hold}" = "emergency" ] && ok "改回阈值 7 s 后仍在打满（最短保持 60 s，不立即解除）" \
                                  || bad "打满 7 s 就解除了 —— 最短保持时间失效，温度来回摆时会频繁写 SMC"
    [ "${m1}" = "emergency" ] && ok "阈值 70°C（全核平均 ${avg}°C）⇒ 进入紧急打满" \
                              || bad "阈值 70°C 时 mode=${m1}，没进入紧急 —— 本条判据前提不成立"
    [ "${m2}" = "normal" ] && ok "阈值改回 90°C ⇒ 解除，回到定速" || bad "改回 90°C 后 mode=${m2}"
    [ "$(( e2 - e0 ))" = "0" ] \
      && ok "⭐紧急进入 + 解除全程「外部改动」+0（自己改目标不算别人改）" \
      || bad "紧急进出被记成外部改动 $(( e2 - e0 )) 次 —— 3 次就会让步 30 分钟、风扇卡在最高速"
  else
    skip "全核平均 ${avg}°C 不在 71~84°C，无法用阈值 70/90 制造一次紧急进出，跳过 R20（单测已覆盖）"
  fi
else
  skip "真守护未运行，跳过 R20"
fi

grp "回归 R14 —— 测试脚本自己留下孤儿守护（2026-09-14 真事故）"
# 事故：R4 裸启动一个 fanpilotd（真守护当时已停 ⇒ flock 无人占 ⇒ 它成了真守护并阻塞）；
#      我 pkill 掉 e2e.sh 后它被孤儿化（PPID=1），在后台写了 6 小时 SMC，
#      与 Macs Fan Control 抢寄存器 ⇒ 使用者看到转速在 3300/2500 间拉锯，两边都不报错。
# ⭐ 判据必须验**机制**，不是验"我加了注释"。三条分别对应三层修复。
nc_e(){ sed 's/[[:space:]]*#.*$//' "${ROOT}/tests/e2e.sh"; }

# 🩸🩸 判据必须**行首锚定**，否则它会匹配到自己这行代码。
#    实测（就在写这组测试时）：初版用 `grep -c 'trap restore EXIT INT TERM'`，
#    而这个字面量**就在判据自己这一行里** ⇒ 计数恒 ≥1 ⇒ 把 trap 改回只有 EXIT
#    之后判据**依然是绿的**。判据匹配判据 = 恒真 = 完全失活。
#    ⭐ 通解：grep 源码的判据要么行首锚定到**只有真代码才有的形态**，
#       要么把被搜的区段排除掉。这是本项目第 8 次栽在「判据命中自己」上。

# ① trap 必须含 INT/TERM —— 只有 EXIT 的话 SIGTERM 会直接干掉 shell，trap 不执行
#    锚 `^trap ` ：真代码在行首，本判据自己以 `[ "$(...` 开头，匹配不到自己
[ "$(nc_e | grep -cE '^trap restore .*INT.*TERM')" != "0" ] \
  && ok "trap 覆盖 EXIT/INT/TERM（被 pkill 时也会清理子进程）" \
  || bad "trap 未覆盖 INT/TERM —— 被 pkill 时子进程会孤儿化"

# ② R4 必须先断言真守护在跑，否则语义翻转成"制造野守护"
#    锚 `^if ! pgrep` ：同理，本判据自己匹配不到
[ "$(nc_e | grep -cE '^if ! pgrep -x fanpilotd')" != "0" ] \
  && ok "R4 有前置条件断言（真守护未跑时跳过而不是制造野守护）" \
  || bad "R4 缺前置条件断言 —— 真守护没跑时会启动一个野守护"

# ③ 绝不能再有"裸启动守护"——必须走 run_bounded 且带 --oneshot
[ "$(nc_e | grep -cE '^[[:space:]]*"\$\{BIN\}"[[:space:]]+--config')" = "0" ] \
  && ok "无任何裸启动守护的调用（都经 run_bounded）" \
  || bad "仍有裸启动守护的调用 —— 可能挂死并留下孤儿"

# 🔑 活体验证：真的制造一个孤儿，再确认兜底扫描能收掉它。
#    只验"代码里有 pkill"是不够的 —— 要验它真的杀得掉，且**不误杀真守护**。
(sleep 300 >/dev/null 2>&1 &
 exec -a "fanpilotd --config /tmp/x --status /tmp/e2e-orphan-probe.json" sleep 300) \
  >/dev/null 2>&1 &
sleep 1
before="$(pgrep -f 'e2e-orphan-probe' | grep -c . || true)"
pkill -f 'fanpilotd .*--status /tmp/e2e-' 2>/dev/null || true
sleep 1
after="$(pgrep -f 'e2e-orphan-probe' | grep -c . || true)"
if [ "${before}" -gt 0 ]; then
  [ "${after}" = "0" ] && ok "⭐活体：造出的孤儿(${before}个)被兜底扫描收掉" \
                       || bad "⭐活体：孤儿仍在（${after}个）—— 兜底扫描无效"
else
  skip "无法造出探针进程（exec -a 不可用），跳过活体验证"
fi
# ⭐ 反向：兜底扫描的判据必须**不匹配** launchd 管的真守护命令行
real_args="/usr/local/sbin/fanpilotd"
printf '%s\n' "${real_args}" | grep -q -- '--status /tmp/e2e-' \
  && bad "兜底判据会误杀真守护 —— 命令行特征不够特异" \
  || ok "⭐反向：兜底判据不匹配真守护（${real_args}）—— 不会误杀"
pkill -f 'e2e-orphan-probe' 2>/dev/null || true

echo
echo "═══════════════════════════════"
printf '  通过 %d · 失败 %d · 跳过 %d\n' "${PASS}" "${FAIL}" "${SKIP}"
[ "${FAIL}" = "0" ] && { echo "  ✅ E2E + 回归全部通过"; exit 0; } || { echo "  ❌ 有失败"; exit 1; }
