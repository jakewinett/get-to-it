// The "Ask" assistant: one turn of conversation with Claude, which can add and update goals
// through tools. Every tool runs as the signed-in user (RLS applies), so the assistant can only
// touch that user's rows. Badges come from the same SQL functions the app calls.
//
// Secrets: ANTHROPIC_API_KEY (set it under Edge Functions → Secrets in the Supabase dashboard).
// SUPABASE_URL and the project's keys are provided by the platform.
//
// Request:  { input, input_mode: "text" | "voice", history?: [{ role, content }], today?, timezone? }
// Response: { reply, changed, badges }

import Anthropic from "npm:@anthropic-ai/sdk@1.5.0";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.119.0";

const MODEL = "claude-opus-5-5";
const MAX_ROUNDS = 8;

type Beta = Anthropic.Beta.Messages.BetaMessageParam;

const SYSTEM = `You are the assistant inside Get To It, a personal goal app for one person.
You help them add goals, update goals and milestones, log progress, and keep moving.

How goals work: each goal has a category, a time frame (short: next 3 months, mid: 3 to 12 months,
long: a year or more), an optional target (a date and/or a label such as "April 2027"), and ordered
milestones. The app picks up to three milestones a day for Today's focus, soonest due first.

How to act:
- Use the tools to make changes. Never say something is done unless the tool call succeeded.
- Use ids from the snapshot or from tool results. If you can't tell which goal or milestone they
  mean, ask one short question instead of guessing.
- When they add a goal, give it 1 to 3 first milestones, the first one small enough to finish this
  week. Infer the category and time frame; ask only if it's genuinely unclear.
- When they say they did something, complete the matching milestone, or add a note to the goal if
  no milestone matches.
- Dates are YYYY-MM-DD. Work relative dates out from today's date in the snapshot.

How to reply: one to three short sentences, plain text, no markdown or lists. Replies may be read
aloud. Be calm and point at the next concrete step ("Done. Next up: draft the agenda."). Never
shame a missed day or a late milestone; the answer to a miss is to start now.`;

const TOOLS: Anthropic.Beta.Messages.BetaTool[] = [
  {
    name: "add_goal",
    description: "Create a new goal with its first milestones.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Short goal title, e.g. \"Run a 10K\"" },
        category: { type: "string", description: "Category name from the snapshot" },
        horizon: { type: "string", enum: ["short", "mid", "long"] },
        target_date: { type: "string", description: "YYYY-MM-DD, only when a specific date is known" },
        target_label: { type: "string", description: "Loose target such as \"April 2027\" or \"Summer 2027\"" },
        milestones: { type: "array", items: { type: "string" }, description: "1 to 3 first milestones, in order" },
      },
      required: ["title", "category", "horizon", "milestones"],
      additionalProperties: false,
    },
  },
  {
    name: "update_goal",
    description:
      "Change a goal's title, time frame, target or status. Sending target_date or target_label replaces " +
      "the whole target: a field you leave out is cleared (a date alone shows as the formatted date).",
    input_schema: {
      type: "object",
      properties: {
        goal_id: { type: "string" },
        title: { type: "string" },
        horizon: { type: "string", enum: ["short", "mid", "long"] },
        target_date: { type: "string", description: "YYYY-MM-DD" },
        target_label: { type: "string" },
        status: { type: "string", enum: ["active", "completed", "archived"] },
      },
      required: ["goal_id"],
      additionalProperties: false,
    },
  },
  {
    name: "add_milestone",
    description: "Add a milestone to the end of a goal's list.",
    input_schema: {
      type: "object",
      properties: {
        goal_id: { type: "string" },
        title: { type: "string" },
        due_date: { type: "string", description: "YYYY-MM-DD" },
      },
      required: ["goal_id", "title"],
      additionalProperties: false,
    },
  },
  {
    name: "update_milestone",
    description: "Rename a milestone or change its due date. Send due_date as an empty string to clear it.",
    input_schema: {
      type: "object",
      properties: {
        milestone_id: { type: "string" },
        title: { type: "string" },
        due_date: { type: "string", description: "YYYY-MM-DD, or empty to clear" },
      },
      required: ["milestone_id"],
      additionalProperties: false,
    },
  },
  {
    name: "complete_milestone",
    description: "Mark a milestone done. Returns any badges earned.",
    input_schema: {
      type: "object",
      properties: { milestone_id: { type: "string" } },
      required: ["milestone_id"],
      additionalProperties: false,
    },
  },
  {
    name: "add_note",
    description: "Add a progress note or update to a goal. Returns any badges earned.",
    input_schema: {
      type: "object",
      properties: { goal_id: { type: "string" }, body: { type: "string" } },
      required: ["goal_id", "body"],
      additionalProperties: false,
    },
  },
];

// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const authHeader = req.headers.get("Authorization") ?? "";
  const db = createClient(url, publishableKey(), { global: { headers: { Authorization: authHeader } } });

  const { data: auth } = await db.auth.getUser(authHeader.replace(/^Bearer\s+/i, ""));
  const user = auth?.user;
  if (!user) return json({ error: "Sign in first." }, 401);

  let body: { input?: string; input_mode?: string; history?: { role: string; content: string }[]; today?: string; timezone?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Body must be JSON." }, 400);
  }
  const input = (body.input ?? "").trim().slice(0, 2000);
  if (!input) return json({ error: "Say or type something first." }, 400);
  const inputMode = body.input_mode === "voice" ? "voice" : "text";

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ error: "The assistant isn't set up yet (missing ANTHROPIC_API_KEY)." }, 503);
  const claude = new Anthropic({ apiKey });

  const today = /^\d{4}-\d{2}-\d{2}$/.test(body.today ?? "") ? body.today! : new Date().toISOString().slice(0, 10);
  const snapshot = await loadSnapshot(db, today, body.timezone);

  const messages: Beta[] = [];
  for (const turn of (body.history ?? []).slice(-12)) {
    const role = turn.role === "assistant" ? "assistant" : "user";
    const content = String(turn.content ?? "").slice(0, 2000);
    if (!content) continue;
    // The API wants turns to alternate; merge any repeats.
    const last = messages[messages.length - 1];
    if (last && last.role === role && typeof last.content === "string") last.content += "\n" + content;
    else messages.push({ role, content });
  }
  if (messages[0]?.role === "assistant") messages.shift();
  const last = messages[messages.length - 1];
  if (last?.role === "user" && typeof last.content === "string") last.content += "\n" + input;
  else messages.push({ role: "user", content: input });

  const actions: { tool: string; input: unknown; ok: boolean; error?: string }[] = [];
  const badges: string[] = [];
  let changed = false;
  let reply = "";
  let modelUsed = MODEL;
  let inputTokens = 0;
  let outputTokens = 0;

  try {
    for (let round = 0; round < MAX_ROUNDS; round++) {
      const response = await claude.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        output_config: { effort: "low" },
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        cache_control: { type: "ephemeral" },
        system: [
          { type: "text", text: SYSTEM },
          { type: "text", text: snapshot },
        ],
        tools: TOOLS,
        messages,
      });
      modelUsed = response.model;
      inputTokens += response.usage.input_tokens;
      outputTokens += response.usage.output_tokens;

      const text = response.content
        .flatMap((b) => (b.type === "text" ? [b.text] : []))
        .join(" ")
        .trim();
      if (text) reply = text;

      if (response.stop_reason === "pause_turn") {
        messages.push({ role: "assistant", content: response.content });
        continue;
      }
      if (response.stop_reason !== "tool_use") {
        if (response.stop_reason === "refusal" && !text) reply = "I can't help with that one. Try asking another way.";
        break;
      }

      messages.push({ role: "assistant", content: response.content });
      const results: Anthropic.Beta.Messages.BetaToolResultBlockParam[] = [];
      for (const block of response.content) {
        if (block.type !== "tool_use") continue;
        try {
          const result = await runTool(db, user.id, block.name, block.input as Record<string, unknown>);
          actions.push({ tool: block.name, input: block.input, ok: true });
          changed = true;
          badges.push(...result.badges);
          results.push({ type: "tool_result", tool_use_id: block.id, content: JSON.stringify(result.data) });
        } catch (e) {
          const message = e instanceof Error ? e.message : String(e);
          actions.push({ tool: block.name, input: block.input, ok: false, error: message });
          results.push({ type: "tool_result", tool_use_id: block.id, content: message, is_error: true });
        }
      }
      messages.push({ role: "user", content: results });
    }
  } catch (e) {
    console.error("assistant error", e);
    if (e instanceof Anthropic.RateLimitError) return json({ error: "The assistant is busy. Try again in a minute." }, 429);
    if (e instanceof Anthropic.APIError) return json({ error: "The assistant couldn't answer. Try again." }, 502);
    return json({ error: "Something went wrong. Try again." }, 500);
  }

  if (!reply) reply = changed ? "Done." : "Tell me a goal to add, or what you got done.";

  // Log the turn. Clients can't write assistant_turns, so this uses the secret key.
  try {
    const admin = createClient(url, secretKey());
    await admin.from("assistant_turns").insert({
      user_id: user.id,
      input_mode: inputMode,
      input,
      reply,
      actions,
      model: modelUsed,
      input_tokens: inputTokens,
      output_tokens: outputTokens,
    });
  } catch (e) {
    console.error("couldn't log assistant turn", e);
  }

  return json({ reply, changed, badges: [...new Set(badges)] });
});

