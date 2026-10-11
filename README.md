# simfile

一个 macOS 命令行小工具：把 iOS 模拟器内部那几个「方便往里拖文件」的目录，直接在 Finder 里打开。

模拟器里的沙盒目录埋在 `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/...` 深处，路径里还夹着随机 UUID，手工翻找很麻烦。本工具负责定位这些目录并调用 `open` 打开，支持三种目标目录：

| 模式 | 打开的位置 | 用途 |
| --- | --- | --- |
| 共享目录（默认） | 模拟器「文件」App 里「我的 iPhone」的根目录 | 把文件拖进去，模拟器「文件」App 就能看到 |
| 应用目录（`-a`） | 指定 App 沙盒的 `Documents` 目录 | 给某个 App 灌入数据文件 |
| 相册目录（`-P`） | 「照片」App 的相册存储目录 | 查看 / 管理照片文件；配合 `-i` 真正导入相册 |

工具会先列出本机所有模拟器（区分运行中 / 未运行）让你选择，也支持用名字或 UDID 直接指定，跳过交互。

## 环境要求

- macOS
- zsh（脚本使用 zsh 专有语法，shebang 为 `/bin/zsh`，不要用 bash 执行）
- Xcode 命令行工具（提供 `xcrun simctl`）
- `python3`（仅用于解析 App 列表）
- `plutil`、`open`（macOS 自带）

## 安装

脚本可以直接在当前目录运行：

```sh
./open-sim-files.sh
```

想在任何目录下用短命令调用，把它软链到 PATH 中的某个目录即可（`~/.local/bin` 需已在 PATH 中）：

```sh
ln -sfn "$PWD/open-sim-files.sh" ~/.local/bin/simfile
```

用软链接而非拷贝，后续修改脚本立即生效，不需要重新安装。

## 使用说明

```
simfile                   共享目录，交互式选择模拟器
simfile -a                应用目录，交互式选择模拟器 + App
simfile -a <名字|UDID>    应用目录，指定模拟器，再交互式选 App
simfile -b <bundle|名字>  应用目录，指定 App，再交互式选模拟器
simfile <名字|UDID>       共享目录，直接打开指定模拟器
simfile -P                相册目录，交互式选择模拟器
simfile -P <名字|UDID>    相册目录，直接打开指定模拟器
simfile -i <文件...>      把文件导入相册（交互式选择模拟器）
simfile <名字|UDID> -i <文件...>   指定模拟器导入相册
simfile -P -i <文件...>   先导入相册，再打开相册目录
simfile -l                只列出模拟器，不选择
simfile -p ...            只打印目录路径，不开 Finder
simfile -h                显示帮助
```

### 参数

| 参数 | 说明 |
| --- | --- |
| `-a`, `--app` | 打开 App 的 `Documents` 目录 |
| `-b`, `--bundle` | 指定 App（bundle id 或名字），隐含 `-a` |
| `-P`, `--photos` | 打开相册目录 |
| `-i`, `--import` | 把后续参数当作文件，导入模拟器相册 |
| `-l`, `--list` | 只列出模拟器 |
| `-p`, `--print-path` | 只打印路径，不打开 Finder |
| `-h`, `--help` | 显示帮助 |

不带参数的裸参数会被当作模拟器名字或 UDID。

### 例子

```sh
# 列出所有模拟器
simfile -l

# 打开 iPhone 17 Pro 的「我的 iPhone」目录
simfile "iPhone 17 Pro"

# 给某台模拟器上的 App 灌数据，先选模拟器再选 App
simfile -a

# 指定 App 并只打印路径，不开 Finder（模拟器仍会让你选）
simfile -p -b com.example.demo

# 往运行中的模拟器相册导入两张照片，并打开相册目录
simfile "iPhone 17 Pro" -P -i ~/Pictures/a.jpg ~/Pictures/b.png
```

### 匹配规则

- 模拟器名字需**完整匹配**；UDID 支持**前缀**匹配（大小写不敏感）。
- App 的 bundle id 或显示名均可，需完整匹配。
- 匹配到多台 / 多个时不会猜测，脚本会列出候选并退出，请用 UDID 或 bundle id 精确定位。

### 交互式选择

不带模拟器参数时，脚本会先打印编号列表：

```
运行中的模拟器：
   1) iPhone 17 Pro                [iOS 26.5]  Booted

未运行的模拟器：
   2) iPhone 18 Pro                [iOS 27.0]  Shutdown
```

输入编号回车即可；直接回车或输入 `q` 退出。应用模式会再列出该模拟器上安装的 App，只包含你自己安装的应用（不含系统 App），开启了文件共享（`UIFileSharingEnabled`）的会打上 `[文件共享]` 标记。

## 目录定位原理

| 模式 | 宿主侧路径 |
| --- | --- |
| 共享目录 | `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/Shared/AppGroup/<UUID>/File Provider Storage/` |
| 应用目录 | `xcrun simctl get_app_container <UDID> <bundle-id> data` 得到的容器下的 `Documents/` |
| 相册目录 | `~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Media/DCIM/100APPLE` |

共享目录的 `<UUID>` 每台设备不同，脚本通过读取 AppGroup 容器元数据、匹配标识 `group.com.apple.FileProvider.LocalStorage` 动态定位。

目标目录尚不存在时（容器已建、系统还没创建子目录），脚本会 `mkdir -p` 补一个空目录，这只是普通文件夹，不影响模拟器。

## 注意事项

- **导入相册用 `-i`，不要手工拖。** 往 `100APPLE` 里直接拖文件不一定会被「照片」App 收进相册；`-i` 调用 `xcrun simctl addmedia` 才会真正导入。因此 `-i` 要求模拟器已启动，未启动时脚本会提示 `xcrun simctl boot <UDID>`。
- **`-i` 后面的参数一律当作文件**，所以模拟器名要写在 `-i` 前面。

  ```sh
  simfile "iPhone 17 Pro" -i photo.jpg     # 正确
  simfile -i "iPhone 17 Pro" photo.jpg     # 错误，会把模拟器名当文件
  ```

- **共享目录找不到时**，通常是该模拟器从未启动过。先用 Xcode 启动一次，并在模拟器「文件」App 里打开一次「我的 iPhone」，再重试。
- **App 数据目录找不到时**，通常是这个 App 从未在模拟器里启动过，先启动一次再重试。
- 打开共享目录后若模拟器「文件」App 里没立刻出现新文件，下拉刷新即可。

## 文件结构

```
.
├── open-sim-files.sh   # 主脚本，全部逻辑都在这里
├── .gitignore
└── README.md
```

脚本按功能分段：基础工具（`die` / `usage`）、设备枚举、应用枚举、目录解析、选择界面、打开目录、主流程。
