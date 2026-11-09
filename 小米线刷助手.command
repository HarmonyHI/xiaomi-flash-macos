#!/bin/bash
# ============================================================================
#  小米 fastboot 线刷助手 · macOS
# ----------------------------------------------------------------------------
#  作用：自动读取「本脚本同目录」下的 flash_*.bat（小米官方线刷包的 Windows
#        脚本），逐行解析并翻译成 macOS 可执行的 fastboot 命令序列，然后
#        让你选择刷机方案，确认后按原脚本的顺序逐步执行。
#
#  用法：双击运行（Terminal 会自动打开）
#        终端：  ./小米线刷助手.command            交互式
#                ./小米线刷助手.command --dry-run  只解析不刷机
#                ./小米线刷助手.command --plan 2   直接选第 2 个方案
#                ./小米线刷助手.command --help
#
#  说明：脚本不改动任何 .bat 原文，全部是运行时解析，转换结果会保存下来
#        方便你复核（路径在结束时会打印）。
# ============================================================================

set -u

APP_VER="1.0"

# ---------------------------------------------------------------- 路径 ----
SRC="${BASH_SOURCE[0]:-$0}"
HERE="$(cd "$(dirname "$SRC")" 2>/dev/null && pwd)"
HERE="${HERE:-$PWD}"
IMAGES="${IMAGES_DIR:-$HERE/images}"
STAMP="$(date +%Y%m%d-%H%M%S)"

LOG_DIR="$HOME/xiaomi-flash-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="$LOG_DIR/flash-$STAMP.log"
PLANS="$LOG_DIR/plans-$STAMP"
mkdir -p "$PLANS" 2>/dev/null || PLANS="/tmp/plans-$STAMP"
mkdir -p "$PLANS" 2>/dev/null
TMPD="$PLANS/.tmp"
mkdir -p "$TMPD" 2>/dev/null

# ---------------------------------------------------------------- 配色 ----
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'
  W=$'\033[1m';  D=$'\033[2m';  N=$'\033[0m'
else
  R=; G=; Y=; B=; W=; D=; N=
fi

say()  { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────"; }
log()  { printf '%s\n' "$*" >> "$LOG" 2>/dev/null; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 把字符串包成安全的双引号形式（用于生成 shell 代码）
q() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

die() {
  printf '\n%s✗ %s%s\n' "$R" "$*" "$N"
  log "✗ $*"
  printf '%s日志文件：%s%s\n' "$D" "$LOG" "$N"
  exit 1
}

# ========================================================== 运行时函数 ====
# 下面的函数会被「翻译后的计划文件」调用，必须在 source 之前定义。

STEP=0
TOTAL=0
FASTBOOT=""

step_begin() {
  STEP=$((STEP + 1))
  [ -n "${STEPFILE:-}" ] && printf '%s' "$STEP" > "$STEPFILE" 2>/dev/null
  printf '\n%s[%2d/%2d]%s %s\n' "$B" "$STEP" "$TOTAL" "$N" "$1"
  log "[$STEP/$TOTAL] $1"
}

note() {
  printf '       %s· %s%s\n' "$D" "$1" "$N"
  log "  · $1"
}

check_begin() { printf '  %s·%s %s ' "$B" "$N" "$1"; }
check_ok()    { printf '%s✓%s\n' "$G" "$N"; }
check_bad()   { printf '%s✗%s\n' "$R" "$N"; }

# 执行 fastboot：实时输出 + 同时写日志；返回 fastboot 的退出码
run_fb() {
  "$FASTBOOT" "$@" 2>&1 | tee -a "$LOG" | sed 's/^/       /'
  local rc=${PIPESTATUS[0]}
  return $rc
}

# 找到镜像文件：images/ 优先，其次脚本同目录
resolve_img() {
  local n="$1"
  local base="${n##*/}"
  local c
  for c in "$IMAGES/$base" "$HERE/$base" "$HERE/images/$base"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf ''
  return 1
}

fb_flash() {   # 分区 镜像 失败信息
  local part="$1" img="$2" msg="$3" f
  step_begin "写入 $part  ←  ${img##*/}"
  f="$(resolve_img "$img")"
  [ -n "$f" ] || die "缺少镜像文件：${img##*/}（在 $IMAGES 下找不到）—— 刷机包不完整，已停止，未对手机做任何操作"
  run_fb flash "$part" "$f" || die "$msg"
}

fb_erase() {   # 分区 失败信息
  local part="$1" msg="$2"
  step_begin "擦除分区 $part"
  run_fb erase "$part" || die "$msg"
}

fb_step() {    # 描述 失败信息 命令...
  local desc="$1" msg="$2"; shift 2
  step_begin "$desc"
  run_fb "$@" || die "$msg"
}

fb_probe() { "$FASTBOOT" "$@" 2>&1; }

probe_grep() { # 正则 命令...
  local pat="$1"; shift
  fb_probe "$@" | grep -Eq -- "$pat"
}

probe_grep_or_die() {  # 正则 失败信息 命令...
  local pat="$1" msg="$2"; shift 2
  check_begin "fastboot $*"
  local out
  out="$(fb_probe "$@")"
  log "$out"
  if printf '%s\n' "$out" | grep -Eq -- "$pat"; then
    check_ok
  else
    check_bad
    die "$msg"
  fi
}

getvar_value() {  # 键 -> 值
  fb_probe getvar "$1" 2>/dev/null \
    | tr -d '\r' \
    | awk -F': *' -v k="$1" 'index($0, k ":") == 1 && NF > 1 { print $2; exit }'
}

anti_from_file() {
  if [ -f "$IMAGES/anti_version.txt" ]; then
    tr -d ' \r\n' < "$IMAGES/anti_version.txt"
  elif [ -f "$HERE/anti_version.txt" ]; then
    tr -d ' \r\n' < "$HERE/anti_version.txt"
  else
    printf '0'
  fi
}

check_antirollback() {  # 设备anti 包anti
  local dev="${1:-0}" pkg="${2:-0}"
  case "$dev" in ''|*[!0-9]*) dev=0 ;; esac
  case "$pkg" in ''|*[!0-9]*) pkg=0 ;; esac
  check_begin "防回滚校验（设备 anti=$dev / 刷机包 anti=${pkg}）"
  if [ "$dev" -gt "$pkg" ]; then
    check_bad
    die "设备防回滚版本高于此刷机包（Antirollback check error）—— 强刷会导致变砖，已停止"
  fi
  check_ok
}

