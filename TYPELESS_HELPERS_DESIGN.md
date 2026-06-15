# Typeless KeyboardHelper / InputHelper 技术方案

> 调研对象:`/Applications/Typeless.app` v1.7.0 内 `Resources/lib/{keyboard,input}-helper/build/` 下的两个 universal dylib,以及主进程通过 `koffi` 调用它们的整套接入方案。

---

## 0. 全局定位

```
┌────────────────────────────────────────────────────────────────────┐
│                        Electron Main Process (Node 22)              │
│  ┌────────────────────────┐    ┌──────────────────────────────┐    │
│  │  dist/main/index.js    │    │  koffi (FFI bindings)        │    │
│  │  (534 KB, obfuscated)  │───▶│  libInputHelper.dylib        │    │
│  │                        │    │  libKeyboardHelper.dylib     │    │
│  │  注入逻辑: paste +     │    │  libContextHelper.dylib      │    │
│  │  上下文采集 + 录音控制  │    │  libUtilHelper.dylib         │    │
│  └────────────────────────┘    │  libopusenc.dylib            │    │
│            │                   └──────────────────────────────┘    │
│            │ IPC (ipcMain)                                          │
│            ▼                                                        │
│  ┌────────────────────────┐                                        │
│  │  Renderer (React 18)   │                                        │
│  │  floating-bar / sidebar│                                        │
│  └────────────────────────┘                                        │
└────────────────────────────────────────────────────────────────────┘
```

- **koffi 2.11** (Node 端) → `koffi.load()` 调 `dlopen`,`koffi.func()` / `koffi.callback()` 走 `dlsym` + 手写 C ABI 适配层。
- 静态签名都通过 dylib 的 **C entry points** 暴露(以 `_` 前缀,无 Swift name-mangling),内部实现用 Swift 写。
- 所有 dylib 都是 `x86_64 + arm64` universal。
- `koffi.node` 在 `app.asar.unpacked/node_modules/koffi/build/koffi/darwin_x64/` — 必须 unpacked 因为 asar 内文件无法 `dlopen`。
- 系统 framework 依赖: `CoreFoundation`, `CoreGraphics`, `AppKit`, `ApplicationServices`, `Carbon`, `Foundation`, `IOKit`, `libobjc`, `libswift*`。

---

## 1. KeyboardHelper

### 1.1 模块结构(Swift)

```
KeyboardHelper_x86_64_temp0
├── Monitor          (单例,CGEventTap 监听 + RunLoop 调度)
├── ShortcutDetector (匹配逻辑,持有 targetShortcuts + pressingKeycodes)
├── Utils            (keyCode↔keyName 双向映射)
└── DeviceList       (CoreAudio/IOHID 设备列表,对外是 getKeyboardDeviceList)
```

- 命名里的 `_x86_64_temp0` 是交叉编译后留下的模块名前缀(Swift 编译器自动加的),源码里就是 `KeyboardHelper`。
- `Monitor` 内部关键状态: `CFRunLoopSource`、`CFMachPort`(eventTap)、`NSTimer`(watcherTimer,周期性 processEvents)、`callback` 闭包。
- 事件流:`CFMachPort` (CGEventTap) → `processEvents()` → `ShortcutDetector.handleKeyDown/Up` → `ShortcutDetector.isMatch` → 通过 `callback` 回调给 JS。

### 1.2 C 导出表(7 个外部符号)

| C 符号 | Swift 源 | 参数 / 返回 | 用途 |
|---|---|---|---|
| `getKeyboardDeviceList` | `DeviceList.getAsJson()` | → `char*?` (JSON 字符串) | 列出当前系统的输入设备,JS 拿到后 JSON.parse |
| `startMonitor` | `Monitor.start(callback:)` | `(callback: CFunctionPointer)` → `void` | 启动键盘监听,把 Swift 闭包注册为 C 回调 |
| `stopMonitor` | `Monitor.stop()` | `()` → `void` | 停监听 |
| `processEvents` | `Monitor.processEvents()` | `()` → `void` | 驱动 pending 事件(由 watcherTimer 周期性调用) |
| `setWatcherInterval` | `Monitor.setWatcherInterval(_:)` | `(Double)` → `void` | 设置 processEvents 的轮询周期(秒) |
| `updateTargetShortcuts` | `ShortcutDetector.updateTargetShortcuts(_:)` | `(char* jsonData)` → `void` | 热更新要识别的快捷键组合(JSON 数组) |
| `resetPressingKeycodes` | `ShortcutDetector.resetPressingKeycodes()` | `()` → `void` | 清空"当前按下"状态(用于切窗口/唤醒后重置) |

