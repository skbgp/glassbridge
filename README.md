# GlassBridge

Copy files and folders between your Mac and Android phone over ADB. There’s a file list on each side, with drag and drop and a transfer queue underneath.

## Install

Download the app from [Releases](https://github.com/skbgp/glassbridge/releases/tag/v0.1.0), unzip it, and move it to Applications. The download includes ADB and runs on Apple Silicon Macs with macOS 14 or later.

The app isn’t notarized yet. If macOS blocks it, try opening it, then look for **Open Anyway** in System Settings → Privacy & Security.

On your phone, enable USB debugging, plug in a USB data cable, and accept the prompt to allow your Mac. Choose the phone in the toolbar if you have more than one connected.

## Copying files

Double-click folders to open them. Drag up or down to select a range of rows, or use Command-click and Shift-click. Drag sideways to copy to the other device.

Drop onto a folder to copy inside it. Drop onto empty space to use the open folder. Before a drop starts copying, you get a confirmation showing the destination.

If an item already exists, choose Replace, Keep Both, or Skip. Replacing a folder replaces the whole folder; it doesn’t merge the contents. Originals on the source device stay where they are.

You can also use the arrow buttons, or drag files from Finder into the Android pane. The queue shows bytes copied, speed, and estimated time left. Copies run one at a time.

| Shortcut | Action |
| --- | --- |
| ⌘⇧R | Send selected files to Android |
| ⌘⇧L | Save selected files to the Mac |
| ⌘R | Refresh |
| ⌘J | Show or hide transfers |
| ⌘⇧. | Show or hide hidden files |

## Build

You’ll need Swift 6.2 and the macOS 26 SDK. Apple’s Command Line Tools are enough.

```sh
git clone https://github.com/skbgp/glassbridge.git
cd glassbridge
./scripts/build.sh
open dist/GlassBridge.app
```

The script bundles ADB from `~/Library/Android/sdk/platform-tools/adb` when available. To use another copy:

```sh
GLASSBRIDGE_ADB_PATH=/path/to/platform-tools/adb ./scripts/build.sh
```

You can also choose ADB in the app’s Settings. Google provides it in [Platform Tools](https://developer.android.com/tools/releases/platform-tools). Builds use the architecture of the Mac running the script and are locally signed.

Run the local checks with `./scripts/test.sh`. For a phone test:

```sh
GLASSBRIDGE_TEST_SERIAL='your-device-serial' \
GLASSBRIDGE_TEST_ADB=/path/to/platform-tools/adb \
./scripts/test.sh
```

The phone test uses a temporary folder under Download and cleans up its own files.

## A few things to know

Copies go to a temporary destination first. File names, sizes, and folder structure are checked before the copy gets its final name. These are size checks, not checksum verification. Progress comes from sampling the destination, so speed and time left are estimates.

Symbolic links aren’t supported. Android files can’t be dragged straight into Finder; use the Mac pane. Transfers don’t resume after the app closes. Android storage access depends on the phone’s ADB permissions.

It’s been tested with an A015 phone and local transfer checks. There isn’t an MTP speed comparison yet.

The Swift source is in `Sources/GlassBridge`, with checks in `Tests/BridgeChecks.swift`. Bundled ADB keeps its own licenses; its notices are included in the app.