# ======================================================== BAT 翻译器 ======
# 把 %~dp0images\xxx.img 这类 Windows 路径转成 $IMAGES/xxx.img
xlate_arg() {
  local p="$1"
  p="${p//\\//}"
  case "$p" in
    *'%~dp0images/'*) printf '"$IMAGES/%s"' "${p#*%~dp0images/}" ;;
    *'%~dp0'*)        printf '"$HERE/%s"'   "${p#*%~dp0}" ;;
    *)                printf '%s' "$p" ;;
  esac
}

# 从 "|| @echo \"xxx\" && exit 1" 里取出提示语
action_msg() {
  local a="$1"
  case "$a" in
    *echo*)
      a="${a#*echo }"
      a="${a%%&&*}"
      a="$(trim "$a")"
      a="${a%\"}"; a="${a#\"}"
      printf '%s' "$a" ;;
    *) printf '' ;;
  esac
}

# 生成「一步」的代码
emit_step() {  # 命令串 失败信息 输出文件
  local expr="$1" msg="$2" out="$3" sub part img a1
  local -a w
  read -ra w <<< "$expr"
  sub="${w[0]:-}"
  case "$sub" in
    erase)
      part="${w[1]:-}"
      [ -n "$msg" ] || msg="擦除 $part 失败"
      printf '#@ 擦除分区 %s\n' "$part"                              >> "$out"
      printf 'fb_erase %s %s\n' "$(q "$part")" "$(q "$msg")"          >> "$out"
      ;;
    flash)
      part="${w[1]:-}"
      img="${w[2]:-}"
      [ -n "$msg" ] || msg="写入 $part 失败"
      printf '#@ 写入 %s  ←  %s\n' "$part" "$(basename "${img//\\//}")" >> "$out"
      printf 'fb_flash %s %s %s\n' "$(q "$part")" "$(xlate_arg "$img")" "$(q "$msg")" >> "$out"
      ;;
    set_active)
      a1="${w[1]:-a}"
      [ -n "$msg" ] || msg="激活槽位 $a1 失败"
      printf '#@ 切换活动槽位 → %s\n' "$a1"                            >> "$out"
      printf 'fb_step %s %s set_active %s\n' "$(q "激活槽位 $a1")" "$(q "$msg")" "$(q "$a1")" >> "$out"
      ;;
    reboot)
      [ -n "$msg" ] || msg="重启失败"
      printf '#@ 重启设备\n'                                          >> "$out"
      printf 'fb_step %s %s reboot\n' "$(q "重启设备")" "$(q "$msg")"  >> "$out"
      ;;
    oem)
      a1="${w[1]:-}"
      [ -n "$msg" ] || msg="oem $a1 失败"
      if [ "$a1" = "lock" ]; then
        printf '#@ 重新锁定 Bootloader（oem lock）\n'                  >> "$out"
        printf 'fb_step %s %s oem lock\n' "$(q "重新锁定 Bootloader")" "$(q "$msg")" >> "$out"
      else
        printf '#@ 执行 fastboot oem %s\n' "$a1"                       >> "$out"
        printf 'fb_step %s %s oem %s\n' "$(q "oem $a1")" "$(q "$msg")" "$(q "$a1")" >> "$out"
      fi
      ;;
    getvar)
      printf '#@? （探针）fastboot %s\n' "$expr"                        >> "$out"
      ;;
    *)
      [ -n "$msg" ] || msg="fastboot $expr 失败"
      printf '#@ 执行 fastboot %s\n' "$expr"                           >> "$out"
      printf 'fb_step %s %s %s\n' "$(q "fastboot $expr")" "$(q "$msg")" "$expr" >> "$out"
      ;;
  esac
}

