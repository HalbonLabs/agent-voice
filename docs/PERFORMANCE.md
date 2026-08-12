# Performance

## Synthesis times

Measured on CPU with torch 2.13, the same method for each engine:

| Engine | Time to produce the audio |
| ------ | ------------------------- |
| Kokoro, warm daemon | **1.7 s** |
| edge-tts | 2.6 s |
| Kokoro, first reply after install | ~12 s |

The hooks are Node and return in ~100 ms on this hardware (Stop hook 100 ms,
prompt hook 124 ms, measured end to end including Node startup), with speech
continuing in a detached process no agent waits for. The PowerShell hooks
they replaced took ~1.4 s, of which 643 ms was `powershell.exe` startup
itself (measured against a bare `exit 0`) and most of the rest .NET assembly
loading; that overhead now exists only inside the detached speaker, where it
delays nothing.

## Why the Kokoro daemon exists

A fresh Python process spends 6.2 s importing PyTorch and 2.4 s building the
pipeline before doing 1.6 s of actual synthesis, and the Stop hook runs a
fresh process every reply. So `kokoro_serve.py` keeps one warm process
resident: the model loads once, and each reply pays only the synthesis.

Daemon behaviour:

- Listens on loopback only, on an OS-assigned port, and requires a token from
  a file only your account can read (created `0600`). It writes only
  allowlisted synthesis filenames inside its own state dir, and bounds
  request bodies at 64 KB and text at 8 KB.
- The port file is published only after the model has loaded, so a successful
  connect means ready to synthesise.
- Costs about 1.7 GB of RAM while resident; exits by itself after 15 idle
  minutes. `uninstall` shuts it down immediately.
- Single-daemon lock records the holder's PID; a lock whose holder is dead is
  taken over immediately.
- If it is not running, synthesis still works via the slow ~12 s in-process
  path, which then starts a daemon for next time. Nothing to manage by hand.

You do not need to install `espeak-ng` separately: the `espeakng-loader`
dependency bundles it. The installer pre-fetches the weights (~300 MB) and a
small spaCy language model, and warms the daemon, so the first spoken reply
is quick.
