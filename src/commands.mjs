// The in-session `voice ...` command surface, once. This replaces the twin
// 400-line voice-context state machines (bash and PowerShell) that had
// already drifted apart in small ways; every reply string lives here and
// nowhere else.
//
// handleCommand returns { handled, lines }: handled=false means the prompt is
// not a voice command and should flow to the model; handled=true means the
// hook carried it out and `lines` is the reply to show.
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { spawn } from 'child_process';
import { join } from 'path';
import {
  rootDir, resolveSession, defaultVoice, defaultSpeed,
  ENGINE_IDS, EDGE_SHORTLIST, enginesData, libFile,
} from './config.mjs';
import { platform } from './platform/index.mjs';
import { stopAll } from './stop.mjs';

const SPEED_MIN = 0.5;
const SPEED_MAX = 2.0;

function kokoroVoices() {
  try { return JSON.parse(readFileSync(libFile('kokoro-voices.json'), 'utf8')); }
  catch { return []; }
}

function touch(path) { writeFileSync(path, ''); }
function rm(path) { try { unlinkSync(path); } catch { /* fine */ } }
function readFlag(path) { try { return readFileSync(path, 'utf8').trim(); } catch { return ''; } }

export function handleCommand(prompt, sid, home) {
  // Normalise: lowercase, trim, strip a leading slash or backslash.
  const cmd = String(prompt || '').toLowerCase().trim().replace(/^[\\/]/, '');
  if (!sid) return { handled: false, lines: [] };

  const s = resolveSession(sid, home);
  const p = s.paths;
  const root = rootDir(home);
  const engine = s.engine;

  const out = [];
  const say = (...ls) => out.push(...ls);
  const done = () => ({ handled: true, lines: out });

  if (cmd === 'voice stop' || cmd === 'shush' || cmd === 'stop voice') {
    stopAll(home);
    say('agent-voice: speech stopped.');
    return done();
  }

  if (cmd === 'voice help') {
    say(
      'agent-voice commands (each affects this session only):',
      '  voice on                summary plus spoken audio',
      '  voice text              summary only, no audio',
      '  voice off               back to normal replies',
      '  voice stop              stop speech now (also: shush)',
      '  voice status            what this session will use right now',
      '  voice engine            list engines, then: voice engine 2',
      '  voice model             list voices, then: voice model 9',
      '  voice preview <n>       hear a voice without switching to it',
      '  voice pick              browse voices with arrows and P, in a new window',
      '  voice speed             list speeds, then: voice speed 1.5',
      '  voice list              same as voice model, lists what is available',
      '  voice help              this list',
      '',
      "  Add 'default' to reset one, for example: voice speed default",
      '  Stop speech immediately: type voice stop, or run ~/.agent-voice/' + (process.platform === 'win32' ? 'shush.cmd' : 'shush.sh'),
    );
    return done();
  }

  if (cmd === 'voice on') {
    touch(p.on); rm(p.off); rm(p.text);
    say('agent-voice: ON (summary + speech) for this session.');
    return done();
  }
  if (cmd === 'voice text') {
    touch(p.on); touch(p.text); rm(p.off);
    say('agent-voice: TEXT-ONLY summary (no audio) for this session.');
    return done();
  }
  if (cmd === 'voice off') {
    rm(p.on); rm(p.text); touch(p.off);
    say('agent-voice: OFF for this session.');
    return done();
  }

  if (cmd === 'voice status') {
    const st = s.mode === 'text' ? 'TEXT-ONLY (summary, no audio)'
      : s.mode === 'on' ? (existsSync(p.on) ? 'ON (summary + speech)' : 'ON (global default)')
      : 'OFF';
    say(`agent-voice: ${st}`);
    say(`  engine  ${engine} (${s.engineFrom === 'session' ? 'this session' : 'default'})`);
    say(`  voice   ${s.voice} (${s.voiceFrom === 'session' ? 'this session' : 'default'})`);
    say(`  speed   ${s.speed}x (${s.speedFrom === 'session' ? 'this session' : 'default'}, 1.0 is normal)`);
    if (engine === 'elevenlabs') say('  note    ElevenLabs ignores speed; it has no rate control in this integration.');
    return done();
  }

  if (cmd === 'voice pick') {
    if (engine !== 'kokoro') {
      say('agent-voice: the picker only covers Kokoro, the one engine whose voices can be auditioned offline.');
      say(`  You are on '${engine}'. Switch with 'voice engine kokoro', or use 'voice model' for a list.`);
    } else if (platform.openPicker(root, sid, engine)) {
      say('agent-voice: opened the voice picker in a new window. Arrows to move, P to hear, Enter to choose.');
    } else {
      say('agent-voice: could not open a picker window. Run it yourself in another terminal.');
    }
    return done();
  }

  let m;

  if ((m = cmd.match(/^voice preview\b(.*)$/))) {
    let arg = m[1].trim();
    if (engine !== 'kokoro') {
      say(`agent-voice: preview only works on Kokoro, which synthesises locally. You are on '${engine}'.`);
      return done();
    }
    const all = kokoroVoices();
    if (/^\d+$/.test(arg)) {
      const v = all[Number(arg) - 1];
      if (v) arg = v.id;
    }
    if (!arg) {
      say("agent-voice: say which one, for example 'voice preview 9'. Type 'voice model' for the list.");
    } else if (!all.some(v => v.id === arg)) {
      say(`agent-voice: '${arg}' is not a Kokoro voice. Type 'voice model' to see the list.`);
    } else {
      platform.previewVoice(root, arg);
      say(`agent-voice: playing ${arg}. Switch to it with: voice model ${arg}`);
    }
    return done();
  }

  if ((m = cmd.match(/^voice (?:list|model|voice)\b(.*)$/))) {
    let arg = m[1].trim();
    const vceFlag = p.voiceFlag(engine);

    const showVoices = (all) => {
      if (engine === 'kokoro') {
        const cat = kokoroVoices();
        const cur = readFlag(vceFlag) || defaultVoice('kokoro', s.cfg);
        const shown = all ? cat : cat.filter(v => v.lang === 'British' || v.lang === 'American');
        say(`agent-voice: Kokoro voices (${shown.length} of ${cat.length}). Grades are the model's own.`);
        cat.forEach((v, i) => {
          if (!shown.includes(v)) return;
          const mark = v.id === cur ? '*' : ' ';
          say(`  ${mark} ${String(i + 1).padStart(2)}. ${v.id.padEnd(14)} ${v.lang.padEnd(11)} ${v.sex.padEnd(7)} grade ${v.grade}`);
        });
        if (!all) say("  'voice model all' adds the other 7 languages.");
        say('  * is in use now. Choose with: voice model 9   (or: voice model af_heart)');
      } else if (engine === 'edge') {
        const cur = (readFlag(vceFlag) || defaultVoice('edge', s.cfg)).toLowerCase();
        say('agent-voice: common edge-tts voices:');
        EDGE_SHORTLIST.forEach((v, i) => {
          const mark = v.id.toLowerCase() === cur ? '*' : ' ';
          say(`  ${mark} ${String(i + 1).padStart(2)}. ${v.id.padEnd(20)} ${v.desc}`);
        });
        say('  Hundreds more: python -m edge_tts --list-voices');
        say('  Choose with: voice model 3   (or: voice model en-GB-SoniaNeural)');
      } else if (engine === 'elevenlabs') {
        say('agent-voice: ElevenLabs voice ids come from your own account at elevenlabs.io/voice-library.');
        say('  There is no list to number here, so paste the id: voice model <voice-id>');
      } else {
        say('agent-voice: the native engine uses the voice built into the OS.');
        if (process.platform === 'win32') say('  Windows: Settings > Time & language > Speech.');
        else say('  macOS: System Settings > Accessibility > Spoken Content > System Voice.');
      }
    };

    if (!arg || arg === 'all') {
      showVoices(arg === 'all');
      return done();
    }

    // A bare number selects from the list just shown.
    if (/^\d+$/.test(arg)) {
      if (engine === 'kokoro') {
        const v = kokoroVoices()[Number(arg) - 1];
        if (v) arg = v.id;
      } else if (engine === 'edge') {
        const v = EDGE_SHORTLIST[Number(arg) - 1];
        if (v) arg = v.id;
      }
    } else if (engine === 'edge') {
      // The command was lowercased wholesale; restore the shortlist's casing.
      const v = EDGE_SHORTLIST.find(e => e.id.toLowerCase() === arg);
      if (v) arg = v.id;
    }

    if (arg === 'default') {
      rm(vceFlag);
      say(`agent-voice: voice override cleared; ${engine} is back to ${defaultVoice(engine, s.cfg)}`);
    } else if (engine === 'kokoro' && !kokoroVoices().some(v => v.id === arg)) {
      say(`agent-voice: '${arg}' is not a Kokoro voice. Type 'voice model' to see the list.`);
    } else {
      writeFileSync(vceFlag, arg);
      say(`agent-voice: voice for this session is now ${arg} (engine ${engine})`);
    }
    return done();
  }

  if ((m = cmd.match(/^voice speed\b(.*)$/))) {
    const arg = m[1].trim();
    if (!arg) {
      say(`agent-voice: speed is ${s.speed}x now. Any number from ${SPEED_MIN} to ${SPEED_MAX} works, for example:`);
      for (const [v, d] of [['0.75', 'slower'], ['1.0', 'normal'], ['1.25', 'brisk'], ['1.5', 'fast'], ['1.75', 'very fast'], ['2.0', 'maximum']]) {
        const mark = Number(v) === Number(s.speed) ? '*' : ' ';
        say(`  ${mark} ${v.padEnd(5)} ${d}`);
      }
      say('  Choose with: voice speed 1.5');
      return done();
    }
    if (arg === 'default') {
      rm(p.speed);
      say(`agent-voice: speed override cleared; back to ${defaultSpeed(engine, s.cfg)}x`);
    } else if (/^\d+(\.\d+)?$/.test(arg) && Number(arg) >= SPEED_MIN && Number(arg) <= SPEED_MAX) {
      writeFileSync(p.speed, arg);
      say(`agent-voice: speed for this session is now ${arg}x (1.0 is normal)`);
    } else {
      say(`agent-voice: speed must be a number between ${SPEED_MIN} and ${SPEED_MAX}, for example 'voice speed 1.5'. Use 'voice speed default' to reset.`);
    }
    return done();
  }

  if ((m = cmd.match(/^voice engine\b(.*)$/))) {
    let arg = m[1].trim();
    if (/^\d+$/.test(arg)) {
      const id = ENGINE_IDS[Number(arg) - 1];
      if (id) arg = id;
    }
    if (!arg) {
      say('agent-voice: choose an engine by number or name:');
      enginesData.engines.forEach((e, i) => {
        const mark = e.id === engine ? '*' : ' ';
        say(`  ${mark} ${i + 1}. ${e.id.padEnd(11)} ${e.listLine}`);
      });
      say('  * is in use now. Choose with: voice engine 2   (or: voice engine kokoro)');
      return done();
    }
    if (arg === 'default') {
      rm(p.engine);
      say(`agent-voice: engine override cleared; this session uses the default (${s.cfg.engine || 'edge'}).`);
    } else if (ENGINE_IDS.includes(arg)) {
      writeFileSync(p.engine, arg);
      let note = '';
      if (arg === 'elevenlabs' && !existsSync(join(root, 'elevenlabs-key'))) {
        note = ' (no API key stored, so it will fall back to the native voice)';
      }
      if (arg === 'kokoro' && existsSync(join(root, 'kokoro_serve.py'))) {
        // Warm the model now so the first reply on the new engine is not slow.
        const c = spawn(s.python, [join(root, 'kokoro_serve.py'), p.state], { detached: true, stdio: 'ignore' });
        c.unref();
        note = ' (warming the model now)';
      }
      say(`agent-voice: engine for this session is now ${arg}${note}`);
    } else {
      say(`agent-voice: unknown engine '${arg}'. Choose from: ${ENGINE_IDS.join(' ')}, or 'default'.`);
    }
    return done();
  }

  return { handled: false, lines: [] };
}