# 主翻译：translate_bat <输入.bat> <输出.plan>
translate_bat() {
  local src="$1" out="$2"
  local -a L
  local n=0 l
  while IFS= read -r l || [ -n "$l" ]; do
    L[$n]="${l%$'\r'}"
    n=$((n + 1))
  done < "$src"

  {
    printf '# ── 自动翻译自：%s\n' "$(basename "$src")"
    printf '# ── 生成时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$out"

  local i=0 line cmd main action expr pat msg body t
  local varname key a1 a2 inner
  while [ "$i" -lt "$n" ]; do
    line="$(trim "${L[$i]}")"
    i=$((i + 1))

    # 空行 / 注释 / 无操作
    case "$line" in
      ''|@echo\ off*|echo\ off*|::*|rem\ *|REM\ *|@rem\ *|@rem*|pause*|@pause*|cls*|@cls*) continue ;;
    esac

    # ---------------------------------------------------- fastboot 命令 --
    if [ "${line#fastboot %\* }" != "$line" ]; then
      cmd="${line#fastboot %\* }"
      action=""
      case "$cmd" in
        *' || '*) action="${cmd#* || }"; main="${cmd%% || *}" ;;
        *)        main="$cmd" ;;
      esac

      pat=""
      case "$main" in
        *'findstr /r /c:"'*)
          pat="${main#*findstr /r /c:\"}"; pat="${pat%%\"*}"
          expr="${main%%| findstr*}"
          ;;
        *) expr="$main" ;;
      esac
      expr="$(trim "$expr")"
      expr="${expr%2>&1}"
      expr="$(trim "$expr")"

      if [ -n "$pat" ]; then
        if [ -n "$action" ]; then
          # 检查不通过就退出：getvar xxx | findstr ... || exit
          msg="$(action_msg "$action")"
          [ -n "$msg" ] || msg="设备检查未通过：fastboot $expr 不匹配 /$pat/"
          printf '#@? 检查：fastboot %s 是否匹配 /%s/\n' "$expr" "$pat" >> "$out"
          printf 'probe_grep_or_die %s %s %s\n' "$(q "$pat")" "$(q "$msg")" "$expr" >> "$out"
        else
          # 纯探针，后面可能跟 if %errorlevel% equ 0 ( ... ) 块
          if [ "$i" -lt "$n" ] && [ "$(trim "${L[$i]}")" = "if %errorlevel% equ 0 (" ]; then
            i=$((i + 1))
            body=""
            while [ "$i" -lt "$n" ]; do
              t="$(trim "${L[$i]}")"
              i=$((i + 1))
              [ "$t" = ")" ] && break
              body+="$t"$'\n'
            done
            local bsrc="$TMPD/blk.bat" bout="$TMPD/blk.plan"
            printf '%s' "$body" > "$bsrc"
            translate_bat "$bsrc" "$bout"
            {
              printf '#@? 条件：fastboot %s 匹配 /%s/ 时执行以下操作\n' "$expr" "$pat"
              printf 'if probe_grep %s %s ; then\n' "$(q "$pat")" "$expr"
            } >> "$out"
            sed '/^# ── 自动翻译自/d; /^# ── 生成时间/d; /^$/d' "$bout" | sed 's/^/  /' >> "$out"
            printf 'fi\n' >> "$out"
          else
            printf '#@? 检查（仅探测，不中断）：fastboot %s\n' "$expr" >> "$out"
          fi
        fi
      else
        emit_step "$expr" "$(action_msg "$action")" "$out"
      fi
      continue
    fi

    # ------------------------------------------- if exist "x.xx" ( ... ) --
    case "$line" in
      'if exist '*)
        inner="${line#*(}"; inner="${inner%)*}"
        case "$inner" in
          *anti_version.txt*|*CURRENT_ANTI_VER*)
            printf '#@? 读取刷机包内的 anti_version.txt（缺省按 0 处理）\n' >> "$out"
            printf 'CURRENT_ANTI_VER="$(anti_from_file)"\n'                >> "$out"
            ;;
          *)
            printf '#@! 无法翻译的条件块，已跳过：%s\n' "$line"            >> "$out"
            ;;
        esac
        continue ;;
    esac

    # ------------------------------------- for /f ... in ('cmd') do (set) --
    case "$line" in
      'for /f '*)
        varname="$(printf '%s' "$line" | sed -n 's/.*set \([A-Za-z0-9_]*\)=.*/\1/p')"
        inner="$(printf '%s' "$line" | sed -n 's/.* in (\(.*\)) do (.*$/\1/p')"
        inner="$(printf '%s' "$inner" | sed "s/^'//; s/'$//")"
        case "$inner" in
          *getvar*)
            key="$(printf '%s' "$inner" | sed -n 's/.*getvar \([A-Za-z0-9:_-]*\).*/\1/p')"
            printf '#@? 读取设备 %s 版本\n' "$key"                          >> "$out"
            printf '%s="$(getvar_value %s)"\n' "$varname" "$key"           >> "$out"
            ;;
          *)
            printf '#@! 无法翻译的 for 块，已跳过：%s\n' "$line"           >> "$out"
            ;;
        esac
        continue ;;
    esac

    # --------------------------------- if [%VAR%] EQU [] set VAR=0 --
    case "$line" in
      'if [%'*)
        varname="$(printf '%s' "$line" | sed -n 's/^if \[%\([^]]*\)%\].*/\1/p')"
        printf '[ -n "${%s:-}" ] || %s=0\n' "$varname" "$varname" >> "$out"
        continue ;;
    esac

    # --------------------- if %version% GTR %CURRENT_ANTI_VER% set anticheck --
    case "$line" in
      'if %'*'% GTR '*)
        a1="$(printf '%s' "$line" | sed -n 's/^if %\([^%]*\)% GTR %\([^%]*\)%.*/\1/p')"
        a2="$(printf '%s' "$line" | sed -n 's/^if %\([^%]*\)% GTR %\([^%]*\)%.*/\2/p')"
        printf '#@? 防回滚校验：%s 不得大于 %s\n' "$a1" "$a2"              >> "$out"
        printf 'check_antirollback "${%s:-0}" "${%s:-0}"\n' "$a1" "$a2"  >> "$out"
        continue ;;
    esac

    # --------------------------------------------- echo %anticheck% | ... --
    case "$line" in
      'echo %anticheck%'*|'@echo %anticheck%'*) continue ;;
    esac

    # -------------------------------------------------------- set VAR=... --
    case "$line" in
      'set '*|'@set '*)
        cmd="${line#@set }"; cmd="${cmd#set }"
        case "$cmd" in
          anticheck=*) continue ;;                       # 由上面的 GTR 行接管
          *=*) printf '%s\n' "$cmd" >> "$out" ;;
        esac
        continue ;;
    esac

    # ------------------------------------------------------------- echo --
    case "$line" in
      'echo '*|'@echo '*)
        msg="${line#@echo }"; msg="${msg#echo }"
        msg="$(trim "$msg")"; msg="${msg%\"}"; msg="${msg#\"}"
        printf 'note %s\n' "$(q "$msg")" >> "$out"
        continue ;;
    esac

    # ------------------------------------------------------------- exit --
    case "$line" in
      'exit /B 1'|'exit /b 1'|'exit 1'|'exit /B 0')
        printf 'die %s\n' "$(q "源脚本要求在此退出")" >> "$out"
        continue ;;
    esac

    # ----------------------------------------------------------- 兜底 --
    printf '#@! 无法识别的语句，已跳过：%s\n' "$line" >> "$out"
    log "WARN 无法识别: $line"
  done
}

