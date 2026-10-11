#!/bin/zsh
#
# open-sim-files.sh
#
# 在 Finder 中打开 iOS 模拟器里、方便往里拖文件的目录。三种模式：
#
#   1) 共享目录（默认）：模拟器「文件」App ->「我的 iPhone」的根目录。
#      宿主侧路径：
#        ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Shared/AppGroup/<UUID>/File Provider Storage/
#      其中 AppGroup 标识为 group.com.apple.FileProvider.LocalStorage（UUID 每台设备不同，需动态查找）。
#
#   2) 应用目录（-a）：指定某个 App，打开它的 Documents 目录。
#      宿主侧路径：<App 数据容器>/Documents，数据容器由
#        xcrun simctl get_app_container <UDID> <bundle-id> data
#      解析得到。
#
#   3) 相册目录（-P）：打开模拟器「照片」App 的相册目录，也就是照片 / 视频
#      文件实际存放的位置。宿主侧路径：
#        ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Media/DCIM/100APPLE
#      同模式下还可以用 -i 把文件真正导入相册：
#        xcrun simctl addmedia <UDID> <文件...>   （要求模拟器已启动）
#      注意：往 100APPLE 里手工拖文件不一定会被「照片」App 收进相册，
#      要保证导入成功请用 -i。
#
# 用法：
#   ./open-sim-files.sh                   共享目录，交互式选择模拟器
#   ./open-sim-files.sh -a                应用目录，交互式选择模拟器 + App
#   ./open-sim-files.sh -a <名字|UDID>    应用目录，指定模拟器，再交互式选 App
#   ./open-sim-files.sh -b <bundle|名字>  应用目录，指定 App，再交互式选模拟器
#   ./open-sim-files.sh <名字|UDID>       共享目录，直接打开指定模拟器
#   ./open-sim-files.sh -P                相册目录，交互式选择模拟器
#   ./open-sim-files.sh -P <名字|UDID>    相册目录，直接打开指定模拟器
#   ./open-sim-files.sh -i <文件...>      把文件导入相册（交互式选择模拟器）
#   ./open-sim-files.sh <名字|UDID> -i <文件...>   指定模拟器导入相册
#   ./open-sim-files.sh -P -i <文件...>   先导入相册，再打开相册目录
#   ./open-sim-files.sh -l                只列出模拟器，不选择
#   ./open-sim-files.sh -p ...            只打印目录路径，不开 Finder
#   ./open-sim-files.sh -h                帮助
#
# 提示：-i 后面的参数一律当作要导入的文件，所以模拟器要写在 -i 前面。

set -u
set -o pipefail

DEVICES_ROOT="$HOME/Library/Developer/CoreSimulator/Devices"
LOCAL_STORAGE_GROUP="group.com.apple.FileProvider.LocalStorage"
STORAGE_DIR_NAME="File Provider Storage"
PHOTOS_ALBUM_DIR_NAME="100APPLE"

typeset -a DEV_NAME DEV_UDID DEV_STATE DEV_RUNTIME
typeset -a APP_NAME APP_BUNDLE APP_SHARING

# ---------------------------------------------------------------- 基础工具

die() { print -ru2 -- "$*"; exit 1; }

usage() {
  cat <<'EOF'
open-sim-files.sh -- 打开 iOS 模拟器里方便拖文件的目录

默认打开「文件」App ->「我的 iPhone」的根目录；加 -a 则打开某个 App 的
Documents 目录；加 -P 则打开「照片」App 的相册目录。三者都会先列出模拟器
（运行中 / 未运行）供你选择。

用法：
  ./open-sim-files.sh                   共享目录，交互式选择模拟器
  ./open-sim-files.sh -a                应用目录，交互式选择模拟器 + App
  ./open-sim-files.sh -a <名字|UDID>    应用目录，指定模拟器，再交互式选 App
  ./open-sim-files.sh -b <bundle|名字>  应用目录，指定 App，再交互式选模拟器
  ./open-sim-files.sh <名字|UDID>       共享目录，直接打开指定模拟器
  ./open-sim-files.sh -P                相册目录，交互式选择模拟器
  ./open-sim-files.sh -P <名字|UDID>    相册目录，直接打开指定模拟器
  ./open-sim-files.sh -i <文件...>      把文件导入相册，交互式选择模拟器
  ./open-sim-files.sh <名字|UDID> -i <文件...>   指定模拟器导入相册
  ./open-sim-files.sh -P -i <文件...>   先导入相册，再打开相册目录
  ./open-sim-files.sh -l                只列出模拟器，不选择
  ./open-sim-files.sh -p ...            只打印目录路径，不开 Finder
  ./open-sim-files.sh -h                显示本帮助

模拟器名字需完整匹配（可用 UDID 或其前缀）；App 可用 bundle id 或名字完整匹配。
应用模式只列出你自己安装的 App（不含系统 App），带 [文件共享] 标记的表示
它开启了 UIFileSharingEnabled，放进 Documents 的文件在「文件」App 里也能看到。

相册模式的 -i 会调用 xcrun simctl addmedia 把文件真正导入「照片」App，因此
要求模拟器处于启动状态；-i 后面的参数一律当作要导入的文件（照片 / 视频 /
联系人 .vcf），所以模拟器名要写在 -i 前面。往相册目录里手工拖文件不一定会
被「照片」App 收进相册，要保证导入成功请用 -i。
EOF
}