> **没有专门的 free 函数** — KeyboardHelper 返回的字符串由调用方 free(实际看 main bundle 没有调用 `freeString` 相关的代码,意味着 JS 端靠 GC + JSON.parse 即时拷贝;若要严格零拷贝要补一个 `freeString`)。

### 1.3 C 回调签名(koffi 端)

```
bool KeyboardCallback(int32_t, char*, int32_t, int32_t, char*)
```

5 个参数语义(从 `ShortcutDetector.isMatch` 推断):
1. `int32_t` eventType: `0 = keyDown`, `1 = keyUp`, `2 = flagsChanged`?
2. `char*` keyName: 当前按键名(`"a"`, `"Command"`, `"RightShift"`)
3. `int32_t` keyCode: macOS 虚拟键码
4. `int32_t` modifiers: 当前修饰键位掩码(cmd/ctrl/alt/shift)
5. `char*` matchedShortcut: 匹配到的快捷键字符串(如 `"RightAlt+Space"`)

返回 `bool` 表示"已消费",true 时 JS 端就阻止该事件再向上传播(虽然 CGEventTap 那边已经吞了,这里只是信号)。

> ⚠️ Swift 端实际注册的 C 回调只有 4 个参数(`(Int32, Int8*?, Int8*?, Int8*?)`),需要 Swift 内部在调用 koffi 提供的 C 指针前做一次封装 — 多半是 `startMonitor` 接收 C 函数指针后,内部存一个 Swift 适配器,直接拿到 4 参数状态后**不再调 C 函数**,而是通过 RunLoop 上的另一个 timer/queue 把 (eventType, keyName, keyCode, modifiers) 喂给 JS。**那 5 参数的 C 回调可能是备用接口,或被不同 C 端实现吞掉**。文档里要明确"本设计以 4 参数 Swift 闭包为准"。

### 1.4 koffi 绑定代码(从 main bundle 反混淆还原)

```js
// koffi 是 dynamic import 的(异步),Es 是模块对象
const koffi = await import('koffi');

// 1. 加载 dylib
const lib = koffi.load(paths.keyboardHelper);   // 例: <resources>/lib/keyboard-helper/build/libKeyboardHelper.dylib

// 2. 定义 C 回调类型
const KeyboardCallback = koffi.callback('bool KeyboardCallback(int32_t, char*, int32_t, int32_t, char*)');
const cbPointer = koffi.register(jsCallback, KeyboardCallback);

// 3. 绑定 C 函数
const libStartMonitor              = lib.func('startMonitor',                       'void', [KeyboardCallback]);
const libStopMonitor               = lib.func('stopMonitor',                        'void', []);
const libProcessEvents             = lib.func('processEvents',                      'void', []);
const libSetWatcherInterval        = lib.func('setWatcherInterval',                 'void', ['double']);
const libUpdateTargetShortcuts     = lib.func('updateTargetShortcuts',              'void', ['str']);
const libResetPressingKeycodes     = lib.func('resetPressingKeycodes',              'void', []);
const libGetKeyboardDeviceList     = lib.func('getKeyboardDeviceList',              'str',  []);
```

### 1.5 JS 端典型调用流

