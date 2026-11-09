# 小米线刷助手 · macOS

在 macOS 上直接跑小米官方线刷包里的 `flash_all.bat`，不用装 Windows、不用开虚拟机。

脚本运行时读取**同一目录**下的 `flash_*.bat`，逐行翻译成 macOS 的 `fastboot` 命令，让你选方案后刷机。原始 `.bat` 不会被修改。

## 为什么不用官方的 .sh

官方 fastboot 包里已经有 `flash_all.sh`，但它在 macOS 上有个坑：第 9 行用 GNU grep 的 PCRE 语法取防回滚版本号

```sh
ver=`fastboot $* getvar anti 2>&1 | grep -oP "anti: \K[0-9]+"`
```

macOS 自带的是 BSD grep，不认 `-P`：

```
grep: invalid option -- P
```

于是 `ver` 变成空值、被下面的 `if [ -z "$ver" ]; then ver=0; fi` 兜成 0 —— 脚本照常往下刷，但**防回滚校验实际上失效了**。这种静默降级在刷机场景里是最危险的，所以本脚本用 BSD 兼容的写法重新实现了这段判断。

## 功能

- **运行时解析 BAT**，不改原文件；能处理小米包的这些写法：
  - `fastboot %* ...`（含 `%*` 参数占位）
  - `... 2>&1 | findstr /r /c:"..."` → `grep -E`
  - `|| @echo "..." && exit 1` → 失败即停
  - `if %errorlevel% equ 0 ( ... )` 多行条件块（递归翻译）
  - `for /f "tokens=..." ... do (set VAR=...)` → 取值赋给 shell 变量
  - `if [%VAR%] EQU []`、`if %a% GTR %b%` → 默认值 / 防回滚比较
  - `%~dp0images\xxx.img` → `images/xxx.img`
- **交互式选方案**，自动算出每个方案的真实步数与是否清数据
- **刷机前体检**：fastboot 是否可用、镜像是否齐全、设备是否在 fastboot、机型代号是否匹配、BL 是否解锁、防回滚、二次确认
- **执行**：`[12/46] 写入 abl_ab ← abl.elf` 逐条进度，输出与日志双写，任何一步失败立即停住且不重启
- **可复核**：翻译结果落盘为计划文件，`--dry-run` 或菜单里 `v` 可查看每一行对应关系

## 三个方案

以 `vermeer`（红米 K70 Pro / POCO F6 Pro 系）官方包为例：

| 脚本 | 步骤 | 行为 |
| --- | --- | --- |
| `flash_all.bat` | 46 | 全量线刷，写 `super`/`userdata`，**清空全盘**，刷完重启 |
| `flash_all_except_storage.bat` | 43 | 不写 `userdata`、不清 `metadata`，**保留用户数据** |
| `flash_all_lock.bat` | 46 | 全量 + `oem lock`，刷完**重新锁定 BL** |

步数按包内容算，不同机型会不同。

## 使用

1. **准备刷机包**：官方 fastboot 包解压后，`images/` 文件夹与 `flash_all.bat` 同级。
2. **把本脚本放进同一个目录**：

   ```bash
   cd ~/Downloads/vermeer          # 解压后的刷机包目录
   curl -O https://raw.githubusercontent.com/HarmonyHI/xiaomi-flash-macos/main/小米线刷助手.command
   chmod +x 小米线刷助手.command
   ```

3. **手机进 fastboot**：完全关机 → 按住 `音量下 + 电源` 约 5 秒，屏幕出现 `FASTBOOT`。
4. **双击 `小米线刷助手.command`**（或终端里 `./小米线刷助手.command`）。
5. 选方案 → 看预检结果 → 输入 `FLASH` 回车。

### 参数

```bash
./小米线刷助手.command               # 交互式
./小米线刷助手.command --dry-run     # 只解析预览，不刷机（换机型包时建议先跑这个）
./小米线刷助手.command --plan 2      # 直接选第 2 个方案
./小米线刷助手.command --help
```

环境变量：`FB_PATH=/path/to/fastboot` 指定 fastboot；`IMAGES_DIR=/path/to/images` 指定镜像目录。

日志与翻译结果：`~/xiaomi-flash-logs/`

## 换其他机型的包

理论上任何小米 fastboot 包的 `flash_*.bat` 都能解析。如果包里出现本脚本不认识的语句，会以 `⚠ 无法识别的语句，已跳过` 标出并在菜单里提示行数 —— **先用 `--dry-run` 看一眼转换结果**，确认没有漏掉关键步骤再刷。

## 注意

- 刷机有变砖风险，**自己承担**。刷之前确认包和机型对得上。
- `flash_all` / `flash_all_lock` 会清空手机全部数据，先备份。
- 必须 BL 已解锁，否则 fastboot 一律拒绝写入。
- 设备防回滚版本高于包内 `anti_version.txt` 时会直接拒绝（强刷可能变砖）。
- **别把刷机包放 FAT32 U 盘**：单文件上限 4GB，而 `super.img` 通常 8GB 以上，放不进去。镜像放本机硬盘（APFS/exFAT）。
- 刷机过程中别拔线、别关盖休眠。

## License

[MIT](LICENSE)