# ============================================================ 工具 ========

plan_steps()   { local c; c="$(grep -cE '^[[:space:]]*(fb_flash|fb_erase|fb_step) ' "$1" 2>/dev/null)"; printf '%s' "${c:-0}"; }
plan_unknown() { local c; c="$(grep -cE '^[[:space:]]*#@!' "$1" 2>/dev/null)"; printf '%s' "${c:-0}"; }
plan_wipe()    { if grep -q 'fb_flash "userdata"' "$1" 2>/dev/null; then printf 'yes'; else printf 'no'; fi; }
plan_lock()    { if grep -q 'oem lock' "$1" 2>/dev/null; then printf 'yes'; else printf 'no'; fi; }
plan_imgcount(){ local c; c="$(grep -o '\$IMAGES/[^"]*' "$1" 2>/dev/null | sort -u | grep -c . )"; printf '%s' "${c:-0}"; }

scheme_title() {
  case "$1" in
    flash_all.bat)                printf '全量线刷' ;;
    flash_all_except_storage.bat) printf '保留数据线刷' ;;
    flash_all_lock.bat)           printf '全量线刷 + 回锁' ;;
    *)                            printf '自定义方案' ;;
  esac
}

scheme_desc() {
  case "$1" in
    flash_all.bat)                printf '写 super/userdata 等全部分区，清空手机内所有数据，完成后重启' ;;
    flash_all_except_storage.bat) printf '不写 userdata、不清 metadata，保留照片/应用等用户数据，完成后重启' ;;
    flash_all_lock.bat)           printf '全量写入并清空数据，最后执行 oem lock 重新锁回 BL' ;;
    *)                            printf '按脚本内容执行' ;;
  esac
}