```js
// 1. 拉设备列表(用于设置面板)
const devices = JSON.parse(libGetKeyboardDeviceList() ?? '{}');

// 2. 注册本地回调
let lastEvent = null;
const onKey = (eventType, keyName, keyCode, modifiers, matchedShortcut) => {
  lastEvent = { eventType, keyName, keyCode, modifiers, matchedShortcut };
  if (matchedShortcut) {
    mainWindow.webContents.send('shortcut:fired', lastEvent);
  }
};

// 3. 启动监听
libStartMonitor(cbPointer);
libSetWatcherInterval(0.016);   // ~60Hz
// libProcessEvents() 由 dylib 内部 NSTimer 周期性调用,JS 不需要主动 pump

// 4. 切换快捷键方案(用户改了设置)
libUpdateTargetShortcuts(JSON.stringify([
  ['RightAlt', 'Space'],
  ['RightAlt', 'S'],
  // ...
]));

// 5. 切窗口 / 唤醒后重置
libResetPressingKeycodes();

// 6. 退出 / 切 profile
libStopMonitor();
```

### 1.6 资源 / 权限需求

- `Info.plist` 需 `NSMicrophoneUsageDescription`(录音),但 **不需要** Accessibility,因为 KeyboardHelper 自身有 CGEventTap — 实际上 macOS 14+ 上 `CGEventTapCreate` 需要 *Input Monitoring* 权限(Settings → Privacy & Security → Input Monitoring),Typeless 应该会引导用户授权。
- koffi 走 `dlopen` + `dlsym`,无代码签名额外限制;helper dylib 自己需要 ad-hoc 签名或 developer ID。

---

## 2. InputHelper

### 2.1 模块结构(Swift)

```
InputHelper_x86_64_temp0
├── (内部状态: NSPasteboard 实例句柄 + AXUIElement 引用缓存 + 一个 ArchivedPasteboardItem 列表)
└── 多个 @_cdecl 桥接函数
```

`ArchivedPasteboardItem` 是私有 Swift struct(从符号看含 `archivedItemV`/`archivedItemN` 名字段,推测保存 pasteboard item 的 `type → data` 字典),用于"保存当前剪贴板 → 写新内容 → 模拟粘贴 → 还原"。

### 2.2 C 导出表(13 个外部符号)

| C 符号 | Swift 源 | 参数 / 返回 | 用途 |
|---|---|---|---|
| `getCurrentInputState` | (内部) | `()` → `char*?` (JSON) | 当前焦点输入框的 IME / composition 状态 |
| `insertText` | `InputHelper.insertText(repeatCount:text:)` | `(int32_t count, const char* text)` → `int32_t` | 通过 Accessibility API 写入纯文本;1 = 成功 |
| `insertRichText` | `InputHelper.insertRichText(repeatCount:text:html:)` | `(int32_t count, const char* text, const char* html)` → `int32_t` | 写入富文本(优先 HTML,回退 text) |
| `deleteBackward` | `InputHelper.deleteBackward(repeatCount:)` | `(int32_t count)` → `int32_t` | 退格 N 个字符;0 = 成功 |
| `savePasteboard` | `InputHelper.savePasteboard()` | `()` → `ArchivedPasteboardItem[]` | 备份当前剪贴板 |
| `restorePasteboard` | `InputHelper.restorePasteboard(from:)` | `(ArchivedPasteboardItem[])` → `void` | 还原 |
| `performTextInsertion` | `InputHelper.performTextInsertion(with:)` | `(const char* text)` → `bool` | 高层"插入纯文本"(内部组合 save→set→paste→restore) |
| `performRichTextInsertion` | `InputHelper.performRichTextInsertion(html:text:)` | `(const char* html, const char* text)` → `bool` | 高层"插入富文本" |
| `simulatePasteCommand` | `InputHelper.simulatePasteCommand(completion:)` | `(completion: CFunctionPointer)` → `void` | 异步触发 ⌘V(通过 CGEventPost 模拟);完成后调 completion |
| `getSelectedText` | `InputHelper.getSelectedText()` | `()` → `char*?` | 通过 AX API 读焦点选中文本 |
| `getSelectedTextBySimulateCopyAsync` | `InputHelper.getSelectedTextBySimulateCopyAsync(_:)` | `(CFunctionPointer callback)` → `void` | 异步版:模拟 ⌘C → 读剪贴板 → 回调;koffi 用 `{async: true}` 标记 |
| `findKeyCodeForCharacter` | `InputHelper.findKeyCodeForCharacter(_:)` | `(const char* character)` → `int32_t` | 给一个 Unicode 字符返回 macOS 键码(用于 Type-by-keyCode 注入) |
| `freeString` | (内部) | `(const char* ptr)` → `void` | 释放上面那些返回 `char*` 的函数分配的内存 |

