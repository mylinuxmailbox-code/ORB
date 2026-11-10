## `orb` command-line interface

Build & run: `swift build -c release && .build/release/orb <command>`

| Command | Description |
|---|---|
| `orb demo [state]` | Live terminal orb. Without a state it cycles all states (`idle downloading installing initializing ready listening thinking speaking error`). Keys: `←/→` or `1-9` switch state, `a` auto-cycle, `m` hold/wave amplitude, `q` quit. Non-TTY: prints one plain-text frame per state. |
| `orb doctor` | Hardware, runtimes (ollama, whisper-server, piper venv), service health, free disk, microphone permission, port usage, config. |
| `orb models <stt\|tts\|llm> [query]` | Featured models, or live search. Tagged `verified` / `experimental`; ★ marks the recommendation for your hardware. |
| `orb setup [--llm TAG --stt ID --tts ID]` | Installs runtimes, downloads models, starts and verifies services. Defaults to the recommended models for your hardware. Live orb on top; steps, progress, speed/ETA and log tail below. Ctrl-C cancels (partial downloads resume next time). |
| `orb run` | Runs the voice agent; the orb reacts to state and mic/speech level; transcript is shown beneath. Ctrl-C quits. |
| `orb chat` | Text chat with the configured LLM through Ollama (streamed). |
| `orb status` | Config and service up/down status. |
| `orb stop` | Stops ORB's whisper/TTS servers (Ollama is left running). |

Rendering: truecolor half-block (`▀`) pixels, density characters for glow/particles, differential updates, ~24 fps, adapts to terminal resize (SIGWINCH), restores the terminal on exit. Set `NO_COLOR=1` for plain ASCII; when stdout is not a TTY no animation is emitted.