# 查找同目录下的 .bat
find_bats() {
  BATS=()
  local f
  for f in "$HERE"/*.bat; do
    [ -f "$f" ] || continue
    BATS[${#BATS[@]}]="$f"
  done
}

# 打印某个方案的翻译结果（人读版）
show_plan() {  # 序号
  local n="$1"
  local f="${BATS[$((n - 1))]}"
  local p="$PLANS/$(basename "$f" .bat).plan"
  hr
  say "${W}方案 ${n}：$(basename "$f")${N}  ${D}→ $p${N}"
  hr
  local i=0 ln tl
  while IFS= read -r ln; do
    tl="$(trim "$ln")"
    case "$tl" in
      '#@ '*)  i=$((i + 1)); printf '%s%3d.%s %s\n' "$D" "$i" "$N" "${tl#\#@ }" ;;
      '#@? '*) printf '     %s%s%s\n' "$D" "${tl#\#@? }" "$N" ;;
      '#@! '*) printf '     %s⚠ %s%s\n' "$Y" "${tl#\#@! }" "$N" ;;
      'if probe_grep'*|'fi') printf '     %s%s%s\n' "$D" "$tl" "$N" ;;
    esac
  done < "$p"
  hr
  say "共 $(plan_steps "$p") 个可执行步骤，涉及 $(plan_imgcount "$p") 个镜像文件。"
}

# 检测 fastboot
find_fastboot() {
  local c
  if [ -n "${FB_PATH:-}" ] && [ -x "$FB_PATH" ]; then FASTBOOT="$FB_PATH"; return 0; fi
  c="$(command -v fastboot 2>/dev/null || true)"
  [ -n "$c" ] && { FASTBOOT="$c"; return 0; }
  for c in "$HERE/platform-tools/fastboot" "$HERE/fastboot" \
           "$HOME/Library/Android/sdk/platform-tools/fastboot" \
           "/opt/homebrew/bin/fastboot" "/usr/local/bin/fastboot"; do
    [ -x "$c" ] && { FASTBOOT="$c"; return 0; }
  done
  return 1
}

# 检查镜像完整性
check_images() {  # plan 文件
  local p="$1" miss="" cnt=0 total=0 im
  while IFS= read -r im; do
    total=$((total + 1))
    [ -n "$(resolve_img "$im")" ] || { miss+="  · $im"$'\n'; cnt=$((cnt + 1)); }
  done < <(grep -o '\$IMAGES/[^"]*' "$p" 2>/dev/null | sed 's|^\$IMAGES/||' | sort -u)

  [ "$total" -eq 0 ] && { MISSING_TOTAL=0; MISSING_CNT=0; return 0; }
  MISSING_TOTAL=$total
  MISSING_CNT=$cnt
  MISSING_LIST="$miss"
  [ "$cnt" -eq 0 ]
}

# 设备检查
check_device() {
  check_begin "检查 fastboot 设备连接"
  local out
  out="$("$FASTBOOT" devices 2>/dev/null | tr -d '\r' | sed '/^$/d')"
  log "devices: $out"
  if [ -z "$out" ]; then
    check_bad
    return 1
  fi
  check_ok
  DEV_SERIAL="$(printf '%s' "$out" | head -1 | awk '{print $1}')"
  return 0
}

# ============================================================ 主流程 ======

usage() {
  cat <<EOF
小米 fastboot 线刷助手 (macOS) v$APP_VER

  ./小米线刷助手.command              交互式选择方案并刷机
  ./小米线刷助手.command --dry-run    只解析、预览转换结果，不刷机
  ./小米线刷助手.command --plan N     直接使用第 N 个方案（仍需输入 FLASH 确认）
  ./小米线刷助手.command --help       显示帮助

脚本会读取所在目录下的 *.bat，解析成 macOS 的 fastboot 指令后执行。
镜像（images/ 目录）需要与脚本放在同一目录。
EOF
}

DRY=0
PRESET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --plan) shift; PRESET="${1:-}" ;;
    --help|-h) usage; exit 0 ;;
    *) say "未知参数：$1"; usage; exit 2 ;;
  esac
  shift
done

log "=== 小米线刷助手 v$APP_VER  $(date '+%F %T') ==="
log "目录: $HERE"
log "镜像目录: $IMAGES"

# ---- 横幅 ----
printf '\n'
say "${W}╔══════════════════════════════════════════════════════════╗${N}"
say "${W}║            小米 fastboot 线刷助手 · macOS                 ║${N}"
say "${W}╚══════════════════════════════════════════════════════════╝${N}"
say "  脚本目录：$HERE"
say "  镜像目录：$IMAGES"

# ---- 找 BAT ----
find_bats
if [ "${#BATS[@]}" -eq 0 ]; then
  printf '\n%s✗ 这个目录里没有找到任何 .bat 文件%s\n' "$R" "$N"
  say "  请把“小米线刷助手.command”放到小米线刷包根目录（和 flash_all.bat 一起）。"
  exit 1
fi

# ---- 翻译 ----
say ""
say "${D}正在解析 $HERE 下的 ${#BATS[@]} 个 BAT 脚本……${N}"
PROD=""
idx=0
for f in "${BATS[@]}"; do
  p="$PLANS/$(basename "$f" .bat).plan"
  translate_bat "$f" "$p"
  # 从 getvar product 里提取机型代号
  [ -n "$PROD" ] || PROD="$(grep -o 'product: \*[A-Za-z0-9_]*' "$p" 2>/dev/null | head -1 | sed 's/product: \*//')"
  idx=$((idx + 1))
done

[ -n "$PROD" ] || PROD="未知"
say "  目标机型代号：${W}$PROD${N} ${D}（取自脚本内的 product 校验）${N}"

# ---- 菜单 ----
menu() {
  hr
  say "${W}可用刷机方案${N}  ${D}（由 BAT 自动解析，非人工改写）${N}"
  hr
  local i=1 f p st wp lk uk
  for f in "${BATS[@]}"; do
    p="$PLANS/$(basename "$f" .bat).plan"
    st="$(plan_steps "$p")"; wp="$(plan_wipe "$p")"; lk="$(plan_lock "$p")"; uk="$(plan_unknown "$p")"
    printf ' %s%d)%s %-28s %s%s%s\n' "$B" "$i" "$N" "$(basename "$f")" "$W" "$(scheme_title "$(basename "$f")")" "$N"
    printf '     %s%s%s\n' "$D" "$(scheme_desc "$(basename "$f")" "$p")" "$N"
    printf '     %s%d 步 · %d 个镜像 · 数据：%s%s' "$D" "$st" "$(plan_imgcount "$p")" \
      "$([ "$wp" = yes ] && printf '清空全盘' || printf '保留')" ""
    [ "$lk" = yes ] && printf ' · 刷完回锁 BL'
    [ "$uk" -gt 0 ] && printf ' · %s⚠ %d 行未识别%s' "$Y" "$uk" "$N"
    printf '%s\n' "$N"
    say ""
    i=$((i + 1))
  done
  hr
  say " v) 查看某个方案的完整转换结果（不刷机）   q) 退出"
  hr
}

ask() {
  local ans
  while :; do
    printf '%s请选择方案 [1-%d / v / q]：%s' "$W" "${#BATS[@]}" "$N"
    read -r ans || exit 1
    ans="$(trim "$ans")"
    case "$ans" in
      q|Q|quit|exit) exit 0 ;;
      v|V)
        printf '要查看哪个方案？[1-%d]：' "${#BATS[@]}"
        read -r ans || exit 1
        ans="$(trim "$ans")"
        case "$ans" in
          ''|*[!0-9]*) ;;
          *) [ "$ans" -ge 1 ] && [ "$ans" -le "${#BATS[@]}" ] && { show_plan "$ans"; say ""; } ;;
        esac
        continue ;;
      ''|*[!0-9]*) say "  请输入 1～${#BATS[@]} 之间的数字。"; continue ;;
    esac
    [ "$ans" -ge 1 ] && [ "$ans" -le "${#BATS[@]}" ] || { say "  请输入 1～${#BATS[@]} 之间的数字。"; continue; }
    CHOICE="$ans"
    return 0
  done
}