> 返回 `int32_t` 的函数惯例:**1 表示成功,0 表示失败**(从 `insertText(...)!==0x1` 推断)。`deleteBackward` 反过来用 `=== 0x0` 判成功,可能是另一种约定 — 实际看调用方写哪个常量就是哪个语义。

### 2.3 koffi 绑定

```js
// 1. 加载 dylib
const lib = koffi.load(paths.inputHelper);   // libInputHelper.dylib

// 2. 定义回调
const JsonStringCallback = koffi.callback('void InputHelperCallback(str /*const char**/)');
const cbPtr = koffi.register(jsCallback, JsonStringCallback);

// 3. 绑定函数
const libInsertText                       = lib.func('int32_t insertText(const char *text)',                    'int32_t', ['str']);
const libInsertRichText                   = lib.func('int32_t insertRichText(const char *html, const char *text)', 'int32_t', ['str', 'str']);
const libDeleteBackward                   = lib.func('int32_t deleteBackward(int32_t count)',                  'int32_t', ['int32_t']);
const libGetCurrentInputState             = lib.func('getCurrentInputState',                                   'str',     []);
const libGetSelectedText                  = lib.func('getSelectedText',                                        'str',     []);
const libGetSelectedTextBySimulateCopyAsync = lib.func('getSelectedTextBySimulateCopyAsync',                  'void',    [JsonStringCallback], { async: true });
const libSavePasteboard                   = lib.func('savePasteboard',                                         /* ArchivedPasteboardItem[] */, []);
const libRestorePasteboard                = lib.func('restorePasteboard',                                      'void',    ['str' /*JSON*/]);
const libPerformTextInsertion             = lib.func('bool performTextInsertion(const char *text)',           'bool',    ['str']);
const libPerformRichTextInsertion         = lib.func('bool performRichTextInsertion(const char *html, const char *text)', 'bool', ['str', 'str']);
const libSimulatePasteCommand             = lib.func('simulatePasteCommand',                                  'void',    [VoidCallback]);
const libFindKeyCodeForCharacter          = lib.func('int32_t findKeyCodeForCharacter(const char *c)',        'int32_t', ['str']);
const libFreeString                       = lib.func('freeString',                                             'void',    ['str']);
```

> `savePasteboard` / `restorePasteboard` 在 C ABI 上传的是 `ArchivedPasteboardItem` 数组(Swift `Array<ArchivedPasteboardItem>` 经 `@_cdecl` 暴露为 OC-ABI 数组),但 koffi 不直接支持 Swift struct 数组 — 实际做法是 **Swift 内部把数组序列化成 JSON 字符串**(`char*`),koffi 端用 `str` 类型互传。从 main bundle 看 `libRestorePasteboard` 接收的就是 `'str'`(JSON),`libSavePasteboard` 返回 `'str'`(JSON),然后 JS 端 `JSON.parse`。

### 2.4 文本注入的两条主路径

**路径 A:AX API 直写(优先,被 Electron / 原生 App 友好支持)**

```js
const ok = libInsertText(0, refinedText) === 1;
if (!ok) {
  // 降级路径 B
  await pathB_pasteboard(refinedText, /*html*/ null);
}
```

`InputHelper.insertText` 内部: 取焦点 AXUIElement → 设置 `.value` 属性(或 `kAXValueAttribute` / `kAXTextFieldText`)。返回 1 = 成功,0 = 失败(无权限 / 非文本框)。

**路径 B:剪贴板 + 模拟 ⌘V(兼容任何接收 ⌘V 的应用)**

