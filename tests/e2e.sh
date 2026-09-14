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
restore(){
  if [ -s "${BACKUP}" ]; then
    cp "${BACKUP}" "${CONF}"
    chown "${CONSOLE_USER_G}" "${CONF}" 2>/dev/null || true   # 同上：别留下 root 属主
    sleep 6      # 等守护自动重载回原配置
  fi
  rm -f "${BACKUP}" /tmp/e2e-*.conf /tmp/e2e-*.json /tmp/e2e-*.png
}
trap restore EXIT

# 读状态文件里的一个数字字段（不解析配置文件 —— 那份带人写的注释）
stat_num(){ sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9.-]*\).*/\1/p" "${STATUS}" | head -1; }
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
wait_reload(){ sleep 7; }   # 守护每 poll_interval 检查 mtime；给足余量

# ═══════════════════════════════════════════════════════════════════
grp "E2E-1 用户路径：从菜单改下限 → 自动生效（无需 reload、无需密码）"
before="$(stat_num min_rpm)"
set_key min_rpm 3000
wait_reload
after="$(stat_num min_rpm)"
[ "${after%.*}" = "3000" ] && ok "改下限 ${before%.*} → 3000 自动生效（守护监视 mtime）" \
                           || bad "下限仍为 ${after}（自动重载失效）"

# ⭐ 用户诉求的核心：抬高下限后曲线必须**重新铺开**，不能压平出死区
eff="$("${BIN}" --config "${CONF}" --check-config 2>/dev/null)"
mono=1; prev=""
while IFS= read -r r; do
  [ -z "${prev}" ] || awk -v a="${prev}" -v b="${r}" 'BEGIN{exit !(b>a+1)}' || mono=0
  prev="${r}"
done < <(printf '%s\n' "${eff}" | sed -n 's/^fan0_curve[0-9]*=[0-9.]*:\([0-9]*\)$/\1/p')
[ "${mono}" = "1" ] && ok "⭐下限 3000 时曲线 5 点严格递增 —— 无死区（曲线自适应生效）" \
                    || bad "曲线出现平段/回落 —— 抬高下限后压平了"

# 实际目标必须跟到新下限之上
t0="$(sed -n 's/.*"target_rpm"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "${STATUS}" | head -1)"
awk -v t="${t0:-0}" 'BEGIN{exit !(t>=2999)}' && ok "风扇目标 ${t0} ≥ 新下限 3000" \
                                             || bad "风扇目标 ${t0} < 3000（下限未施加）"

grp "E2E-2 恢复原配置 → 目标回落"
set_key min_rpm 2000
wait_reload
[ "$(stat_num min_rpm | cut -d. -f1)" = "2000" ] && ok "下限恢复 2000" || bad "下限未恢复"

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
"${BIN}" --config "${CONF}" --status /tmp/e2e-dup.json >/dev/null 2>&1
[ $? = 4 ] && ok "第二个实例被拒（退出码 4）" || bad "第二个实例竟能启动 —— 会抢写 SMC"
[ "$(pgrep -x fanpilotd | grep -c .)" = "1" ] && ok "实例数恒为 1" || bad "存在多个实例"

grp "回归 R5 —— 安全阈值被配置绕过"
# 真实 bug①：max_rpm 设很低 ⇒ 紧急打满被用户上限挡住
# 真实 bug②：emergency_temp 设 200 ⇒ 紧急保护被整个禁用
EVIL=/tmp/e2e-evil.conf
printf 'emergency_temp = 200\npoll_interval = 0.01\nema_seconds = 9999\ndeadband = 99999\nslew_up = 1\n' > "${EVIL}"
e="$("${BIN}" --config "${EVIL}" --check-config 2>/dev/null)"
chk_clamp(){
  local got; got="$(printf '%s\n' "$e" | awk -F= -v k="$1" '$1==k{print $2;exit}')"
  awk -v a="${got:-0}" -v b="$2" 'BEGIN{exit !(a-b<0.01 && b-a<0.01)}' \
    && ok "$1 被夹到 $2" || bad "$1=${got:-读不到}，期望 $2 —— 阈值可被绕过"
}
chk_clamp emergency_temp 95
chk_clamp poll_interval  0.50
chk_clamp ema_seconds    120
chk_clamp deadband       500
chk_clamp slew_up        10