if [ "$DRY" = 1 ]; then
  i=1
  for f in "${BATS[@]}"; do
    show_plan "$i"
    say ""
    i=$((i + 1))
  done
  say "${D}转换结果已保存到：$PLANS${N}"
  exit 0
fi

CHOICE=""
if [ -n "$PRESET" ]; then
  case "$PRESET" in
    ''|*[!0-9]*) die "--plan 需要一个数字" ;;
  esac
  [ "$PRESET" -ge 1 ] && [ "$PRESET" -le "${#BATS[@]}" ] || die "--plan $PRESET 超出范围（1～${#BATS[@]}）"
  CHOICE="$PRESET"
else
  menu
  ask
fi

SEL="${BATS[$((CHOICE - 1))]}"
SELBASE="$(basename "$SEL")"
PLAN="$PLANS/$(basename "$SEL" .bat).plan"
TOTAL="$(plan_steps "$PLAN")"
WIPE="$(plan_wipe "$PLAN")"
LOCK="$(plan_lock "$PLAN")"
UNK="$(plan_unknown "$PLAN")"

[ "$TOTAL" -gt 0 ] || die "解析 $SELBASE 得到 0 个步骤，脚本格式可能不被支持"

# ---- 方案摘要 ----
printf '\n'
hr
say "${W}已选择：$SELBASE${N}  ——  $(scheme_title "$SELBASE")"
say "  步骤数：$TOTAL"
say "  处理方式：$([ "$WIPE" = yes ] && printf '%s会清空手机内全部数据%s' "$R" "$N" || printf '保留用户数据')"
[ "$LOCK" = yes ] && say "  附加操作：${Y}刷完后重新锁定 Bootloader${N}"
[ "$UNK" -gt 0 ] && say "  ${Y}⚠ 有 $UNK 行无法识别，执行时会被跳过（v 可查看）${N}"
hr