```js
async function pathB_pasteboard(text, html) {
  const snapshot = libSavePasteboard();            // JSON 字符串
  try {
    if (html) {
      // 写多类型 pasteboard item
      // (InputHelper 内部调 NSPasteboard.general().setData for both text & html)
      libPerformRichTextInsertion(html, text);
    } else {
      libPerformTextInsertion(text);
    }
    await new Promise(resolve => {
      const cb = koffi.callback('void PasteDone()');
      const cbPtr = koffi.register(() => resolve(), cb);
      libSimulatePasteCommand(cbPtr);   // 触发 ⌘V
    });
  } finally {
    setTimeout(() => libRestorePasteboard(snapshot), 100);  // 延迟还原,避免粘贴本身读到还原后的内容
  }
}
```

> 关键时序:`restorePasteboard` 必须在 `simulatePasteCommand` 完成 **之后** 再执行,所以用 setTimeout 或等 `PasteDone` 回调。

### 2.5 上下文采集链(InputHelper 仅是其中一个环节)

整体上下文链路是 4 个 helper 协作的:

```
ContextHelper (Swift)            InputHelper (Swift)             UtilHelper (Swift)
  getFocusedAppInfo       →         getCurrentInputState     →   checkAccessibilityPermission
  getFocusedElementInfo             getSelectedText                getAudioDevicesJSON
  getFocusedVisibleText             getSelectedTextBySimulateCopy  isAudioMuted
  smartJoinTexts                    findKeyCodeForCharacter
  findWebArea (浏览器)
  collectContentBefore/After
```

主进程拿到这些后,会拼成 `audio_context`(存进 `history_v2.audio_context` 字段),送给 LLM 做 prompt 上下文。

---

## 3. 工程集成细节

### 3.1 目录与产物

```
typeless/
├── packages/
│   ├── main/                        # Node 端
│   │   ├── src/native/
│   │   │   ├── koffi-helpers.ts    # koffi.load + func 绑定(本设计)
│   │   │   ├── keyboard.ts         # KeyboardHelper 业务封装
│   │   │   ├── input.ts            # InputHelper 业务封装
│   │   │   └── context.ts
│   │   └── tsconfig.json
│   └── helpers/                     # Swift 端(每个 helper 一个 target)
│       ├── KeyboardHelper/
│       │   ├── Package.swift
│       │   ├── Sources/
│       │   │   ├── Monitor.swift
│       │   │   ├── ShortcutDetector.swift
│       │   │   ├── Utils.swift
│       │   │   ├── DeviceList.swift
│       │   │   └── CExports.swift  # @_cdecl 桥接
│       │   └── Tests/
│       ├── InputHelper/
│       │   ├── Package.swift
│       │   ├── Sources/
│       │   │   ├── Pasteboard.swift
│       │   │   ├── TextInjector.swift
│       │   │   ├── AXBridge.swift
│       │   │   └── CExports.swift
│       │   └── Tests/
│       ├── ContextHelper/  (同结构)
│       └── UtilHelper/     (同结构)
├── scripts/
│   ├── build-helpers.sh             # swiftc -emit-library ... -target arm64-apple-macos14 -target x86_64-apple-macos14 -output libKeyboardHelper.dylib
│   └── lipo.sh                      # lipo -create -output libKeyboardHelper.dylib
└── appshell/
    └── electron-builder.yml         # 配置 asarUnpack 把 node_modules/koffi/build 复制到 unpacked
```

### 3.2 Swift → C 导出模板

```swift
// Sources/CExports.swift
import Foundation

@_cdecl("getKeyboardDeviceList")
public func getKeyboardDeviceList() -> UnsafeMutablePointer<CChar>? {
    return DeviceList.shared.getAsJson().toCString()
}

@_cdecl("startMonitor")
public func startMonitor(callback: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void) {
    Monitor.shared.start(callback: callback)
}

// 字符串返回约定:Swift 分配 → JS 端用 freeString 释放
@_cdecl("freeString")
public func freeString(_ ptr: UnsafeMutablePointer<CChar>?) {
    if let p = ptr { free(p) }
}

@_cdecl("insertText")
public func insertText(repeatCount: Int32, text: UnsafePointer<CChar>?) -> Int32 {
    let s = text.flatMap { String(cString: $0) } ?? ""
    return TextInjector.shared.insertText(s, repeatCount: Int(repeatCount)) ? 1 : 0
}
```

