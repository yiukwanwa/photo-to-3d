# 相片變3D（Photo to 3D）— SketchUp 擴充功能

揀一張物件相，AI 幫你變成有顏色嘅 3D 模型，直接放入 SketchUp。

## 三個 AI 引擎（混合模式）

| 引擎 | 喺邊度運行 | 收費 | 效果 |
|---|---|---|---|
| **Hunyuan3D-2 mini** | 你部電腦（本機） | 免費 | 形狀清晰；顏色跟相片 |
| **TripoSR** | 你部電腦（本機） | 免費 | 最快；形狀圓滑啲；AI 估埋背面顏色 |
| **Meshy 7.1** | 雲端 | 付費（每個約 30 credits） | 細節最多、最平滑、有真實相片貼圖，最似相 |

本機引擎完全離線，張相唔會離開你部電腦。Meshy 會將相片上載到 Meshy 伺服器，要用你自己嘅 Meshy 付費計劃 API key。

## 需要咩

- Windows 10 / 11（64 位元）
- SketchUp 2021 或更新
- NVIDIA 顯示卡 6 GB 或以上（RTX 3060 / 3060 Ti 好夠），驅動程式要新
- 16 GB RAM，大約 20 GB 硬碟空間
- 安裝時要上網（大約下載 11 GB）

## 安裝（喺另一部電腦）

1. 將 **`dist\PhotoTo3D.rbz`** 抄去嗰部電腦。
2. 開 SketchUp → **Extensions（擴充功能）→ Extension Manager → Install Extension**，揀 `PhotoTo3D.rbz`。
3. 撳工具列嘅 **相片變3D** 掣，開個視窗。
4. 第一次會見到「要先安裝 AI」→ 撳 **安裝 AI**。會彈出一個安裝視窗，自動裝晒（20–40 分鐘）。
5. 裝完之後，喺相片變3D 視窗撳 **再檢查**，就用得。

（另一個方法：抄成個 `PhotoTo3D` 資料夾過去，關咗 SketchUp，雙擊 `install.bat`，佢會連擴充功能一齊裝。）

AI 會裝喺 `%LOCALAPPDATA%\PhotoTo3D`。再裝一次可以修復或者更新。

## 點用

1. 撳工具列 **相片變3D**（或者 **Extensions → 相片變3D → 由相片整模型...**）。
2. 撳相片框揀相，或者直接將相拖入去。
3. 揀 AI 引擎同設定（模型高度、品質、精細度、顏色數量、自動去背景、去除光影）。
   「品質」揀 **精細**（本機引擎）會用 Hunyuan3D 完整版模型、計多啲步、用更細嘅網格，形狀細節多啲，
   每次多大約 20-30 秒（快：約 1 分鐘）；第一次用要多下載大約 4 GB。顏色同貼圖唔會因此變好。
   「去除光影」會先將相入面嘅燈光色、反光同陰影剷走，先至上色，等黃色燈光唔會變咗物件嘅顏色（本機引擎，每次慢 10 秒左右）。
   用 Meshy 嘅話，貼上你嘅 API key（可以揀記住喺呢部電腦）。
4. 撳 **開始變 3D**，睇住進度條。整緊嘅時候可以繼續用 SketchUp。
5. 「擺放位置」揀 **跟住滑鼠**：模型整好之後會黐住滑鼠，喺畫面撳一下就放低（撳 Esc 就唔放，之後可以喺 Components → In Model 搵返）。
   揀 **原點**：模型會放喺 0,0,0 並揀咗，用「移動」工具擺去你想要嘅位置。

## 更新

有新版本嘅時候，打開相片變3D 視窗，最上面會出「有新版本」。撳 **下載** 會打開 https://chilldim.site ，
下載新嘅 `PhotoTo3D.rbz`，再喺 Extension Manager 撳 Install Extension 揀佢，就會蓋過舊版（設定同 AI 唔使重裝）。

## 點樣影出好效果

- 每張相淨係影一件嘢：櫈、花樽、公仔、鞋、車。
- 成件嘢要入晒鏡，背景簡單、光線充足。
- 由斜上少少、側少少嘅角度影。
- 影燈飾最好熄燈、用白光或者日光影；著住燈嘅光暈 AI 未必估到原本係咩色。
- 背面係 AI 估出嚟，所以冇咁準。
- 成座建築物或者房間，請用 SketchUp 嘅 **Match Photo**。

## 出問題

- 視窗會顯示原因，撳「睇記錄」可以睇詳情；「開工作資料夾」入面每次都有 `log.txt`。
- 「張相搵唔到物件」：試下清楚啲嘅相，或者用已經去咗背景嘅 PNG。
- 「Hunyuan3D 需要 NVIDIA 顯示卡」：改用 TripoSR 或 Meshy，或者更新顯示卡驅動。
- Meshy「API key 唔啱」/「credits 唔夠」：去 meshy.ai 檢查你嘅 key 同戶口。

## 開發者：整 .rbz

```
powershell -ExecutionPolicy Bypass -File build_rbz.ps1
```

會輸出 `dist\PhotoTo3D.rbz`。

## 授權

- TripoSR：MIT。
- Hunyuan3D-2 mini：Tencent Hunyuan 3D 2.0 Community License。可以免費用（包括商業用途），
  但**唔可以喺歐盟、英國同南韓使用**；每月用戶超過 100 萬嘅公司要另外問騰訊攞許可。
- Meshy：跟 Meshy 嘅服務條款，按 credits 收費。
