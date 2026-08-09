#!/usr/bin/env bash
# agent-voice UserPromptSubmit hook (macOS).
#   1. Intercepts in-session commands: voice on / voice text / voice off /
#      voice status / voice engine <name>.
#   2. Otherwise injects the <spoken> summary instruction when voice is active.

ROOT="$HOME/.agent-voice"
STATE="$ROOT/state"
mkdir -p "$STATE"

ENGINES="edge kokoro elevenlabs native"
# The numbered edge-tts shortlist, kept next to its display so they cannot diverge.
EDGE_SHORTLIST="en-GB-SoniaNeural en-GB-RyanNeural en-US-AvaNeural en-US-AndrewNeural en-AU-NatashaNeural en-IE-EmilyNeural"

# Installed default engine, used when a session has no override of its own.
cfg_get() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$ROOT/config" 2>/dev/null | tail -1; }

cfg_engine="edge"
cfg_python="python3"
if [ -f "$ROOT/config" ]; then
  found="$(cfg_get engine)";      [ -n "$found" ] && cfg_engine="$found"
  # python_cmd is the current spelling; kokoro_python is accepted as an older one.
  found="$(cfg_get python_cmd)";  [ -z "$found" ] && found="$(cfg_get kokoro_python)"
  [ -n "$found" ] && cfg_python="$found"
fi

# Speed is one number across every engine, 1.0 being normal, because each engine
# expresses it differently (Kokoro a multiplier, edge-tts a percentage, say a words
# per minute figure). The engines convert it; the user sees one scale.
default_speed() {
  s="$(cfg_get voice_speed)"
  if [ -n "$s" ]; then printf '%s' "$s"; return; fi
  case "$1" in
    kokoro) s="$(cfg_get kokoro_speed)"; printf '%s' "${s:-1.15}" ;;
    edge)
      r="$(cfg_get edge_rate)"
      case "$r" in
        [+-]*%) printf '%s' "$(awk -v p="${r%\%}" 'BEGIN{printf "%.2f", 1 + p/100}')" ;;
        *) printf '1.15' ;;
      esac ;;
    native) printf '1.2' ;;
    *) printf '1.0' ;;
  esac
}

voice_name() {
  case "$1" in
    kokoro)     s="$(cfg_get kokoro_voice)"; printf '%s' "${s:-bf_emma}" ;;
    edge)       s="$(cfg_get edge_voice)";   printf '%s' "${s:-en-US-AvaNeural}" ;;
    elevenlabs) s="$(cfg_get eleven_voice)"; printf '%s' "${s:-JBFqnCBsd6RMkjVDRZzb}" ;;
    *)          s="$(cfg_get native_voice)"; printf '%s' "${s:-system default}" ;;
  esac
}

RAW="$(cat)"
sid="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" session_id)"
prompt="$(printf '%s' "$RAW" | node "$ROOT/lib/json-get.mjs" prompt)"

global_on="$STATE/voice-on"
on_flag="$STATE/on.$sid"
off_flag="$STATE/off.$sid"
text_flag="$STATE/text.$sid"
eng_flag="$STATE/engine.$sid"
spd_flag="$STATE/speed.$sid"

# Normalise the command: lowercase, strip a leading slash or backslash.
cmd="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^[\\/]##')"

# The engine in effect for this session, which the voice commands below act on.
cur_engine="$cfg_engine"
[ -f "$eng_flag" ] && cur_engine="$(cat "$eng_flag")"
vce_flag="$STATE/voice.$cur_engine.$sid"

