# ORB

**Build your voice agent. Three models. One local AI.**

ORB is a macOS app (and CLI) that assembles a fully local voice assistant from three open models:
a thinking model (LLM via Ollama), speech-to-text (whisper.cpp) and text-to-speech (Piper).
Pick the models, press **SET UP MY ORB →**, and ORB downloads, installs, starts and verifies everything end to end.

## Requirements

- macOS 14+ (Apple Silicon recommended; 8 GB RAM minimum, 16 GB+ comfortable)
- Swift 5.9+ toolchain (Xcode or Command Line Tools) to build from source
- Internet for the one-time setup (Hugging Face / Ollama downloads). After that ORB runs offline.
- Free disk: roughly 2–10 GB depending on chosen models
- Microphone permission

## Install

```sh
git clone <this repo> ORB && cd ORB
scripts/build_app.sh        # builds build/ORB.app (release, ad-hoc signed, mic entitlement)
open build/ORB.app
```

## CLI

The `orb` executable shares the same core. See [docs/CLI.md](docs/CLI.md).

```sh
swift run orb --help
```

## Architecture

| Module | Role |
| --- | --- |
| `OrbCore/Contracts.swift` | Shared types: `CatalogModel`, `OrbConfig`, `OrbState`, `Paths`, `Endpoints`, protocols |
| `OrbCore/Hardware` | `HardwareDetector` – chip, memory, disk, tier |
| `OrbCore/Catalog` | `ModelCatalog` – featured, live Hugging Face search, hardware-based recommendation |
| `OrbCore/Download` | `ModelDownloader` – resumable, checksum-verified downloads |
| `OrbCore/Runtime` / `Setup` | Runtime installation, service lifecycle, `SetupEngine` step pipeline |
| `OrbCore/Voice` | `VoiceAgent` – mic capture, STT → LLM → TTS, barge-in, audio devices |
| `OrbCore/Orb` | `OrbEngine` – pixel-grid orb renderer |
| `OrbApp` | SwiftUI app: builder, setup, voice screen, settings |
| `orb` | Command line interface |

Local services (loopback only): Ollama `11434`, whisper-server `18181`, Piper server `18182`.

## Compatibility registry

Models are labelled **VERIFIED** when they are in the built-in registry (tested architecture, format and backend), and **EXPERIMENTAL** when they are heuristically matched from live Hugging Face search and may not run. Experimental models are never silently marked ready: setup verifies end to end and reports failures honestly.

## Privacy

Audio, transcripts and conversations are processed on your Mac and never sent anywhere. Network is used only to download models and runtimes, and for catalog search. Services bind to `127.0.0.1`.

Data lives in `~/Library/Application Support/ORB` (config, runtimes, logs, models). The models directory can be changed in Settings.

## Development

```sh
swift build            # debug build
swift test             # core tests
swift run ORB          # run the app unbundled (microphone needs the bundled app)
scripts/build_app.sh   # bundle
```

## Troubleshooting

- **No microphone input** – use the bundled `ORB.app` (not `swift run`) and allow access in System Settings → Privacy & Security → Microphone.
- **Status pill shows OFFLINE/DEGRADED** – open Settings → Diagnostics to see which service is unhealthy; use Retry or re-run setup.
- **Setup failed** – expand the log panel on the setup screen; logs are in `~/Library/Application Support/ORB/logs`. Retry resumes partial downloads.
- **Port in use** – ports 11434, 18181, 18182 must be free.
- **Not enough disk** – pick smaller models or change the models directory in Settings.
- **Gatekeeper warning** – the app is ad-hoc signed; right-click → Open the first time.