> Swift `String` 转到 C `char*` 必须自己 `strdup` 或 `UnsafeMutablePointer.allocate`,并在 freeString 里 `free()`。**绝不能直接返回 `withCString` 拿到的临时指针**。

### 3.3 构建脚本(swiftc universal)

```bash
#!/usr/bin/env bash
set -euo pipefail
HELPER=$1            # KeyboardHelper / InputHelper / ...
SDK=$(xcrun --sdk macosx --show-sdk-path)
COMMON="-O -parse-as-library -emit-library -static -std=swift5.9 -sdk $SDK \
        -framework CoreFoundation -framework CoreGraphics -framework Foundation"

swiftc $COMMON -target arm64-apple-macos14.0 \
    -emit-library -o build/arm64/lib${HELPER}.dylib \
    $(find Sources -name '*.swift')

swiftc $COMMON -target x86_64-apple-macos14.0 \
    -emit-library -o build/x86_64/lib${HELPER}.dylib \
    $(find Sources -name '*.swift')

lipo -create \
    build/arm64/lib${HELPER}.dylib \
    build/x86_64/lib${HELPER}.dylib \
    -output build/lib${HELPER}.dylib

# 注入 ad-hoc 签名
codesign --force --sign - build/lib${HELPER}.dylib
```

### 3.4 electron-builder 配置要点

```yaml
# electron-builder.yml
asar: true
asarUnpack:
  - "node_modules/koffi/build/**/*"   # 让 .node 能 dlopen
  - "lib/**/build/*.dylib"            # 显式 unpack dylib,避免 asar 内的 dylopen 失败
extraResources:
  - from: "packages/helpers/{Keyboard,Input,Context,Util}Helper/build"
    to: "lib"
    filter: ["**/*.dylib"]
mac:
  entitlements: "build/entitlements.mac.plist"
  entitlementsInherit: "build/entitlements.mac.plist"
  hardenedRuntime: true
  gatekeeperAssess: false
```

### 3.5 koffi 封装层的 TS 模板

```ts
// src/native/koffi-helpers.ts
import koffi from 'koffi';
import path from 'node:path';
import os from 'node:os';
import { app } from 'electron';

type Arch = 'x64' | 'arm64';
const arch: Arch = process.arch === 'arm64' ? 'arm64' : 'x64';

function helperPath(helper: string, file: string) {
  const base = process.resourcesPath;
  if (process.platform === 'darwin') {
    return path.join(base, 'lib', helper, 'build', file);
  }
  if (process.platform === 'win32') {
    return path.join(base, 'lib', helper, 'build', 'win', arch, file);
  }
  return path.join(base, 'lib', helper, 'build', 'linux', arch, file);
}

export function loadKeyboardHelper() {
  const lib = koffi.load(helperPath('keyboard-helper', 'libKeyboardHelper.dylib'));

  const KeyboardCb = koffi.callback('bool KeyboardCallback(int32_t, char*, int32_t, int32_t, char*)');
  const kRegister  = (fn: (...a: any[]) => boolean) => koffi.register(fn, KeyboardCb);

  return {
    lib,
    KeyboardCb,
    kRegister,
    getKeyboardDeviceList: lib.func('getKeyboardDeviceList', 'str', []),
    startMonitor:          lib.func('startMonitor',          'void', [KeyboardCb]),
    stopMonitor:           lib.func('stopMonitor',           'void', []),
    processEvents:         lib.func('processEvents',         'void', []),
    setWatcherInterval:    lib.func('setWatcherInterval',    'void', ['double']),
    updateTargetShortcuts: lib.func('updateTargetShortcuts', 'void', ['str']),
    resetPressingKeycodes: lib.func('resetPressingKeycodes', 'void', []),
  };
}

export function loadInputHelper() {
  const lib = koffi.load(helperPath('input-helper', 'libInputHelper.dylib'));

  const JsonStrCb = koffi.callback('void InputHelperCallback(str)');
  const VoidCb    = koffi.callback('void VoidCallback()');
  const reg       = (fn: any, t: any) => koffi.register(fn, t);

  return {
    lib,
    reg,
    JsonStrCb,
    VoidCb,
    insertText:         lib.func('int32_t insertText(const char *text)',                                              'int32_t', ['str']),
    insertRichText:     lib.func('int32_t insertRichText(const char *html, const char *text)',                       'int32_t', ['str','str']),
    deleteBackward:     lib.func('int32_t deleteBackward(int32_t count)',                                            'int32_t', ['int32_t']),
    getCurrentInputState:lib.func('getCurrentInputState',                                                            'str',     []),
    getSelectedText:    lib.func('getSelectedText',                                                                  'str',     []),
    getSelectedTextBySimulateCopyAsync: lib.func('getSelectedTextBySimulateCopyAsync',                              'void',    [JsonStrCb], { async: true }),
    savePasteboard:     lib.func('savePasteboard',                                                                   'str',     []),
    restorePasteboard:  lib.func('restorePasteboard',                                                                'void',    ['str']),
    performTextInsertion: lib.func('bool performTextInsertion(const char *text)',                                   'bool',    ['str']),
    performRichTextInsertion: lib.func('bool performRichTextInsertion(const char *html, const char *text)',        'bool',    ['str','str']),
    simulatePasteCommand: lib.func('simulatePasteCommand',                                                           'void',    [VoidCb]),
    findKeyCodeForCharacter: lib.func('int32_t findKeyCodeForCharacter(const char *c)',                             'int32_t', ['str']),
    freeString:         lib.func('freeString',                                                                       'void',    ['str']),
  };
}
```