grp "回归 R6 —— --check-config 显示模板而非生效曲线"
# 真实 bug：check-config 在读到硬件上限前就 return，打印的是模板 ⇒ 看起来能验其实验不到
hw="$(printf '%s\n' "$e" | grep -c '^fan[01]_hw_max=' || true)"
[ "${hw}" = "2" ] && ok "check-config 报告两风扇各自的硬件上限（显示真正生效的）" \
                  || bad "check-config 未报告硬件上限 —— 又变成只显示模板"
# 两风扇上限不同 ⇒ 曲线末点必须不同（否则风扇1 白丢余量）
l0="$(printf '%s\n' "$e" | sed -n 's/^fan0_curve4=[0-9.]*:\([0-9]*\)$/\1/p')"
l1="$(printf '%s\n' "$e" | sed -n 's/^fan1_curve4=[0-9.]*:\([0-9]*\)$/\1/p')"
[ -n "${l0}" ] && [ -n "${l1}" ] && [ "${l0}" != "${l1}" ] \
  && ok "两风扇曲线末点不同（${l0} / ${l1}）—— 各自铺到自己上限" \
  || bad "两风扇曲线末点相同（${l0}/${l1}）—— 风扇1 丢失余量"

grp "回归 R7 —— 菜单栏宽度横跳 / emoji 变黑块 / 靠上对齐"
if [ -x "${APPBIN}" ]; then
  ws=""
  for st in normal emergency fault firmware; do
    out="$("${APPBIN}" --render-preview "/tmp/e2e-${st}.png" "57°" "2384" "${st}" 2>/dev/null)"
    w="$(printf '%s' "${out}" | sed -n 's/.*图像=(\([0-9.]*\),.*/\1/p')"
    ws="${ws} ${w}"
  done
  uniqn="$(printf '%s\n' ${ws} | sort -u | grep -c . || true)"
  [ "${uniqn}" = "1" ] && ok "4 种状态菜单栏宽度一致（${ws} ）—— 不横跳" \
                       || bad "宽度不一致（${ws} ）—— 菜单栏会横跳"
  # 宽度不得回退到过去的臃肿值（34/38pt）
  w1="$(printf '%s\n' ${ws} | head -1)"
  awk -v w="${w1}" 'BEGIN{exit !(w<=26)}' && ok "宽度 ${w1}pt ≤ 26pt（未回退到 34/38pt 的臃肿版）" \
                                          || bad "宽度 ${w1}pt 过宽，挤占菜单栏"
  # 🩸 状态标记不得与数字重叠（实测踩过：4 位转速占满全宽时，
  #    画在左侧空隙的标记直接压在数字上，数字读不出来）。
  #    判据：用**最宽内容**渲染紧急态，检查文字墨迹与贴底标记条之间必须有空行。
  "${APPBIN}" --render-preview /tmp/e2e-collide.png "100°" "5777" emergency >/dev/null 2>&1
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

grp "回归 R9 —— 下限档位标签语义错误"
# 真实 bug：标签用三元表达式只覆盖 3 档，1500/2500/3500/4000 全落到「强散热」；
#          且「强散热」本身是误导 —— 下限不改变高温散热能力
sw="$(grep -c 'case 1500: hint' "${ROOT}/app/Sources/FanPilotMenu/main.swift" || true)"
[ "${sw}" != "0" ] && ok "档位标签逐档定义（不是只覆盖 3 档的三元表达式）" \
                   || bad "档位标签未逐档定义 —— 会有档位落到错误的 else"
# 剥掉注释后再判：否则会命中「初版把 4000 标成强散热是误导」这句注释本身
mis="$(nocomment_swift "${ROOT}/app/Sources/FanPilotMenu/main.swift" | grep -c '强散热' || true)"
[ "${mis}" = "0" ] && ok "无「强散热」误导性标签（已剥注释后判定）" \
                   || bad "仍有「强散热」标签 —— 会让人以为高档能压住高负载"

