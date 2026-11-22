# Архитектура WimWizardCli.ps1

## Обзор

WimWizardCli.ps1 (v6.2.1) — PowerShell-скрипт для offline-обслуживания
Windows 11 образов (WIM/ESD) перед развёртыванием. Работает с **распакованными
папками**, содержащими `install.wim`/`install.esd` и подпапку
`LanguagesAndOptionalFeatures` — монтирование ISO больше не используется.

Поддерживается только **x64**. ARM64, SCCM/MECM, SafeOS и WinRE — вне области
задачи (удалены в 6.1.0).

## Основные компоненты

### 1. Параметры и конфигурация

| Параметр | Назначение |
|---|---|
| `SourceFolder` | Папка, содержащая `install.wim`/`install.esd` (рекурсивный поиск) и подпапку `LanguagesAndOptionalFeatures` с LP/FoD cab-файлами |
| `WindowsISOPath` | Устарел — оставлен для обратной совместимости, игнорируется |
| `UpdatePath` | Явный путь к папке с обновлениями (.msu/.cab). Пусто = автоматическое скачивание |
| `OutputPath` | Итоговый WIM: папка (имя генерируется) или полный путь с `.wim` |
| `WimIndex` | Явный индекс WIM. `0` = автоопределение Enterprise |
| `Languages` | 2-буквенные коды языков (`se,no,dk,fi`). При `-Unattended` без параметра — English only |
| `FoDList` | Ключи Features on Demand: `NetFx3`, `RsatAD`, `RsatGPO`, `RsatSrvMgr` |
| `DriverPath` | Папка с распакованными driver-пакетами (.inf/.sys/.cat). Только в full build |
| `DriverListPath` | XML со списком INF для инъекции (генерируется GUI). Приоритет над `DriverPath` |
| `AppxListPath` | XML с кастомным списком Appx для удаления |
| `PatchExistingWim` | Режим patch: только LCU/checkpoint/.NET CU, без LP/Appx/Drivers |
| `SkipUpdates`, `SkipLanguagePacks`, `SkipAppxRemoval`, `SkipDefenderUpdate` | Отключение отдельных фаз |
| `Unattended` | Без интерактивных промптов |
| `DebugBuild` | Расширенная диагностика DISM |

### 2. Фазы обслуживания (Pipeline)

1. **Обнаружение WIM/ESD (`Resolve-WimEsdFolder`)**
   - Рекурсивный поиск `install.wim` / `install.esd` в `SourceFolder`
   - Автоопределение `LanguagesAndOptionalFeatures` (используется как источник LP и FoD cab-файлов)
   - Fallback: `SourceFolder` как источник cab-файлов, если подпапка отсутствует

2. **Выбор индекса WIM**
   - Автоопределение Enterprise (исключая Evaluation)
   - Fallback на единственную edition в образе
   - Промпт при нескольких editions (кроме `-Unattended`)

