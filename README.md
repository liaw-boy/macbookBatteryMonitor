# 電池監控 macbookBatteryMonitor

> **status 分支：系統監控整合版（開發中，尚未發布）**
> 在電池功能之外，加上 CPU／GPU、記憶體、磁碟、網路四個系統監控模組，每個模組在選單列各有一個圖示、每秒更新。
> 已發布的版本請到 [Releases](https://github.com/sgeric910601/macbookBatteryMonitor/releases) 下載；要試用這個分支請參考〈從原始碼編譯〉。

macOS 選單列的電池資訊 App
選單列直接顯示電量，點開就能看到剩餘時間、健康度、電力流向（可展開到各硬體的耗電）、充電上限、歷史曲線與耗電排行。

- **只讀取資訊**：不會更動任何充電設定，不需要管理員權限
- **系統監控**（status 分支）：CPU／GPU、記憶體、磁碟、網路，可在設定裡個別開關
- **每秒更新**：選單列與面板上的資訊每 1 秒刷新一次；面板關閉時 CPU 約 0.2%（只有電池）、約 0.9%（再開啟四個系統監控模組），不會阻止系統睡眠
- **不需要 Xcode**：只要 Command Line Tools 就能編譯

## 下載與版本選擇

到 [Releases](https://github.com/sgeric910601/macbookBatteryMonitor/releases) 下載編好的 App。三個版本的電池資訊、通知與充電上限功能相同，差在電力流向與選單列：

| 版本 | 電力流向 | 選單列 | 面板開著時 CPU | 面板關閉時 CPU | 適合 |
|---|---|---|---|---|---|
| [v1.2.2](https://github.com/sgeric910601/macbookBatteryMonitor/releases/tag/v1.2.2)（最新，Full 完整版） | 動畫流向圖，可展開螢幕背光、晶片運算與 CPU／GPU／ANE；所有資訊每秒更新 | 多一種「圖示內百分比 + 剩餘時間」；面板關著時也每秒更新 | 約 4%（展開硬體細項約 4.5%） | 約 0.2% | 想看各硬體的耗電、要即時數字 |
| [v1.1.0](https://github.com/sgeric910601/macbookBatteryMonitor/releases/tag/v1.1.0) | 動畫 Sankey 流向圖，依功率分流 | 四種顯示方式 | 約 3% | 約 0% | 想要較生動的介面 |
| [v1.0.0](https://github.com/sgeric910601/macbookBatteryMonitor/releases/tag/v1.0.0) | 靜態圖示與箭頭 | 四種顯示方式 | 約 1% | 約 0% | 想要最精簡、最省電 |

> CPU 數據為 M1 MacBook Air 實測：面板開著時停在「耗電排行」分頁（v1.0.0／v1.1.0 每 5 秒跑一次 `top`；v1.2.2 持續跑一個 `top` 每秒輸出，`top` 本身另佔約 1%）；v1.2.2 另測了展開晶片細項的情況。面板關閉時，v1.0.0／v1.1.0 每 30 秒更新一次選單列，v1.2.2 每秒更新。

v1.2.2 起所有資訊每秒更新（面板關著時選單列也是）。v1.2.1 修正了 v1.2.0 在 M1 等機型上「變壓器輸入」和「系統＋電池」對不起來的問題。使用 v1.2.0、v1.2.1 的話建議更新到 v1.2.2。

## 安裝

需求：macOS 14 以上、Apple Silicon 的 MacBook（附的 App 為 arm64 版本）。

1. 從 Releases 下載 `macbookBatteryMonitor-<版本>-macOS-arm64.zip`，解壓縮
2. 把 `macbookBatteryMonitor.app` 拖到「應用程式」資料夾
3. 第一次打開時 macOS 會擋下來（App 沒有 Apple 開發者簽章）。任選一種方式放行：
   - 到「系統設定 → 隱私權與安全性」，在下方找到這個 App，按「強制打開」
   - 或在終端機執行：
     ```bash
     xattr -dr com.apple.quarantine /Applications/macbookBatteryMonitor.app
     ```
4. 第一次啟動會詢問通知權限，並自動加入開機自啟動（可在設定關閉）

要換版本時，結束 App 後用另一個版本的 `.app` 覆蓋即可，設定與歷史資料會保留。

## 功能

**選單列**（設定 → 選單列 → 顯示方式）
- 圖示 + 百分比、只有圖示、只有百分比、圖示 + 剩餘時間
- 圖示內百分比 + 剩餘時間（v1.2 起）：電量顯示在電池圖示裡，右側是剩餘／充滿時間；沒有時間資料顯示「—」，滿電、接電未充電、到達上限時分別顯示「已充飽」、「接電」、「已達上限」
- 充電中顯示閃電、接電未充電顯示插頭、低電量變紅

**面板**
- 電量、充放電狀態、剩餘時間／充滿時間（有充電上限時顯示充到上限的時間）
- 預估用到 0% 與**用到 10%** 的時間：系統預估 + 依近 3 分鐘平均耗電推算
- 已使用電池多久（這次拔掉電源後）
- 電力流向：變壓器、系統、電池之間的瓦數
- 系統細項（v1.2 起）：展開成螢幕背光、晶片運算、其他（估算）；點晶片再展開 CPU／GPU／ANE
- 詳細資訊：電壓、電流、電池功率、系統耗電、系統預估、溫度、健康度、循環次數、容量（mAh）、變壓器、充電上限
- 電量歷史圖表（1 小時／24 小時／7 天，第一次啟動會用 `pmset` 紀錄回填過去幾天）
- 耗電排行：前 5 名 App，同一個 App 的子程序會合併，每秒更新

**系統監控模組**（status 分支，設定 → 系統監控，可個別開關）
- CPU／GPU：選單列顯示 CPU 與 GPU 使用率；面板有使用者／系統比例、最近 2 分鐘曲線、各核心（效能核心、節能核心）、GPU 記憶體、平均負載、CPU 使用率最高的 App
- 記憶體：選單列顯示使用率（記憶體壓力升高時變橘、變紅）；面板有 App 記憶體、系統保留、已壓縮、檔案快取、可用的組成，以及最近 2 分鐘曲線、Swap、使用記憶體最多的 App
- 磁碟：選單列顯示開機磁碟的已使用比例；面板有已使用／可用容量、讀寫速度與曲線、開機以來的累計讀寫
- 網路：選單列顯示上傳與下載速度；面板有目前的網路介面（Wi-Fi、乙太網路）與 IP、速度曲線、開機以來的累計流量
- 同一個 App 的子程序（例如瀏覽器分頁）會合併到 App 名下

**其他**
- 顯示 macOS 的充電上限（系統設定 → 電池 → 電池健康度與充電）：已達上限、充到上限的時間、高於上限時降到上限的時間
- 低電量／充電完成通知（門檻可調；到達系統充電上限也會通知）
- 開機自動啟動

## 使用方式

- **左鍵**點選單列圖示：打開面板
- **右鍵**：打開面板、設定、結束
- **電力流向**（v1.2 起）：點「系統」展開硬體細項，點「晶片運算」再展開 CPU／GPU／ANE
- **系統監控模組**（status 分支）：左鍵打開該模組的面板，右鍵打開設定或結束；按住 ⌘ 可以拖曳調整圖示在選單列的順序
- **設定**：選單列顯示方式、系統監控模組開關、通知門檻、開機自啟動；充電上限由 macOS 控制，App 只讀取顯示，可從設定頁跳到系統設定修改

## 電力總覽與硬體功耗（v1.2 起）

面板主頁每 1 秒取樣一次，關閉面板、進入設定頁或睡眠時停止取樣。讀取不需要管理員權限。

**電力總覽**（變壓器、系統、電池）

- **變壓器輸入**讀 SMC `PDTR`，**系統耗電**讀 SMC `PSTR`
- **電池功率**用「變壓器輸入 − 系統耗電」推算，所以三個數字一定對得起來。SMC 的 `PPBR` 在 M1 MacBook Air 上不是帶正負號的電池功率（充電約 13 W 時只讀到 1～2 W），只在讀不到 `PSTR` 時備援
- 剛拔電時 `PDTR` 可能殘留舊值，只在系統確認接電時才計入輸入
- macOS 放電到充電上限時會暫停變壓器供電，此時仍視為接電，顯示「已達充電上限」
- SMC 數值即時更新，不會像電池晶片（IORegistry）那樣插拔後延遲約一分鐘；電流由電池功率與電壓換算並以 ≈ 標示。插拔通知後會在 1、3、6 秒各重讀一次

**硬體細項**

- **系統總功耗**：優先讀取 SMC `PSTR`，不可用時退回 IORegistry 的 `SystemLoad`
- **螢幕背光**：讀取 SMC 感測器
- **CPU／GPU／ANE**：IOReport Energy Model 的能量差除以實際取樣時間；首次取樣只建立基準
- **其他（估算）**：總功耗扣掉背光與已取得的晶片功耗後的差值；缺晶片細項時改標示「未分類（估算）」，裡面也包含缺少的項目
- 晶片合計只涵蓋取得的 CPU、GPU、ANE，不代表完整 SoC 功耗，也不含外接螢幕

IOReport 是系統私有介面，可用性依晶片與 macOS 版本而異，讀不到的項目顯示「—」：

| 機型 | 系統總功耗 | 背光 | GPU | CPU | ANE |
|---|---|---|---|---|---|
| M2 Pro | ✓ | ✓ | ✓ | 顯示 0 W（通道未持續更新） | 閒置時 0 W |
| M1 MacBook Air | ✓ | — | ✓ | 顯示 0 W（通道未持續更新） | — |

## 更新頻率與省電設計

所有即時資訊每 1 秒更新，但每次只做必要的讀取。M1 MacBook Air 實測：

| 情況 | CPU |
|---|---|
| 面板關閉，只有電池 | 約 0.2% |
| 面板關閉，電池＋四個系統監控模組（status 分支） | 約 0.9% |
| 打開電池面板（耗電排行分頁） | 約 4%（`top` 本身另佔約 1%） |
| 打開 CPU 或記憶體模組面板 | 約 6～9%（含每秒的 `top` 排行） |

- 面板關著時每秒更新選單列需要的資料（電量、狀態、功率、剩餘時間）；插拔電源另由系統通知立即更新
- 選單列圖示只有在數字、時間或狀態改變時才重畫
- SMC 每個 key 的格式查過一次就記住，之後每個數值只需一次 SMC 呼叫；`PPBR` 只在讀不到 `PSTR` 時才讀
- 變壓器規格接上電源後每 30 秒查一次（額定瓦數不會每秒改變）；充電上限檔案用 `stat()` 確認修改時間，變了才重新解析
- 面板每次打開才建立，關閉就連同視窗整個釋放，背景沒有任何畫面在更新
- 硬體細項與 SMC 溫度只在面板開著時讀
- 耗電排行只在面板開著且停在該分頁時，持續跑一個 `top` 每秒輸出；切換分頁或關閉面板就停止
- 流向動畫由 Core Animation 合成（不逐幀更新 SwiftUI），只在面板開著且該線路有供電時播放；支援「減少動態效果」
- 系統監控模組（status 分支）只取樣有開啟的模組；選單列圖示寬度固定，換數字時不會讓整條選單列重新排版
- 磁碟容量每秒用 `statfs()` 讀（幾微秒），系統可清出的空間（查一次約 12 毫秒）每 5 分鐘校正一次；網路只查目前使用中的介面
- CPU 與記憶體的 App 排行只在該模組面板開著時，持續跑一個 `top` 每秒輸出；關閉面板就停止
- 不是即時讀數的資料不必每秒查：電量歷史每分鐘記一筆（每 15 分鐘寫一次檔，睡眠前和結束時也會存）；健康度每 6 小時查一次（`system_profiler` 每次約需 0.5 秒，健康度以週為單位變化）

## 資料來源

| 項目 | 來源 |
|---|---|
| 電量、電壓、原始電流、容量、循環次數 | IORegistry `AppleSmartBattery` |
| 外部輸入、系統功耗、背光 | SMC（唯讀，`PDTR`、`PSTR`、`PDBR`／`PBwo`） |
| 電池功率 | 由「外部輸入 − 系統功耗」推算；讀不到 `PSTR` 時改用 SMC `PPBR`，再不行用 IORegistry 電流 × 電壓 |
| CPU／GPU／ANE 功耗 | IOReport Energy Model 的能量差與實際取樣時間 |
| 系統預估時間、充電狀態 | IOKit Power Sources |
| 健康度（最大容量）、電池狀況 | `system_profiler SPPowerDataType` |
| 溫度 | SMC（唯讀，`TB0T`～`TB2T`） |
| 耗電排行 | `top -o power` |
| 歷史回填、拔電時間 | `pmset -g log` |
| 充電上限 | `/Library/Preferences/com.apple.powerd.charging.plist`（唯讀；macOS 拔電後會清空，App 會記住上次接電時讀到的值） |
| CPU 使用率、各核心 | `host_processor_info` 的累計 tick 差值；核心類型來自 `hw.perflevel0／1` |
| 平均負載 | `getloadavg` |
| GPU 使用率、GPU 記憶體 | IORegistry `IOAccelerator` 的 `PerformanceStatistics` |
| 記憶體組成、壓力、Swap | `host_statistics64`、`kern.memorystatus_vm_pressure_level`、`vm.swapusage` |
| 磁碟容量 | `statfs()`，加上定期校正的系統可清出空間（與 Finder 一致） |
| 磁碟讀寫 | IORegistry `IOBlockStorageDriver` 的累計讀寫位元組 |
| 網路速度與累計流量 | `sysctl` 的 64 位元介面計數器（`NET_RT_IFLIST2`），只查目前使用中的介面 |
| 網路介面與 IP | `SCDynamicStore`（預設路由介面）、`getifaddrs` |
| CPU／記憶體 App 排行 | `top -o cpu`、`top -o mem` |

## 資料存放位置

- 歷史紀錄：`~/Library/Application Support/BatteryMonitor/history.json`（保留 7 天）
- 設定：`com.kuan.batterymonitor`（UserDefaults）

## 解除安裝

1. 在 App 設定裡關閉「開機時自動啟動」，然後結束 App
2. 刪除 `/Applications/macbookBatteryMonitor.app`
3. （選擇性）清除資料：
   ```bash
   rm -rf ~/Library/Application\ Support/BatteryMonitor
   defaults delete com.kuan.batterymonitor
   ```

## 從原始碼編譯

只需要 Command Line Tools（`xcode-select --install`），不需要 Xcode。

```bash
git clone https://github.com/sgeric910601/macbookBatteryMonitor.git
cd macbookBatteryMonitor
git checkout v1.2.2          # 或 v1.1.0、v1.0.0；status 是系統監控整合版，不指定就是最新的開發版
./build.sh                   # 產生 build/macbookBatteryMonitor.app
./build.sh install           # 安裝到 /Applications 並啟動
```

## 開發

```bash
Scripts/test-power.sh    # 換算、供電狀態切換、生命週期、動畫與系統監控計算測試（Command Line Tools 可執行）
```

除錯用參數：

```bash
APP=/Applications/macbookBatteryMonitor.app/Contents/MacOS/macbookBatteryMonitor
$APP --dump              # 目前讀到的資料印成 JSON
$APP --dump-hardware     # 每秒輸出硬體功耗，共五筆 JSON
$APP --snapshot <資料夾>  # 在螢幕外把面板各分頁畫成 PNG
$APP --selftest-panel    # 自動開面板 20 秒再關，量測耗電用
$APP --selftest-hardware # 展開晶片、切換設定頁，確認取樣會停止與恢復
$APP --dump-monitors     # 系統監控模組的讀數（間隔 1 秒取樣兩次）印成 JSON
$APP --selftest-monitors # 依序打開 CPU、記憶體模組面板各 10 秒再關，量測耗電用
```

只裝 Command Line Tools 時沒有 SwiftUI 的 macro 外掛，所以程式裡不用 `@State`，介面狀態集中在 `PanelState`。