grp "回归 R10 —— 逻辑在两处重复（守护与 fanlogic.h 分叉）"
for fn in fl_curve_eval fl_clamp_fan fl_ema fl_slew fl_should_write fl_fault_check; do
  n="$(grep -c "${fn}" "${ROOT}/src/fanpilotd.c" || true)"
  [ "${n}" != "0" ] || bad "守护未使用 ${fn}（逻辑可能又复制了一份）"
done
dup="$(grep -cE '^static (double|int) (curve_eval|clamp_fan)\(' "${ROOT}/src/fanpilotd.c" || true)"
[ "${dup}" = "0" ] && ok "守护内无重复的决策逻辑实现（单一来源 fanlogic.h）" \
                   || bad "守护内仍有重复实现 —— 两份都可能被当权威，必然分叉"

grp "回归 R11 —— 菜单槽位错位（骨架槽位数 ≠ set() 调用数）"
# 真实 bug（2026-09-14）：温度口径加到三档时**只加了 set() 没加骨架槽位**，
#   导致「平滑后」往下整体串一格：风扇标题跑到缩进层、轮询行挂到「开机自动启动」下面、
#   最后一行被 `dyn.indices.contains(i)` **静默丢弃**。肉眼与 grep 都查不出来。
# ⭐ 判据必须是「真的把菜单渲染一遍」，不是 grep 源码数行数
#   （grep 会命中注释、也数不清 for 循环里的槽位）。
if [ -x "${APPBIN}" ]; then
  if dm="$("${APPBIN}" --dump-menu 2>&1)"; then
    ok "--dump-menu 槽位契约成立（$(printf '%s' "${dm}" | sed -n 's/^槽位 \(.*\)$/\1/p')）"
  else
    bad "--dump-menu 报告槽位不匹配 —— 菜单有行错位或被丢弃：$(printf '%s' "${dm}" | tail -1)"
  fi
  # 三档温度必须都在菜单里出现，且**恰好一档**被标为曲线输入
  for L in 最高核心 全核平均 最低核心 平滑后; do
    printf '%s\n' "${dm}" | grep -q "${L}" \
      && ok "菜单含「${L}」行" || bad "菜单缺「${L}」行"
  done
  nc="$(printf '%s\n' "${dm}" | grep -c '← 曲线输入' || true)"
  [ "${nc}" = "1" ] && ok "恰好一档被标为「曲线输入」" \
                    || bad "被标为「曲线输入」的档位有 ${nc} 个（应为 1）"
  ne="$(printf '%s\n' "${dm}" | grep -c '紧急判据 ≥' || true)"
  [ "${ne}" = "1" ] && ok "恰好一档被标为「紧急判据」，且带阈值数字" \
                    || bad "「紧急判据」标记有 ${ne} 处（应为 1）"
  # 🩸 旧版用 `！紧急` 这种裸符号，读起来像告警（"81.9°C！紧急"）而实际只是口径标注。
  #    剥注释后判：源码里不得再出现这两个无说明的符号标记。
  bads="$(nocomment_swift "${ROOT}/app/Sources/FanPilotMenu/main.swift" \
          | grep -cE '★曲线|!紧急' || true)"
  [ "${bads}" = "0" ] && ok "无无说明的符号标记（★曲线 / !紧急 已改成完整词组）" \
                      || bad "仍有 ${bads} 处裸符号标记 —— 没有图例，只有作者看得懂"
  # 同一事实只写一处：不得再有独立的「紧急判据用：」行与行内标记并存
  dupe="$(nocomment_swift "${ROOT}/app/Sources/FanPilotMenu/main.swift" \
          | grep -c '紧急判据用' || true)"
  [ "${dupe}" = "0" ] && ok "紧急判据只标在它监视的那行温度旁（无重复的独立行）" \
                      || bad "紧急判据有两处表述 —— 改一处忘另一处就会自相矛盾"
else
  skip "菜单栏 App 未构建，跳过 R11"
fi

echo
echo "═══════════════════════════════"
printf '  通过 %d · 失败 %d · 跳过 %d\n' "${PASS}" "${FAIL}" "${SKIP}"
[ "${FAIL}" = "0" ] && { echo "  ✅ E2E + 回归全部通过"; exit 0; } || { echo "  ❌ 有失败"; exit 1; }
