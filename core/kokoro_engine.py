"""Shared Kokoro synthesis for agent-voice.

Imported by both the one-shot client (kokoro-tts.py) and the warm daemon
(kokoro-serve.py). Importing this module is what costs ~6s, because it pulls in
PyTorch, so the client imports it lazily and only when the daemon is unavailable.

Underscored filename, unlike its hyphenated siblings, so it can be imported.
"""

import numpy as np
import soundfile as sf
from kokoro import KPipeline

# Language is inferred from the voice-name prefix, per Kokoro's convention:
# 'a' American English, 'b' British English, 'e' Spanish, 'f' French, 'h' Hindi,
# 'i' Italian, 'j' Japanese, 'p' Brazilian Portuguese, 'z' Mandarin.
LANGS = ("a", "b", "e", "f", "h", "i", "j", "p", "z")

REPO_ID = "hexgrad/Kokoro-82M"
SAMPLE_RATE = 24000
DEFAULT_VOICE = "bf_emma"
DEFAULT_SPEED = 1.15

# One pipeline per language, built on demand and kept for the process lifetime.
# In the daemon this is the whole point: build once, reuse for every reply.
_pipelines = {}


def lang_for(voice):
    """Kokoro language code for a voice name, defaulting to American English."""
    return voice[0] if voice[:1] in LANGS else "a"


def get_pipeline(lang):
    if lang not in _pipelines:
        # repo_id passed explicitly only to silence Kokoro's default-repo warning.
        _pipelines[lang] = KPipeline(lang_code=lang, repo_id=REPO_ID)
    return _pipelines[lang]


def synth_to_wav(text, out, voice=DEFAULT_VOICE, speed=DEFAULT_SPEED):
    """Synthesise text to a 24 kHz mono WAV at `out`. Raises on failure."""
    pipeline = get_pipeline(lang_for(voice))
    chunks = [np.asarray(audio, dtype="float32") for _gs, _ps, audio in pipeline(text, voice=voice, speed=speed)]
    if not chunks:
        raise RuntimeError("kokoro produced no audio")
    sf.write(out, np.concatenate(chunks), SAMPLE_RATE)
    return out