// ---------------------------------------------------------------------------
// Tools

async function runTool(
  db: SupabaseClient,
  userId: string,
  name: string,
  input: Record<string, unknown>,
): Promise<{ data: unknown; badges: string[] }> {
  const str = (key: string) => (typeof input[key] === "string" ? (input[key] as string).trim() : undefined);
  const date = (key: string) => {
    const value = str(key);
    if (value === undefined || value === "") return value;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error(`${key} must be YYYY-MM-DD`);
    return value;
  };
  const check = <T>(result: { data: T; error: { message: string } | null }) => {
    if (result.error) throw new Error(result.error.message);
    return result.data;
  };

  switch (name) {
    case "add_goal": {
      const title = str("title");
      if (!title) throw new Error("title is required");
      const categories = check(await db.from("categories").select("id,name").is("archived_at", null)) ?? [];
      const wanted = (str("category") ?? "").toLowerCase();
      const category = categories.find((c) => c.name.toLowerCase() === wanted);
      if (!category) throw new Error(`No category named "${str("category")}". Use one of: ${categories.map((c) => c.name).join(", ")}`);
      const targetDate = date("target_date") || null;
      const goal = check(
        await db.from("goals").insert({
          user_id: userId,
          title,
          category_id: category.id,
          horizon: str("horizon") ?? "short",
          target_date: targetDate,
          target_label: str("target_label") || (targetDate ? formatDate(targetDate) : null),
          source: "assistant",
        }).select("id").single(),
      );
      if (!goal) throw new Error("The goal didn't save");
      const steps = Array.isArray(input.milestones)
        ? (input.milestones as unknown[]).map((s) => String(s).trim()).filter(Boolean).slice(0, 10)
        : [];
      const rows = (steps.length ? steps : ["Pick the first small step"]).map((t, i) => ({
        user_id: userId,
        goal_id: goal.id,
        title: t,
        position: i + 1,
      }));
      const milestones = check(await db.from("milestones").insert(rows).select("id,title"));
      return { data: { goal_id: goal.id, milestones }, badges: [] };
    }

    case "update_goal": {
      const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
      const title = str("title");
      if (title) patch.title = title;
      const horizon = str("horizon");
      if (horizon) patch.horizon = horizon;
      if ("target_date" in input || "target_label" in input) {
        const targetDate = date("target_date") || null;
        patch.target_date = targetDate;
        patch.target_label = str("target_label") || (targetDate ? formatDate(targetDate) : null);
      }
      const status = str("status");
      if (status) {
        patch.status = status;
        patch.completed_at = status === "completed" ? new Date().toISOString() : null;
      }
      const goal = check(await db.from("goals").update(patch).eq("id", str("goal_id")).select("id,title").maybeSingle());
      if (!goal) throw new Error("No goal with that id");
      return { data: goal, badges: [] };
    }

    case "add_milestone": {
      const goalId = str("goal_id");
      const title = str("title");
      if (!title) throw new Error("title is required");
      const last = check(
        await db.from("milestones").select("position").eq("goal_id", goalId).order("position", { ascending: false }).limit(1),
      );
      const milestone = check(
        await db.from("milestones").insert({
          user_id: userId,
          goal_id: goalId,
          title,
          position: (last?.[0]?.position ?? 0) + 1,
          due_date: date("due_date") || null,
        }).select("id,title").single(),
      );
      return { data: milestone, badges: [] };
    }

    case "update_milestone": {
      const patch: Record<string, unknown> = {};
      const title = str("title");
      if (title) patch.title = title;
      if ("due_date" in input) patch.due_date = date("due_date") || null;
      if (!Object.keys(patch).length) throw new Error("Nothing to change");
      const milestone = check(
        await db.from("milestones").update(patch).eq("id", str("milestone_id")).select("id,title,due_date").maybeSingle(),
      );
      if (!milestone) throw new Error("No milestone with that id");
      return { data: milestone, badges: [] };
    }

    case "complete_milestone": {
      const earned = check(await db.rpc("complete_milestone", { p_milestone: str("milestone_id") })) ?? [];
      const badges = await badgeNames(db, earned);
      return { data: { done: true, badges_earned: badges }, badges };
    }

    case "add_note": {
      const body = str("body");
      if (!body) throw new Error("body is required");
      const earned = check(await db.rpc("add_note", { p_goal: str("goal_id"), p_body: body, p_source: "assistant" })) ?? [];
      const badges = await badgeNames(db, earned);
      return { data: { saved: true, badges_earned: badges }, badges };
    }

    default:
      throw new Error(`Unknown tool ${name}`);
  }
}