### 3.6 业务封装层(单例 + 错误处理)

```ts
// src/native/keyboard.ts
import { loadKeyboardHelper } from './koffi-helpers';
import log from 'electron-log';

let native: ReturnType<typeof loadKeyboardHelper> | null = null;
export function keyboard() {
  if (!native) native = loadKeyboardHelper();
  return native;
}

export class KeyboardMonitor {
  private cbPtr: unknown = null;
  start(onShortcut: (e: ShortcutEvent) => void) {
    const k = keyboard();
    this.cbPtr = k.kRegister((eventType, keyName, keyCode, mods, matched) => {
      if (matched) {
        onShortcut({
          eventType,
          keyName: keyName?.toString() ?? '',
          keyCode,
          modifiers: mods,
          shortcut: matched.toString(),
        });
      }
      return true;   // consumed
    });
    k.startMonitor(this.cbPtr as any);
    k.setWatcherInterval(0.016);   // 60Hz poll
  }

  updateShortcuts(shortcuts: string[][]) {
    keyboard().updateTargetShortcuts(JSON.stringify(shortcuts));
  }

  reset() { keyboard().resetPressingKeycodes(); }
  stop()  {
    keyboard().stopMonitor();
    // 注意:cbPtr 不可显式 free,koffi 会跟随 lib 卸载
  }
}
```

### 3.7 资源回收(防止热重载 / 反复实例化时泄漏)

- 同一个 dylib 路径**只 `koffi.load` 一次**,所有 helper 模块都从单例取。
- 进程退出时(`app.on('will-quit')`):
  - `KeyboardMonitor.stop()` + `cbPtr = null`
  - `InputHelper 端不需要主动 free(koffi 在 lib 句柄 GC 时一起释放 C 字符串)`,但保险起见把 `lib` 句柄置 null。
- Swift 端 `Monitor` 是单例,内部 NSTimer / CFMachPort 必须显式 invalidate(否则 macOS 会在 run loop 持有,主进程退出卡 1–2s)。

---