# The command replies are written to stderr below, which the terminal shows but the
# VS Code extension does not. Rather than rewrite forty call sites, the dispatch is
# wrapped and its output captured, then re-emitted as the structured JSON that every
# client understands: "decision": "block" stops the prompt reaching the model just as
# exit 2 did, and "reason" is shown to the user.
handle_command() {
if [ -n "$sid" ]; then
  case "$cmd" in
    "voice stop"|"shush"|"stop voice")
      # Kill speech from inside the session. The hotkey is faster where it exists,
      # but macOS has none by default, and typing this needs no OS integration at
      # all. Works everywhere, including over SSH.
      if [ -f "$ROOT/shush.sh" ]; then
        bash "$ROOT/shush.sh" >/dev/null 2>&1
        echo "agent-voice: speech stopped." >&2
      else
        echo "agent-voice: shush.sh is missing; re-run the installer." >&2
      fi
      return 2 ;;

    "voice help")
      {
        echo "agent-voice commands (each affects this session only):"
        echo "  voice on                summary plus spoken audio"
        echo "  voice text              summary only, no audio"
        echo "  voice off               back to normal replies"
        echo "  voice stop              stop speech now (also: shush)"
        echo "  voice status            what this session will use right now"
        echo "  voice engine            list engines, then: voice engine 2"
        echo "  voice model             list voices, then: voice model 9"
        echo "  voice preview <n>       hear a voice without switching to it"
        echo "  voice pick              browse voices with arrows and P, in a new window"
        echo "  voice speed             list speeds, then: voice speed 1.5"
        echo "  voice list              same as voice model, lists what is available"
        echo "  voice help              this list"
        echo ""
        echo "  Add 'default' to reset one, for example: voice speed default"
        echo "  Stop speech immediately: type voice stop, or run ~/.agent-voice/shush.sh"
      } >&2
      return 2 ;;

    "voice pick")
      # The same arrow-key picker the installer uses, in its own Terminal window,
      # because this hook cannot read keystrokes itself.
      if [ ! -f "$ROOT/pick-voice.sh" ]; then
        echo "agent-voice: pick-voice.sh is missing; re-run the installer." >&2
      elif [ "$cur_engine" != "kokoro" ]; then
        echo "agent-voice: the picker only covers Kokoro, the one engine whose voices can be auditioned offline." >&2
        echo "  You are on '$cur_engine'. Switch with 'voice engine kokoro', or use 'voice model' for a list." >&2
      elif [ "$(uname)" = "Darwin" ]; then
        osascript -e "tell application \"Terminal\" to do script \"bash '$ROOT/pick-voice.sh' --session '$sid' '$cur_engine'\"" >/dev/null 2>&1 \
          && echo "agent-voice: opened the voice picker in a new Terminal window. Arrows to move, P to hear, Enter to choose." >&2 \
          || echo "agent-voice: could not open a Terminal window. Run it yourself: bash ~/.agent-voice/pick-voice.sh --session $sid" >&2
      else
        echo "agent-voice: no window to open here. Run it yourself in another terminal:" >&2
        echo "  bash ~/.agent-voice/pick-voice.sh --session $sid" >&2
      fi
      return 2 ;;

    "voice preview"|"voice preview "*)
      # Hear a voice without switching to it. Backgrounded so the hook returns at
      # once rather than holding up the prompt while audio plays.
      arg="${cmd#voice preview}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      if [ "$cur_engine" != "kokoro" ]; then
        echo "agent-voice: preview only works on Kokoro, which synthesises locally. You are on '$cur_engine'." >&2
        return 2
      fi
      case "$arg" in
        [0-9]*)
          picked="$(node -e 'const a=require(process.argv[1]); const i=parseInt(process.argv[2],10); process.stdout.write(a[i-1] ? a[i-1].id : "")' "$ROOT/lib/kokoro-voices.json" "$arg" 2>/dev/null)"
          [ -n "$picked" ] && arg="$picked" ;;
      esac
      if [ -z "$arg" ]; then
        echo "agent-voice: say which one, for example 'voice preview 9'. Type 'voice model' for the list." >&2
      elif ! node -e 'process.exit(require(process.argv[1]).some(v => v.id === process.argv[2]) ? 0 : 1)' "$ROOT/lib/kokoro-voices.json" "$arg" 2>/dev/null; then
        echo "agent-voice: '$arg' is not a Kokoro voice. Type 'voice model' to see the list." >&2
      else
        (ROOT="$ROOT" bash "$ROOT/pick-voice.sh" --preview "$arg" >/dev/null 2>&1 &)
        echo "agent-voice: playing $arg. Switch to it with: voice model $arg" >&2
      fi
      return 2 ;;

    "voice list"|"voice list "*|"voice model"|"voice model "*|"voice voice"|"voice voice "*)
      # Bare lists what is available, a number or an id selects, 'default' clears.
      # Numbers index the full catalogue, ordered English first, so they stay stable
      # whether or not the other languages are on screen.
      arg="${cmd#voice }"; arg="${arg#list}"; arg="${arg#model}"; arg="${arg#voice}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      show_voices() {
        want_all="$1"
        case "$cur_engine" in
          kokoro)
            [ -f "$ROOT/lib/kokoro-voices.json" ] || return
            cur="$(voice_name kokoro)"; [ -f "$vce_flag" ] && cur="$(cat "$vce_flag")"
            node -e '
              const all = require(process.argv[1]);
              const showAll = process.argv[2] === "1";
              const cur = process.argv[3];
              const shown = showAll ? all : all.filter(v => v.lang === "British" || v.lang === "American");
              console.error(`agent-voice: Kokoro voices (${shown.length} of ${all.length}). Grades are the model own.`);
              all.forEach((v, i) => {
                if (!shown.includes(v)) return;
                const mark = v.id === cur ? "*" : " ";
                console.error(`  ${mark} ${String(i + 1).padStart(2)}. ${v.id.padEnd(14)} ${v.lang.padEnd(11)} ${v.sex.padEnd(7)} grade ${v.grade}`);
              });
            ' "$ROOT/lib/kokoro-voices.json" "$want_all" "$cur"
            [ "$want_all" = "1" ] || echo "  'voice model all' adds the other 7 languages." >&2
            echo "  * is in use now. Choose with: voice model 9   (or: voice model af_heart)" >&2 ;;
          edge)
            cur="$(voice_name edge)"; [ -f "$vce_flag" ] && cur="$(cat "$vce_flag")"
            echo "agent-voice: common edge-tts voices:" >&2
            i=1
            for e in $EDGE_SHORTLIST; do
              if [ "$e" = "$cur" ]; then mark="*"; else mark=" "; fi
              case "$e" in
                en-GB-Sonia*)   d="British female" ;;
                en-GB-Ryan*)    d="British male" ;;
                en-US-Ava*)     d="American female" ;;
                en-US-Andrew*)  d="American male" ;;
                en-AU-Natasha*) d="Australian female" ;;
                en-IE-Emily*)   d="Irish female" ;;
                *)              d="" ;;
              esac
              printf '  %s %2d. %-20s %s\n' "$mark" "$i" "$e" "$d" >&2
              i=$((i + 1))
            done
            echo "  Hundreds more: python3 -m edge_tts --list-voices" >&2
            echo "  Choose with: voice model 3   (or: voice model en-GB-SoniaNeural)" >&2 ;;
          elevenlabs)
            echo "agent-voice: ElevenLabs voice ids come from your own account at elevenlabs.io/voice-library." >&2
            echo "  There is no list to number here, so paste the id: voice model <voice-id>" >&2 ;;
          *)
            echo "agent-voice: the native engine uses the voice built into the OS." >&2
            echo "  macOS: System Settings > Accessibility > Spoken Content > System Voice." >&2 ;;
        esac
      }

      if [ -z "$arg" ] || [ "$arg" = "all" ]; then
        if [ "$arg" = "all" ]; then show_voices 1; else show_voices 0; fi
        return 2
      fi

      # A bare number selects from the list just shown.
      case "$arg" in
        [0-9]*)
          case "$cur_engine" in
            kokoro)
              picked="$(node -e 'const a=require(process.argv[1]); const i=parseInt(process.argv[2],10); process.stdout.write(a[i-1] ? a[i-1].id : "")' "$ROOT/lib/kokoro-voices.json" "$arg")"
              [ -n "$picked" ] && arg="$picked" ;;
            edge)
              i=1
              for e in $EDGE_SHORTLIST; do
                [ "$i" = "$arg" ] && arg="$e" && break
                i=$((i + 1))
              done ;;
          esac ;;
      esac

      if [ "$arg" = "default" ]; then
        rm -f "$vce_flag"
        echo "agent-voice: voice override cleared; $cur_engine is back to $(voice_name "$cur_engine")" >&2
      else
        ok=1
        if [ "$cur_engine" = "kokoro" ] && [ -f "$ROOT/lib/kokoro-voices.json" ]; then
          node -e 'process.exit(require(process.argv[1]).some(v => v.id === process.argv[2]) ? 0 : 1)' \
            "$ROOT/lib/kokoro-voices.json" "$arg" || ok=0
        fi
        if [ "$ok" = 1 ]; then
          printf '%s' "$arg" > "$vce_flag"
          echo "agent-voice: voice for this session is now $arg (engine $cur_engine)" >&2
        else
          echo "agent-voice: '$arg' is not a Kokoro voice. Type 'voice model' to see the list." >&2
        fi
      fi
      return 2 ;;

    "voice speed"|"voice speed "*)
      # How fast the summary is read, in this session only. One scale across all
      # engines, 1.0 normal, since spoken summaries are often the thing you want
      # to get through quickly.
      arg="${cmd#voice speed}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      # Listed as values rather than numbered, because 1 and 2 are themselves valid
      # speeds and a numbered menu would be ambiguous.
      if [ -z "$arg" ]; then
        cur="$(default_speed "$cur_engine")"; [ -f "$spd_flag" ] && cur="$(cat "$spd_flag")"
        echo "agent-voice: speed is ${cur}x now. Any number from 0.5 to 2.0 works, for example:" >&2
        for p in "0.75|slower" "1.0|normal" "1.25|brisk" "1.5|fast" "1.75|very fast" "2.0|maximum"; do
          v="${p%%|*}"; d="${p##*|}"
          if awk -v a="$v" -v b="$cur" 'BEGIN{exit !(a==b)}'; then mark="*"; else mark=" "; fi
          printf '  %s %-5s %s\n' "$mark" "$v" "$d" >&2
        done
        echo "  Choose with: voice speed 1.5" >&2
        return 2
      fi
      if [ "$arg" = "default" ]; then
        rm -f "$spd_flag"
        eng="$cfg_engine"; [ -f "$eng_flag" ] && eng="$(cat "$eng_flag")"
        echo "agent-voice: speed override cleared; back to $(default_speed "$eng")x" >&2
      elif printf '%s' "$arg" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
        && awk -v v="$arg" 'BEGIN{exit !(v >= 0.5 && v <= 2.0)}'; then
        printf '%s' "$arg" > "$spd_flag"
        echo "agent-voice: speed for this session is now ${arg}x (1.0 is normal)" >&2
      else
        echo "agent-voice: speed must be a number between 0.5 and 2.0, for example 'voice speed 1.5'. Use 'voice speed default' to reset." >&2
      fi
      return 2 ;;
    "voice engine"|"voice engine "*)
      arg="${cmd#voice engine}"
      arg="$(printf '%s' "$arg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      # A bare number selects from the list below; the order is fixed so it is stable.
      case "$arg" in
        [0-9]*)
          i=1
          for e in $ENGINES; do
            [ "$i" = "$arg" ] && arg="$e" && break
            i=$((i + 1))
          done ;;
      esac

      if [ -z "$arg" ]; then
        echo "agent-voice: choose an engine by number or name:" >&2
        i=1
        for e in $ENGINES; do
          if [ "$e" = "$cur_engine" ]; then mark="*"; else mark=" "; fi
          case "$e" in
            edge)       d="free, natural, summary text sent to Microsoft" ;;
            kokoro)     d="free, natural, fully local, 54 voices" ;;
            elevenlabs) d="best quality, needs your API key" ;;
            *)          d="robotic, no dependencies, no network" ;;
          esac
          printf '  %s %d. %-11s %s\n' "$mark" "$i" "$e" "$d" >&2
          i=$((i + 1))
        done
        echo "  * is in use now. Choose with: voice engine 2   (or: voice engine kokoro)" >&2
        return 2
      fi
      if [ "$arg" = "default" ]; then
        rm -f "$eng_flag"
        echo "agent-voice: engine override cleared; this session uses the default ($cfg_engine)." >&2
      elif printf '%s' " $ENGINES " | grep -q " $arg "; then
        printf '%s' "$arg" > "$eng_flag"
        note=""
        if [ "$arg" = "elevenlabs" ] && [ ! -f "$ROOT/elevenlabs-key" ]; then
          note=" (no API key stored, so it will fall back to the native voice)"
        fi
        if [ "$arg" = "kokoro" ] && [ -f "$ROOT/kokoro_serve.py" ]; then
          # Warm the model now so the first reply on the new engine is not slow.
          ("$cfg_python" "$ROOT/kokoro_serve.py" "$STATE" >/dev/null 2>&1 &)
          note=" (warming the model now)"
        fi
        echo "agent-voice: engine for this session is now $arg$note" >&2
      else
        echo "agent-voice: unknown engine '$arg'. Choose from: $ENGINES, or 'default'." >&2
      fi
      return 2 ;;
    "voice on")
      : > "$on_flag"; rm -f "$off_flag" "$text_flag"
      echo "agent-voice: ON (summary + speech) for this session." >&2; exit 2 ;;
    "voice text")
      : > "$on_flag"; : > "$text_flag"; rm -f "$off_flag"
      echo "agent-voice: TEXT-ONLY summary (no audio) for this session." >&2; exit 2 ;;
    "voice off")
      rm -f "$on_flag" "$text_flag"; : > "$off_flag"
      echo "agent-voice: OFF for this session." >&2; exit 2 ;;
    "voice status")
      if [ -f "$text_flag" ]; then st="TEXT-ONLY (summary, no audio)"
      elif [ -f "$on_flag" ]; then st="ON (summary + speech)"
      elif [ -f "$global_on" ] && [ ! -f "$off_flag" ]; then st="ON (global default)"
      else st="OFF"; fi
      if [ -f "$eng_flag" ]; then eng_name="$(cat "$eng_flag")"; eng_from="this session"
      else eng_name="$cfg_engine"; eng_from="default"; fi
      if [ -f "$spd_flag" ]; then spd_val="$(cat "$spd_flag")"; spd_from="this session"
      else spd_val="$(default_speed "$eng_name")"; spd_from="default"; fi
      {
        echo "agent-voice: $st"
        echo "  engine  $eng_name ($eng_from)"
        if [ -f "$STATE/voice.$eng_name.$sid" ]; then
          echo "  voice   $(cat "$STATE/voice.$eng_name.$sid") (this session)"
        else
          echo "  voice   $(voice_name "$eng_name") (default)"
        fi
        echo "  speed   ${spd_val}x ($spd_from, 1.0 is normal)"
        [ "$eng_name" = "elevenlabs" ] && echo "  note    ElevenLabs ignores speed; it has no rate control in this integration."
      } >&2
      return 2 ;;
  esac