# ---- 环境检查 ----
say "${W}环境检查${N}"
if ! find_fastboot; then
  printf '  %s✗%s 找不到 fastboot\n' "$R" "$N"
  say "    它是 Android platform-tools 里的命令。任选一种："
  say "      1) brew install --cask android-platform-tools"
  say "      2) 下载 platform-tools 后放到 $HERE/platform-tools/"
  say "      3) 用 FB_PATH=/path/to/fastboot ./小米线刷助手.command 指定"
  die "缺少 fastboot，未对手机做任何操作"
fi
check_begin "fastboot 路径"
check_ok
say "       ${D}$FASTBOOT${N}"
log "fastboot: $FASTBOOT ($("$FASTBOOT" --version 2>&1 | head -1))"

if ! check_images "$PLAN"; then
  printf '  %s✗%s 缺少 %d/%d 个镜像文件（在 %s 下找不到）\n' "$R" "$N" "$MISSING_CNT" "$MISSING_TOTAL" "$IMAGES"
  printf '%s' "$MISSING_LIST" | head -8 | sed 's/^/     /'
  [ "$MISSING_CNT" -gt 8 ] && say "     …… 还有 $((MISSING_CNT - 8)) 个"
  say ""
  say "  ${Y}这个目录里只有脚本，没有 images/ 镜像目录，现在刷不了。${N}"
  say "  官方 fastboot 包的结构是：flash_all.bat 旁边有一个 images/ 文件夹，"
  say "  里面是 abl.elf、super.img、boot.img 等。请把整个 images/ 拷进来。"
  say ""
  DEV_FS="$(df -P "$HERE" 2>/dev/null | awk 'END{print $1}')"
  FS="$(diskutil info "$DEV_FS" 2>/dev/null | awk -F: '/File System Personality/{gsub(/^[ \t]+/, "", $2); print $2}')"
  case "$FS" in
    *FAT*)
      say "  ${Y}注意：本目录所在卷是 ${FS}，单文件上限 4GB，而 super.img 通常 8GB 以上，${N}"
      say "  ${Y}根本放不进来。建议把整个刷机包先解压到 Mac 硬盘（如 ~/Downloads/rom），${N}"
      say "  ${Y}再把本脚本一起拷过去运行。${N}" ;;
    *)
      say "  ${D}把整个 images/ 文件夹拷到本目录即可；也可以整包放到 Mac 硬盘任意位置再运行本脚本。${N}" ;;
  esac
  die "镜像不完整，未对手机做任何操作"
else
  check_begin "镜像文件完整性（$MISSING_TOTAL 个）"
  check_ok
fi

if ! check_device; then
  say ""
  say "  ${Y}没有检测到处于 fastboot 模式的设备：${N}"
  say "    · 手机完全关机 → 同时按住 ${W}音量下 + 电源${N} 约 5 秒，屏幕出现 FASTBOOT 字样"
  say "    · 或用数据线连 Mac 后执行：${W}adb reboot bootloader${N}"
  say "    · 换一根能传数据的线 / 换个 USB 口（别用 hub）"
  die "设备未连接"
fi
say "       序列号 ${D}$DEV_SERIAL${N}"

check_begin "读取设备信息"
DEVP="$("$FASTBOOT" getvar product 2>&1 | tr -d '\r' | sed -n 's/^product: *//p' | head -1)"
UNLOCKED="$("$FASTBOOT" getvar unlocked 2>&1 | tr -d '\r' | sed -n 's/^unlocked: *//p' | head -1)"
SLOT="$("$FASTBOOT" getvar current-slot 2>&1 | tr -d '\r' | sed -n 's/^current-slot: *//p' | head -1)"
check_ok
say "       型号 ${W}${DEVP:-?}${N}  ·  解锁状态 ${W}${UNLOCKED:-?}${N}  ·  当前槽位 ${W}${SLOT:-?}${N}"
log "device: product=$DEVP unlocked=$UNLOCKED slot=$SLOT"