## 4. 关键边界 & 已知坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `dylib` 找不到 | electron-builder 默认把资源打进 asar,`dlopen` 不能读 asar 内文件 | `asarUnpack: ["lib/**/*.dylib", "node_modules/koffi/build/**/*"]` |
| `koffi` 加载后 dylib 签名错误 | helper dylib 用了 ad-hoc 签名,主 app 是 Developer ID 签名,Gatekeeper 会拦 | 全部用 Developer ID 签,或在 `entitlements.mac.plist` 加 `com.apple.security.cs.disable-library-validation` |
| CGEventTap 不触发 | 没授权 Input Monitoring | 启动时检测 `IOPMAssertion` + `CGEventTapCreate` 返回 `nil` → 弹设置引导 |
| 路径 A 失败(非 Electron 应用) | 有些 app 焦点元素不响应 `kAXValueAttribute` | 降级到路径 B(剪贴板 + ⌘V) |
| 路径 B 残留剪贴板 | 还原在 paste 之前发生 | 等 `PasteDone` 回调 + `setTimeout(100ms)` 双保险 |
| `insertText` 注入中文乱码 | Swift `String` ↔ `const char*` 用 UTF-8 时编码不一致 | 统一 UTF-8 + NULL 结尾,Swift 端 `String(data: Data(cStr), encoding: .utf8)` |
| `processEvents` 漏事件 | 太快/太慢都会 | 用 `setWatcherInterval` 暴露给 JS 调,默认 16ms(60Hz) |
| `KeyboardCallback` 5 参数 | Swift 闭包 4 参数 vs koffi 5 参数签名不一致 | 文档注明以 4 参数为准,或用 `int32_t padding` 占位第 5 位 |
| Accessibility 权限反复问 | Swift API 检测 `AXIsProcessTrusted()` 是同步阻塞的 | `UtilHelper.checkAccessibilityPermissions` 异步包装 + 缓存 1s |
| Intel Mac 上 `koffi.node` 缺失 | 打包时没把对应 `.node` 拷过去 | `npm rebuild` 之后 `asarUnpack` 通配 `**/build/Release/*.node` |

---

## 5. 测试策略

### 5.1 单元 / 集成

- **Swift 端**:XCTest 覆盖 `Utils.transformKeyCodeToName`、`ShortcutDetector.isMatch`(枚举所有 shortcut 组合)、`DeviceList.getAsJson`(snapshot)。
- **Node 端**:Vitest 跑 mock 的 dylib(用 `node-ffi-napi` 或 `dlopen` 一个 stub),验证调用顺序、参数序列化、freeString 调用。
- **E2E**:Spectron / Playwright for Electron,起一个 mock 输入框应用(`appshell/test-fixtures/notepad-like/`),脚本化:
  1. 启动 monitor → 模拟 ⌘→ → 验证 callback 收到
  2. 调 `insertText("hello")` → 读 AX API 验值
  3. 调 `performTextInsertion` → 验剪贴板是否在 100ms 内还原
- **权限场景**:用一个 GitHub Actions runner 跑(无 GUI 权限),仅做"加载 + 列设备"冒烟。

### 5.2 静态检查

- `nm -gU libKeyboardHelper.dylib` → 7 个 C 符号
- `nm -gU libInputHelper.dylib` → 13 个 C 符号
- `otool -L` → 确认只依赖白名单 system framework
- `codesign -dvv` → ad-hoc / Developer ID
- 任何 C 函数 ABI 改动 = 主进程 koffi.func 同步改 = 算 breaking change,要走 SemVer。

---

## 6. 复刻此方案的最小清单

如果你打算在 0 到 1 复刻这套架构,按这个顺序做最快:

1. **建 1 个 Swift Package**,只做 `KeyboardHelper` 的 `Utils.transformKeyCodeToName` + `getKeyboardDeviceList`,跨平台先不写,只 macOS。
2. **写一个 `scripts/build-helper.sh`**,universal 编译,产物丢到 `Resources/lib/keyboard-helper/build/`。
3. **Electron 主进程**:`koffi.load` + `lib.func('getKeyboardDeviceList','str',[])` + `console.log(JSON.parse(...))`。
4. 跑通最小回路后,**再加 `startMonitor` + `setWatcherInterval` + `stopMonitor`**,CGEventTap 配 Input Monitoring 权限。
5. 之后才是 `InputHelper`,从 `getSelectedText` → `insertText` → `performTextInsertion` 渐进。
6. 最后把 `ContextHelper` + `UtilHelper` 一起补上,接入 LLM 上下文采集。
7. **CI**:`swiftc + lipo + electron-builder --mac` → 产物用 `nm` 校验符号表,失败立刻报警。

这样每个阶段都有可演示产物,不会陷在 4 个 helper 同时写完才能跑的局面。
