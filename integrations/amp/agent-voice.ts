// agent-voice shim for Amp (https://ampcode.com), which runs plugins
// in-process under Bun rather than shelling out to hooks.
//
// STATUS: written against Amp's documented plugin surface (agent.start
// appends to the user message; agent.end carries messages[] with the full
// assistant reply inline), but NOT yet exercised against a live Amp. Treat
// it as a starting point. Install: copy to ~/.config/amp/plugins/.
//
// It reuses the same two Node hooks every other agent uses, so behaviour
// (commands, grounded facts, policy, earcons) is identical.
import { homedir } from "os";
import { join } from "path";

const HOOK_DIR = join(homedir(), ".agent-voice", "src");

async function runHook(script: string, payload: unknown): Promise<string> {
  const proc = Bun.spawn(["node", join(HOOK_DIR, script)], {
    stdin: new TextEncoder().encode(JSON.stringify(payload)),
    stdout: "pipe",
    stderr: "ignore",
  });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return out;
}

export default {
  name: "agent-voice",

  async "agent.start"(event: { thread: { id: string }; prompt?: string }) {
    const out = await runHook("hook-prompt.mjs", {
      session_id: event.thread?.id ?? "",
      prompt: event.prompt ?? "",
    });
    if (!out.trim()) return undefined;
    // A command reply arrives as the JSON envelope; the contract as plain text.
    try {
      const j = JSON.parse(out);
      const ctx = j?.hookSpecificOutput?.additionalContext;
      if (ctx) return { message: { content: ctx } };
    } catch {
      return { message: { content: out } };
    }
    return undefined;
  },

  async "agent.end"(event: { thread: { id: string }; messages?: Array<{ role: string; content: unknown }> }) {
    const last = [...(event.messages ?? [])].reverse().find(m => m.role === "assistant");
    const text = typeof last?.content === "string"
      ? last.content
      : Array.isArray(last?.content)
        ? (last!.content as Array<{ type?: string; text?: string }>)
            .filter(b => b?.type === "text").map(b => b.text ?? "").join("\n")
        : "";
    if (!text) return;
    await runHook("hook-stop.mjs", {
      session_id: event.thread?.id ?? "",
      last_assistant_message: text,
    });
  },
};