if [ "$UNLOCKED" = "no" ]; then
  say ""
  say "  ${R}Bootloader 处于锁定状态，fastboot 刷机一定会失败。${N}"
  say "  请先在「小米社区 → 解锁」申请并完成 BL 解锁（会清空数据），再来刷机。"
  die "BL 未解锁，未做任何操作"
fi

if [ -n "$PROD" ] && [ "$PROD" != "未知" ] && [ -n "$DEVP" ] && [ "$DEVP" != "$PROD" ]; then
  say ""
  say "  ${R}机型不匹配：脚本针对 ${PROD}，当前设备是 ${DEVP}。${N}"
  say "  刷错包会变砖，已停止。"
  die "机型不匹配"
fi

# ---- 危险确认 ----
printf '\n'
hr
say "${R}${W}开始前请确认${N}"
say "  ${R}·${N} 刷机过程中 ${W}不要拔线、不要断电、不要关盖休眠${N}"
if [ "$WIPE" = yes ]; then
  say "  ${R}·${N} 本方案会 ${R}清空手机内全部数据${N}（照片、微信、应用都没了），请先备份"
else
  say "  ${Y}·${N} 本方案保留用户数据，但仍会重写系统分区"
fi
[ "$LOCK" = yes ] && say "  ${R}·${N} 刷完会 ${R}重新锁定 BL${N}，之后无法再刷第三方/修改版包"
say "  ${R}·${N} 中途报错就停下看日志，不要盲目反复重试"
hr
say ""
printf '%s确认开始，请输入 %sFLASH%s 并回车（其他任意输入取消）：%s' "$Y" "$W" "$Y" "$N"
read -r ans || exit 1
case "$(printf '%s' "$(trim "$ans")" | tr 'a-z' 'A-Z')" in
  FLASH) ;;
  *) say "已取消，未对手机做任何操作。"; exit 0 ;;
esac

# ---- 执行 ----
printf '\n'
hr
say "${W}开始刷机 · $SELBASE · $TOTAL 步${N}"
say "${D}日志：$LOG${N}"
hr
log "=== 开始执行 $SELBASE ==="

START=$(date +%s)
INTERRUPTED=0
STEPFILE="$PLANS/.step"
rm -f "$STEPFILE"
trap 'INTERRUPTED=1; printf "\n\n%s⚠ 已中断。%s\n" "$R" "$N"; printf "设备可能停在 fastboot 或半刷状态，建议重新完整刷一次。\n日志：%s\n" "$LOG"; exit 130' INT TERM

( source "$PLAN" )
RC=$?

trap - INT TERM
EXEC=$(cat "$STEPFILE" 2>/dev/null || printf '0')
END=$(date +%s)
ELAPSED=$((END - START))
if [ "$ELAPSED" -lt 60 ]; then COST="${ELAPSED} 秒"; else COST="$((ELAPSED / 60)) 分 $((ELAPSED % 60)) 秒"; fi

printf '\n'
hr
if [ "$RC" -eq 0 ]; then
  log "=== 完成 $SELBASE 执行 $EXEC/$TOTAL 步 用时 $COST ==="
  say "${G}✓ 刷机流程已执行完毕${N}  （执行 $EXEC 步 / 计划 $TOTAL 步，用时 ${COST}）"
  [ "$EXEC" -lt "$TOTAL" ] && say "  ${D}差的 $((TOTAL - EXEC)) 步是设备上没有对应分区（如 opcust），脚本按原逻辑自动跳过了${N}"
  hr
  say "  · 手机正在重启，首次开机可能要 ${W}5～15 分钟${N}，期间别断电"
  say "  · 如果卡在开机动画超过 20 分钟，重新线刷一次「保留数据」方案试试"
  [ "$LOCK" = yes ] && say "  · BL 已回锁，之后无法再刷第三方/修改版包"
  say "  · 日志：$LOG"
else
  log "=== 失败 $SELBASE rc=$RC 停在第 $EXEC 步 用时 $COST ==="
  say "${R}✗ 刷机中断/失败${N}  （停在第 $EXEC 步 / 共 $TOTAL 步，用时 ${COST}）"
  hr
  say "  失败前最后一步请对照上面输出与日志。常见原因："
  say "    · 线材/接口不稳：换原装线、直插 Mac、别用 hub"
  say "    · 镜像损坏：重新解压刷机包（校验 md5）"
  say "    · 防回滚/机型不匹配：换对应的包"
  say "  ${W}处理完可以重新运行本脚本，从头完整刷一遍${N}（已写入的分区重写无害）。"
  say "  · 日志：$LOG"
fi
hr
say "${D}转换结果：$PLANS${N}"
printf '\n'
[ "$RC" -eq 0 ] || exit "$RC"