fi
  return 0
}

cmd_out="$(handle_command 2>&1)"
cmd_rc=$?
if [ "$cmd_rc" = "2" ]; then
  # Getting this text on screen turned out to be the hard part. stderr with exit 2
  # is documented to show the user and works in a terminal, but the VS Code
  # extension renders none of it: not stderr, not "reason" from a block decision,
  # not "systemMessage". Confirmed from the hook log, where the command fires and
  # replies and the user still sees nothing.
  #
  # So the reply is handed to the model as context instead, with an instruction to
  # print it verbatim. That costs one cheap turn, but the model's reply is the one
  # channel every client displays, which is the whole point.
  printf '%s' "$cmd_out" | CMD="$cmd" node -e '
    let s = "";
    process.stdin.on("data", c => s += c).on("end", () => {
      const text = s.replace(/\n+$/, "");
      const instruction =
        `The user typed the agent-voice command "${process.env.CMD}". The hook has already carried it out;\n` +
        "there is nothing for you to run or change. Output the block below exactly as it is,\n" +
        "inside a code fence, and write nothing else at all: no preamble, no summary, no\n" +
        "<spoken> block.\n\n" + text;
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: instruction
        },
        systemMessage: text
      }) + "\n");
      process.stderr.write(text + "\n");
    });
  '
  exit 0
fi

# Inject the instruction when active.
active=0
if [ -n "$sid" ] && [ -f "$on_flag" ]; then active=1
elif [ -f "$global_on" ] && ! { [ -n "$sid" ] && [ -f "$off_flag" ]; }; then active=1
fi
[ "$active" = 1 ] || exit 0

cat <<'EOF'
Voice mode is active. End every response with a <spoken> block on its own line.
Inside it: 2 to 3 sentences of plain prose. No markdown, no code, no file paths,
no lists, no symbols. State only what changed since my last message and what
decision I need to make. If nothing needs a decision, say what you did and stop.
Written to be heard, not read. Everything above the block stays normal.
EOF
exit 0