3. **Скачивание обновлений (Patch Tuesday)**
   - LCU (Cumulative Update + SSU)
   - **Checkpoint KB5043080** — обязательный prerequisite для LCU после LP/FoD
   - .NET Framework CU
   - Кэш в `Updates\` (или `-UpdatePath`)
   - Сохранение оригинального имени Microsoft с SHA1 hash (`windows11.0-kbNNNNNNN-x64_<hash>.msu`)

4. **Применение обновлений (install.wim)**
   - **Pass 1 (SSU)**: checkpoint + LCU копируются в `LCU_temp\`, DISM применяет их последовательно
   - **Language Packs**: `Add-WindowsPackage` для каждого locale + Fonts capability
   - **Features on Demand**: языковые FoD через `Add-WindowsCapability`, затем RSAT
   - **Pass 2 (Full LCU)**: checkpoint + LCU копируются в `LCU_temp2\`, DISM восстанавливает baseline и применяет LCU
   - **Component cleanup**: `/StartComponentCleanup` (без `/ResetBase` — только для WinRE/WinPE по MS docs)
   - **NetFx3 + .NET CU**: `Add-WindowsCapability NetFX3~~~~` + `Add-WindowsPackage` для .NET

5. **Driver injection (full build only)**
   - `-DriverListPath` (XML) имеет приоритет над `-DriverPath` (рекурсивный скан)
   - Каждый INF инжектится отдельно через `Add-WindowsDriver` с per-driver try/catch
   - Ошибки non-fatal (архитектурные несовместимости, дубликаты)

6. **Удаление Appx-пакетов**
   - `-AppxListPath` (XML из GUI) или встроенный default-список
   - Exact match по `DisplayName` → fallback на `-like "*name*"` → ambiguous skip
   - Дедупликация по `DisplayName` (пакет удаляется один раз)

7. **Defender offline update (KB4568292)**
   - Кэш в `<Updates>\DefenderKit\defender-update-kit-amd64.zip`
   - Использование кэша без перезагрузки; принудительный refresh = удалить zip
   - Валидация: Authenticode Valid + `O=Microsoft Corporation` + layout cab + arch совместимость
   - Drift-детекция hash `DefenderUpdateWinImage.ps1`
   - Rollback в стоковое состояние при ошибке копирования (non-fatal; только провал rollback прерывает build)

8. **Экспорт и сжатие**
   - `Export-WindowsImage -CompressionType Max -CheckIntegrity`
   - Автогенерация имени: `Win11_<version>_<build>_<langs>_<date>.wim`
   - Patch mode: замена устаревшего build-токена в авто-имени после export (5.7.2)

### 3. Режимы работы

| Режим | Поведение |
|---|---|
| **Interactive** (по умолчанию) | Промпты для всех путей и параметров, подтверждение перед стартом |
| **Unattended** (`-Unattended`) | Без промптов; при отсутствии `-Languages` — English only; при отсутствии Enterprise — hard fail |
| **Patch** (`-PatchExistingWim`) | Только LCU + checkpoint + .NET CU; LP/Appx/Drivers пропускаются принудительно |
| **Debug** (`-DebugBuild`) | Полный вывод DISM для всех шагов (cleanup, LCU passes) |

### 4. Проверки и обработка ошибок

- **Stale mounts**: `dism /Cleanup-Mountpoints` перед началом работы
- **DISM**: проверка доступности
- **Свободное место**: минимум 30 GB в output и work folders (DarkYellow warning + keypress pause в интерактиве)
- **Интернет**: проверка доступности Microsoft Update Catalog (fallback в manual mode)
- **Ранняя проверка checkpoint**: в Step 3 — если LCU есть, а checkpoint KB5043080 нет → warn + confirm
- **DISM error codes**:
  - `0x800f081e` (CBS_E_NOT_APPLICABLE) — ignorable для LCU/LP/.NET
  - `0x800f0952` (CBS_E_ALREADY_INSTALLED) — ignorable для LP
  - `0x800F0806` (CBS_E_PENDING) — non-fatal для cleanup
  - `0x800F0838` (CBS_E_IMAGE_UNSERVICEABLE) — **fatal** для LCU pass 2, явное сообщение про missing checkpoint
  - `0x800401e3` (Add-WindowsPackage на LCU) — обходится через `dism.exe /Add-Package`
  - `0x80070241`/`0x80070570` — обходится сохранением hash-named filename

### 5. Ключевые архитектурные особенности

1. **Checkpoint KB5043080 — обязательный этап**
   - При наличии LCU в папке обновлений автоматически ищется checkpoint (тот же `DownloadDialog.aspx` API)
   - Скачивается, даже если LCU уже в кэше (проверка отдельная для каждого файла)
   - Копируется в `LCU_temp\` и `LCU_temp2\` рядом с LCU — DISM применяет его как prerequisite
   - Защищён от удаления при prune старых LCU (`-notmatch "kb5043080"`)
   - Исключён из селектора `$lcuFile` (алфавитная сортировка иначе выберет его вместо LCU)

2. **Двухпроходная установка LCU**
   - Pass 1 (SSU): до LP/FoD, обеспечивает свежий servicing stack
   - Pass 2 (Full): после LP/FoD, восстанавливает baseline через checkpoint и применяет полный LCU
   - Копирование LCU и checkpoint в изолированную temp-папку сохраняет оригинальные hash-named имена — критично для DISM signature validation

3. **Кэширование**
   - LCU / checkpoint / .NET: `Updates\` с проверкой по KB-номеру и hash в имени
   - DefenderKit: `Updates\DefenderKit\` (не перезагружается, если zip на месте)
   - MSCatalogLTS: PSGallery + NuGet provider 2.8.5.208

4. **Гибкость путей**
   - Output: папка (авто-имя) или полный путь с `.wim`
   - Work folder (WIM mount + scratch, ~20 GB): промпт с проверкой свободного места
   - Update folder: промпт при автоскачивании
   - Driver/Appx XML override: приоритет над folder scan / default list

5. **Идемпотентность patch mode**
   - `PatchExistingWim` копирует исходный WIM в `<Work>\install_work.wim`
   - Читает `Languages` и `Version` из WIM, формирует `CatalogSearchTerms` из реального build
   - Авто-имя с build-токеном обновляется после export (не влияет на имена, заданные пользователем)

## Важные версии и изменения

- **6.2.1** — Checkpoint KB5043080 докачивается при кэшированном LCU; DefenderKit кэшируется в `Updates\DefenderKit\` и не перезагружается; ранняя проверка checkpoint в Step 3; явные промпты для update folder и work folder
- **6.2.0** — Возврат checkpoint KB5043080 (лечит `0x800F0838` на pass 2 после LP/FoD); `$lcuFile` исключает checkpoint
- **6.1.0** — Удалены SCCM/MECM, ARM64, SafeOS, WinRE, Inbox App Language Fix; `Get-CatalogSearchTerms.VersionString` вместо `SafeOSVersion`
- **5.7.x** — Defender kit (KB4568292), `-SkipUpdates` fix, patch filename build-token fix
- **5.3.x** — Driver injection, INF token resolve, comment strip

## Миграция с ISO-подхода

`Resolve-WimEsdFolder` заменяет `Resolve-SourceFolder`, `Mount-ISOSafe`, `Dismount-AllISOs`. Ожидаемая структура `SourceFolder`:
ISO-Source
├── Windows11_25H2\ (распакованный ISO или его sources)
│ ├── install.wim или install.esd
│ └── ...
└── LanguagesAndOptionalFeatures\ (распакованный LP ISO)
├── Microsoft-Windows-Client-Language-Pack_x64_sv-se.cab
├── Microsoft-Windows-Client-Language-Pack_x64_nb-no.cab
├── ... (Basic, OCR, Handwriting, TextToSpeech, Speech)
└── Microsoft-Windows-LanguageFeatures-Basic-*.cab

Рекурсивный поиск `install.wim`/`install.esd` находит единственный образ; при нескольких — детерминированный выбор (первый в алфавитном порядке) с предупреждением. `LanguagesAndOptionalFeatures` ищется сначала как подпапка `SourceFolder`, при отсутствии — используется сам `SourceFolder` для LP/FoD cab-файлов.

## Использование

Скрипт предназначен для системных администраторов, которые:
- Собирают образы Windows 11
- Требуют гибкой настройки образа: языки, FoD, драйверы, Appx, Defender
- Обслуживают образы регулярно (patch mode для месячных Patch Tuesday циклов)
- Работают с распакованными папками (без монтирования ISO — удобно в CI/CD, контейнерах, на build-серверах без прав на Mount-DiskImage)