async function badgeNames(db: SupabaseClient, earned: { badge_key?: string | null }[]): Promise<string[]> {
  const keys = earned.map((e) => e.badge_key).filter((k): k is string => !!k);
  if (!keys.length) return [];
  const { data } = await db.from("badge_catalog").select("key,name").in("key", keys);
  return keys.map((k) => data?.find((b) => b.key === k)?.name ?? k);
}

// ---------------------------------------------------------------------------
// Context

async function loadSnapshot(db: SupabaseClient, today: string, timezone?: string): Promise<string> {
  const [{ data: categories }, { data: goals }] = await Promise.all([
    db.from("categories").select("id,name").is("archived_at", null).order("position"),
    db.from("goals")
      .select("id,title,horizon,target_date,target_label,status,categories(name),milestones(id,title,position,due_date,completed_at,broken_down_at)")
      .eq("status", "active")
      .order("created_at"),
  ]);

  const lines = [`Today is ${today}${timezone ? ` (${timezone})` : ""}.`];
  lines.push(`Categories: ${(categories ?? []).map((c) => c.name).join(", ") || "none"}.`);
  if (!goals?.length) {
    lines.push("No active goals yet.");
  } else {
    lines.push("Active goals:");
    for (const g of goals) {
      const category = (g.categories as unknown as { name: string } | null)?.name ?? "?";
      const target = g.target_label ?? (g.target_date ? formatDate(g.target_date) : "no target");
      lines.push(`- goal ${g.id}: "${g.title}" · ${category} · ${g.horizon} · target ${target}`);
      const milestones = (g.milestones ?? [])
        .filter((m) => !m.broken_down_at)
        .sort((a, b) => a.position - b.position);
      for (const m of milestones) {
        const state = m.completed_at ? "done" : "open";
        lines.push(`  - milestone ${m.id}: [${state}] ${m.title}${m.due_date ? ` · due ${m.due_date}` : ""}`);
      }
    }
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Helpers

function formatDate(isoDay: string): string {
  const [y, m, d] = isoDay.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
}

function publishableKey(): string {
  const keys = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (keys) return JSON.parse(keys)["default"];
  return Deno.env.get("SUPABASE_ANON_KEY")!;
}

function secretKey(): string {
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keys) return JSON.parse(keys)["default"];
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