# ---------------------------------------------------------------- 设备枚举

load_devices() {
  DEV_NAME=() DEV_UDID=() DEV_STATE=() DEV_RUNTIME=()
  local line runtime="" out
  out="$(xcrun simctl list devices 2>/dev/null)" || die "无法执行 xcrun simctl，请确认已安装 Xcode 命令行工具。"

  while IFS= read -r line; do
    if [[ $line == '-- '* ]]; then
      runtime=${line#-- }
      runtime=${runtime% --}
      continue
    fi
    if [[ $line =~ '^ +(.+) \(([0-9A-Fa-f-]{36})\) \(([A-Za-z ]+)\) *$' ]]; then
      DEV_NAME+=("$match[1]")
      DEV_UDID+=("$match[2]")
      DEV_STATE+=("$match[3]")
      DEV_RUNTIME+=("$runtime")
    fi
  done <<< "$out"
}

is_running() {
  [[ "$1" == "Booted" || "$1" == "Booting" ]]
}

# ---------------------------------------------------------------- 应用枚举

# 列出该模拟器上用户自己安装的 App（排除系统 App），
# 结果写入 APP_NAME / APP_BUNDLE / APP_SHARING。
load_apps() {
  local udid="$1"
  APP_NAME=() APP_BUNDLE=() APP_SHARING=()
  local name bid share
  while IFS=$'\t' read -r name bid share; do
    [[ -n "$bid" ]] || continue
    APP_NAME+=("$name")
    APP_BUNDLE+=("$bid")
    APP_SHARING+=("$share")
  done < <(xcrun simctl listapps "$udid" 2>/dev/null \
           | plutil -convert json -o - - 2>/dev/null \
           | python3 -c '
import json, sys, plistlib, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = []
for bid, v in d.items():
    if not isinstance(v, dict) or v.get("ApplicationType") != "User":
        continue
    name = v.get("CFBundleDisplayName") or v.get("CFBundleName") or bid
    share = ""
    try:
        with open(os.path.join(v.get("Path", ""), "Info.plist"), "rb") as f:
            pl = plistlib.load(f)
        if pl.get("UIFileSharingEnabled") or pl.get("LSSupportsOpeningDocumentsInPlace"):
            share = "1"
    except Exception:
        pass
    rows.append((name.replace("\t", " "), bid, share))
for name, bid, share in sorted(rows, key=lambda r: r[0].lower()):
    print("\t".join((name, bid, share)))
')
}

# ---------------------------------------------------------------- 目录解析

# 找到该模拟器「我的 iPhone」对应的宿主目录，成功则打印路径。
resolve_storage_dir() {
  local udid="$1"
  local device_dir="$DEVICES_ROOT/$udid"
  local app_group_root="$device_dir/data/Containers/Shared/AppGroup"

  [[ -d "$device_dir" ]] || return 1
  [[ -d "$app_group_root" ]] || return 1

  local meta group_dir
  for meta in "$app_group_root"/*/.com.apple.mobile_container_manager.metadata.plist(N); do
    if [[ "$(plutil -extract MCMMetadataIdentifier raw -o - "$meta" 2>/dev/null)" == "$LOCAL_STORAGE_GROUP" ]]; then
      group_dir="${meta:h}"
      break
    fi
  done

  [[ -n "${group_dir:-}" ]] || return 1

  local storage="$group_dir/$STORAGE_DIR_NAME"
  # 容器已存在但目录还没被系统创建时，补建一个空目录即可（只是普通文件夹）。
  if [[ ! -d "$storage" ]]; then
    mkdir -p "$storage" 2>/dev/null || return 1
  fi

  print -r -- "$storage"
}

# 找到该 App 的 Documents 目录，成功则打印路径。
resolve_app_docs_dir() {
  local udid="$1" bid="$2"
  local data

  data="$(xcrun simctl get_app_container "$udid" "$bid" data 2>/dev/null)"
  [[ -n "$data" && "$data" != "(null)" && -d "$data" ]] || return 1

  local docs="$data/Documents"
  # 有些 App 还没写过 Documents，补建一个空目录即可（只是普通文件夹）。
  if [[ ! -d "$docs" ]]; then
    mkdir -p "$docs" 2>/dev/null || return 1
  fi

  print -r -- "$docs"
}

# 找到该模拟器「照片」App 的相册目录，成功则打印路径。
resolve_photos_dir() {
  local udid="$1"
  local device_dir="$DEVICES_ROOT/$udid"
  local album="$device_dir/data/Media/DCIM/$PHOTOS_ALBUM_DIR_NAME"

  [[ -d "$device_dir" ]] || return 1
  # 设备从没启动过时 Media 目录还不存在，补建一个空目录即可（只是普通文件夹）。
  if [[ ! -d "$album" ]]; then
    mkdir -p "$album" 2>/dev/null || return 1
  fi

  print -r -- "$album"
}

# ---------------------------------------------------------------- 选择界面

# 打印编号列表，并把编号写入全局 PICK_INDEX（1 起）
PICK_INDEX=0
PICK_APP=0

print_choice_list() {
  local i running_count=0
  print -r -- ""
  print -r -- "运行中的模拟器："
  for (( i = 1; i <= ${#DEV_UDID[@]}; i++ )); do
    if is_running "${DEV_STATE[i]}"; then
      printf '  %2d) %-28s [%s]  %s\n' "$i" "${DEV_NAME[i]}" "${DEV_RUNTIME[i]}" "${DEV_STATE[i]}"
      (( running_count++ ))
    fi
  done
  (( running_count > 0 )) || print -r -- "  （无）"

  print -r -- ""
  print -r -- "未运行的模拟器："
  local stopped_count=0
  for (( i = 1; i <= ${#DEV_UDID[@]}; i++ )); do
    if ! is_running "${DEV_STATE[i]}"; then
      printf '  %2d) %-28s [%s]  %s\n' "$i" "${DEV_NAME[i]}" "${DEV_RUNTIME[i]}" "${DEV_STATE[i]}"
      (( stopped_count++ ))
    fi
  done
  (( stopped_count > 0 )) || print -r -- "  （无）"
  print -r -- ""
}

interactive_select() {
  print_choice_list
  local choice
  printf '请选择要打开文件目录的模拟器编号（回车或 q 退出）: '
  read -r choice || return 1
  choice="${choice// /}"
  [[ -z "$choice" || "$choice" == "q" || "$choice" == "Q" ]] && return 1
  [[ "$choice" == <-> ]] || { print -ru2 -- "请输入数字编号。"; return 1; }
  (( choice >= 1 && choice <= ${#DEV_UDID[@]} )) || { print -ru2 -- "编号超出范围。"; return 1; }
  PICK_INDEX=$choice
}

print_app_list() {
  local i tag
  print -r -- ""
  print -r -- "该模拟器上安装的 App："
  for (( i = 1; i <= ${#APP_BUNDLE[@]}; i++ )); do
    tag=""
    [[ "${APP_SHARING[i]}" == "1" ]] && tag="  [文件共享]"
    printf '  %2d) %-24s %s%s\n' "$i" "${APP_NAME[i]}" "${APP_BUNDLE[i]}" "$tag"
  done
  print -r -- ""
}

interactive_select_app() {
  print_app_list
  local choice
  printf '请选择要打开文档目录的 App 编号（回车或 q 退出）: '
  read -r choice || return 1
  choice="${choice// /}"
  [[ -z "$choice" || "$choice" == "q" || "$choice" == "Q" ]] && return 1
  [[ "$choice" == <-> ]] || { print -ru2 -- "请输入数字编号。"; return 1; }
  (( choice >= 1 && choice <= ${#APP_BUNDLE[@]} )) || { print -ru2 -- "编号超出范围。"; return 1; }
  PICK_APP=$choice
}

# 按名字或 UDID 匹配，结果写入全局 PICK_INDEX
match_device() {
  local query="$1"
  local -a matches=()
  local i
  local lower_query="${query:l}"

  for (( i = 1; i <= ${#DEV_UDID[@]}; i++ )); do
    if [[ "${DEV_UDID[i]:l}" == "$lower_query"* || "${DEV_NAME[i]:l}" == "$lower_query" ]]; then
      matches+=("$i")
    fi
  done

  (( ${#matches[@]} > 0 )) || { print -ru2 -- "找不到匹配的模拟器：$query"; return 1; }
  if (( ${#matches[@]} > 1 )); then
    print -ru2 -- "「$query」匹配到多台模拟器，请用 UDID 或更完整的名字指定："
    local m
    for m in "${matches[@]}"; do
      print -ru2 -- "  ${DEV_NAME[m]} [${DEV_RUNTIME[m]}]  ${DEV_UDID[m]}"
    done
    return 1
  fi
  PICK_INDEX="${matches[1]}"
}

# 按 bundle id 或名字匹配，结果写入全局 PICK_APP
match_app() {
  local query="$1"
  local -a matches=()
  local i
  local lower_query="${query:l}"

  for (( i = 1; i <= ${#APP_BUNDLE[@]}; i++ )); do
    if [[ "${APP_BUNDLE[i]:l}" == "$lower_query" || "${APP_NAME[i]:l}" == "$lower_query" ]]; then
      matches+=("$i")
    fi
  done

  (( ${#matches[@]} > 0 )) || { print -ru2 -- "找不到匹配的 App：$query"; return 1; }
  if (( ${#matches[@]} > 1 )); then
    print -ru2 -- "「$query」匹配到多个 App，请用 bundle id 指定："
    local m
    for m in "${matches[@]}"; do
      print -ru2 -- "  ${APP_NAME[m]}  ${APP_BUNDLE[m]}"
    done
    return 1
  fi
  PICK_APP="${matches[1]}"
}

# ---------------------------------------------------------------- 打开目录

open_dir() {
  local dir="$1" hint="$2"
  print -r -- "目录：$dir"
  if [[ "$PRINT_ONLY" == "1" ]]; then
    return 0
  fi
  open "$dir"
  print -r -- "已在 Finder 中打开，把文件拖进去即可。"
  [[ -n "$hint" ]] && print -r -- "$hint"
  return 0
}

open_shared_dir() {
  local idx="$1"
  local name="${DEV_NAME[idx]}" udid="${DEV_UDID[idx]}"
  local dir

  print -r -- ""
  print -r -- "模拟器：$name  [$udid]"

  if ! dir="$(resolve_storage_dir "$udid")"; then
    print -ru2 -- "找不到该模拟器的「我的 iPhone」存储目录。"
    print -ru2 -- "通常是因为它从未启动过：请先用 Xcode 启动一次这台模拟器，"
    print -ru2 -- "在里面的「文件」App 打开一次「我的 iPhone」，然后重试本脚本。"
    return 1
  fi

  open_dir "$dir" "若模拟器「文件」App 里没立刻出现，下拉刷新一下即可。"
}

open_app_dir() {
  local idx="$1" aidx="$2"
  local name="${DEV_NAME[idx]}" udid="${DEV_UDID[idx]}"
  local aname="${APP_NAME[aidx]}" bid="${APP_BUNDLE[aidx]}"
  local dir

  print -r -- ""
  print -r -- "模拟器：$name  [$udid]"
  print -r -- "App：$aname  [$bid]"

  if ! dir="$(resolve_app_docs_dir "$udid" "$bid")"; then
    print -ru2 -- "找不到「$aname」的数据目录。通常是因为它从未在模拟器里启动过；"
    print -ru2 -- "先在模拟器中启动一次这个 App，再重试本脚本。"
    return 1
  fi

  local hint=""
  if [[ "${APP_SHARING[aidx]}" == "1" ]]; then
    hint="该 App 开启了文件共享，放进去的文件在「文件」App 的「我的 iPhone > $aname」里也能看到。"
  fi
  open_dir "$dir" "$hint"
}

open_photos_dir() {
  local idx="$1"
  local name="${DEV_NAME[idx]}" udid="${DEV_UDID[idx]}"
  local dir

  print -r -- ""
  print -r -- "模拟器：$name  [$udid]"

  if ! dir="$(resolve_photos_dir "$udid")"; then
    print -ru2 -- "找不到该模拟器的相册目录。通常是因为它从未启动过："
    print -ru2 -- "请先用 Xcode 启动一次这台模拟器，然后重试本脚本。"
    return 1
  fi

  open_dir "$dir" "提示：往里手工拖文件不一定会被「照片」App 收进相册；要保证导入成功，用本脚本的 -i 导入。"
}

# 用 xcrun simctl addmedia 把文件真正导入该模拟器的相册。
import_media() {
  local idx="$1"; shift
  local name="${DEV_NAME[idx]}" udid="${DEV_UDID[idx]}"
  local -a files=("$@")
  local f

  print -r -- ""
  print -r -- "模拟器：$name  [$udid]"

  # simctl addmedia 需要一个已启动的设备，否则会直接以 LaunchdSimError 失败。
  if ! is_running "${DEV_STATE[idx]}"; then
    print -ru2 -- "该模拟器当前未运行，导入相册需要它处于启动状态，请先启动再重试："
    print -ru2 -- "  xcrun simctl boot $udid"
    return 1
  fi

  for f in "${files[@]}"; do
    [[ -e "$f" ]] || { print -ru2 -- "文件不存在：$f"; return 1; }
  done

  if xcrun simctl addmedia "$udid" "${files[@]}"; then
    print -r -- "已把 ${#files[@]} 个文件导入相册，在模拟器「照片」App 里即可看到。"
    return 0
  fi

  print -ru2 -- "导入相册失败。请确认这些文件是照片 / 视频 / 联系人（.vcf）格式。"
  return 1
}

# ---------------------------------------------------------------- 主流程

main() {
  local print_only=0
  local app_mode=0
  local photos_mode=0
  local bundle_query=""
  local -a args=()
  local -a media_files=()

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; return 0 ;;
      -l|--list) mode_list=1; shift ;;
      -p|--print-path) print_only=1; shift ;;
      -a|--app) app_mode=1; shift ;;
      -P|--photos) photos_mode=1; shift ;;
      -i|--import)
        shift
        (( $# > 0 )) || die "参数 -i 后面要跟至少一个要导入相册的文件。"
        # -i 之后的参数一律当作文件，直到遇到下一个以 - 开头的参数。
        while (( $# > 0 )) && [[ "$1" != -* ]]; do
          media_files+=("$1"); shift
        done ;;
      -b|--bundle)
        (( $# >= 2 )) || die "参数 -b 后面要跟 App 的 bundle id 或名字。"
        bundle_query="$2"; app_mode=1; shift 2 ;;
      --) shift; args+=("$@"); break ;;
      -*) die "未知参数：$1（用 -h 查看用法）" ;;
      *) args+=("$1"); shift ;;
    esac
  done

  load_devices
  (( ${#DEV_UDID[@]} > 0 )) || die "没有找到任何 iOS 模拟器。"

  if [[ "${mode_list:-0}" == "1" ]]; then
    print_choice_list
    return 0
  fi

  PRINT_ONLY=$print_only

  if (( ${#args[@]} > 0 )); then
    match_device "${args[1]}" || return 1
  else
    interactive_select || return 1
  fi

  # 相册模式：-i 先导入，-P 再打开相册目录（两个都可以单独使用）。
  if [[ "$photos_mode" == "1" || ${#media_files[@]} -gt 0 ]]; then
    local rc=0
    if (( ${#media_files[@]} > 0 )); then
      import_media "$PICK_INDEX" "${media_files[@]}" || rc=$?
    fi
    (( rc == 0 )) || return "$rc"
    [[ "$photos_mode" == "1" ]] || return 0
    open_photos_dir "$PICK_INDEX"
    return $?
  fi

  if [[ "$app_mode" != "1" ]]; then
    open_shared_dir "$PICK_INDEX"
    return $?
  fi

  load_apps "${DEV_UDID[PICK_INDEX]}"
  (( ${#APP_BUNDLE[@]} > 0 )) || die "该模拟器上没有安装任何用户 App。"

  if [[ -n "$bundle_query" ]]; then
    match_app "$bundle_query" || return 1
  else
    interactive_select_app || return 1
  fi

  open_app_dir "$PICK_INDEX" "$PICK_APP"
}

PRINT_ONLY=0
mode_list=0
main "$@"
