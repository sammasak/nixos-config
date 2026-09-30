// GENERATED from sammasak/pi-harness src/ — regenerate with: npm run bundle

// dist/stages/router.js
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// dist/classify.js
var DEFAULT_EP = () => process.env.PICODE_EP || "http://localhost:8080";
var DEFAULT_GATE = () => process.env.PICODE_GATE || "qwen2.5-coder:3b";
function peakConfidence(probs) {
  const n = probs.length;
  if (n <= 1)
    return 1;
  const peak = Math.max(...probs);
  return (n * peak - 1) / (n - 1);
}
async function classifyLabels(prompt, labels, opts = {}) {
  const keys = Object.keys(labels);
  const uniform = () => {
    const probs2 = {};
    for (const k of keys)
      probs2[k] = 1 / keys.length;
    return probs2;
  };
  const fail = () => ({ label: keys[0], confidence: 0, probs: uniform(), ok: false });
  const ep = opts.endpoint || DEFAULT_EP();
  const model = opts.model || DEFAULT_GATE();
  const doFetch = opts.fetchImpl || fetch;
  const temp = opts.temperature ?? 0;
  let j;
  try {
    const r = await doFetch(`${ep}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model,
        messages: [{ role: "user", content: prompt }],
        max_tokens: 1,
        temperature: 0,
        logprobs: true,
        top_logprobs: opts.topLogprobs ?? 20
      }),
      signal: AbortSignal.timeout(opts.timeoutMs ?? 2e4)
    });
    if (!r.ok)
      return fail();
    j = await r.json();
  } catch {
    return fail();
  }
  const top = j?.choices?.[0]?.logprobs?.content?.[0]?.top_logprobs || [];
  const firstCharSurface = {};
  for (const k of keys)
    firstCharSurface[labels[k].trim().charAt(0).toUpperCase()] = k;
  const mass = {};
  for (const k of keys)
    mass[k] = 0;
  let total = 0;
  for (const cand of top) {
    const c = (cand.token || "").trim().charAt(0).toUpperCase();
    const k = firstCharSurface[c];
    if (k === void 0)
      continue;
    const p = Math.exp(cand.logprob ?? -Infinity);
    mass[k] += p;
    total += p;
  }
  if (total === 0) {
    const emitted = (j?.choices?.[0]?.message?.content || "").trim().charAt(0).toUpperCase();
    const k = firstCharSurface[emitted];
    if (k === void 0)
      return fail();
    const probs2 = {};
    for (const kk of keys)
      probs2[kk] = kk === k ? 1 : 0;
    return { label: k, confidence: 0, probs: probs2, ok: false };
  }
  const probs = {};
  if (temp && temp > 0 && temp !== 1) {
    const logs = keys.map((k) => Math.log(mass[k] / total || 1e-12) / temp);
    const m = Math.max(...logs);
    const exps = logs.map((x) => Math.exp(x - m));
    const z = exps.reduce((a, b) => a + b, 0);
    keys.forEach((k, i) => probs[k] = exps[i] / z);
  } else {
    for (const k of keys)
      probs[k] = mass[k] / total;
  }
  let label = keys[0];
  for (const k of keys)
    if (probs[k] > probs[label])
      label = k;
  return { label, confidence: peakConfidence(keys.map((k) => probs[k])), probs, ok: true };
}

// dist/route.js
var LABELS = { SIMPLE: "S", AGENTIC: "A" };
function routePrompt(task) {
  return `You are a fast router for a coding agent. Answer with a SINGLE letter and nothing else:
S = the task is to write ONE new self-contained function, file, or script FROM SCRATCH (no existing project code, no tools, no tests to run).
A = the task requires reading or editing EXISTING code, running commands or tests, debugging, or multiple dependent steps.
Task: ${task}
Answer (S or A):`;
}
async function routeTask(task, opts = {}) {
  const threshold = opts.agenticThreshold ?? 0.5;
  const band = opts.escalateBand ?? 0;
  const base = {
    endpoint: opts.endpoint,
    timeoutMs: opts.timeoutMs,
    fetchImpl: opts.fetchImpl
  };
  const prompt = routePrompt(task);
  const first = await classifyLabels(prompt, LABELS, { ...base, model: opts.gate });
  let pAgentic = first.probs.AGENTIC;
  let confidence = first.confidence;
  let ok = first.ok;
  let escalated = false;
  const uncertain = band > 0 && Math.abs(pAgentic - threshold) <= band;
  if (uncertain) {
    const escalateModel = opts.escalateGate || process.env.PICODE_ESCALATE || "qwen2.5-coder:7b";
    const second = await classifyLabels(prompt, LABELS, { ...base, model: escalateModel });
    if (second.ok) {
      pAgentic = second.probs.AGENTIC;
      confidence = second.confidence;
      ok = true;
      escalated = true;
    }
  }
  const decision = !ok ? "AGENTIC" : pAgentic >= threshold ? "AGENTIC" : "SIMPLE";
  return { decision, pAgentic, confidence, escalated, ok };
}

// dist/codegen.js
var DEFAULT_EP2 = () => process.env.PICODE_EP || "http://localhost:8080";
var DEFAULT_CODER = () => process.env.PICODE_CODER || "qwen2.5-coder:3b";
async function ollamaGenerate(prompt, opts = {}) {
  const doFetch = opts.fetchImpl || fetch;
  const r = await doFetch(`${opts.endpoint || DEFAULT_EP2()}/api/generate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: opts.model || DEFAULT_CODER(),
      prompt,
      stream: false,
      options: { temperature: 0 }
    }),
    signal: AbortSignal.timeout(opts.timeoutMs ?? 12e4)
  });
  if (!r.ok)
    throw new Error(`ollama ${r.status}`);
  const j = await r.json();
  return j.response ?? "";
}
var LANGS = [
  [/\b(rust|rustlang|\.rs\b)\b/i, "rust", "rs"],
  [/\b(bash|shell script|shell|sh script|zsh|posix sh)\b/i, "bash", "sh"],
  [/\b(typescript|\.ts\b)\b/i, "typescript", "ts"],
  [/\b(javascript|node\.?js|\.js\b)\b/i, "javascript", "js"],
  [/\b(golang|go language|go program|go function)\b/i, "go", "go"],
  // A trailing \b can never follow the non-word chars in "c++"/"c#", so match
  // those symbol forms without it (word boundary only on the leading side).
  [/\bc\+\+|\bcpp\b/i, "cpp", "cpp"],
  [/\b(java|\.java\b)\b/i, "java", "java"],
  [/\b(kotlin|\.kt\b)\b/i, "kotlin", "kt"],
  [/\b(ruby|\.rb\b)\b/i, "ruby", "rb"],
  [/\b(php|\.php\b)\b/i, "php", "php"],
  [/\bc#|\bcsharp\b|\.cs\b/i, "csharp", "cs"],
  [/\b(swift|\.swift\b)\b/i, "swift", "swift"],
  [/\b(sql|postgres|sqlite|mysql)\b/i, "sql", "sql"]
];
function detectLang(task) {
  for (const [re, tag, ext] of LANGS)
    if (re.test(task))
      return { tag, ext };
  return { tag: "python", ext: "py" };
}
var REFUSAL_RE = /^\s*(?:#|\/\/|--|;)?\s*(?:i (?:can'?t|cannot|am unable|won'?t|do not|don'?t)|i'?m (?:sorry|unable|afraid)|sorry|as an ai|unable to|cannot (?:help|assist)|there is no|no code|please provide|could you (?:clarify|provide))/i;
var CODE_TOKEN_RE = /[{}()=;]|=>|\b(?:def|class|import|from|return|for|while|if|lambda|fn|let|struct|impl|use|pub|mut|func|package|var|const|function|async|echo|print|printf)\b/;
var CODE_STRUCT_RE = /(?:^|\n)\s*(?:def |fn |func |function |class |struct |impl |interface |enum |public |private |protected |static |const |let |var |import |from |package |use |namespace |#include|#!|@\w)/;
function looksLikeCode(code) {
  if (CODE_STRUCT_RE.test(code))
    return true;
  const lines = code.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0)
    return false;
  const codey = lines.filter((l) => /[;{}:)\]]$|^[}\])]/.test(l)).length;
  return codey / lines.length >= 0.5;
}
function extractFencedCode(resp) {
  const fenceCount = (resp.match(/```/g) || []).length;
  if (fenceCount !== 2)
    return "";
  const m = resp.match(/```[a-zA-Z0-9+#-]*[ \t]*\r?\n([\s\S]*?)```/);
  if (!m)
    return "";
  const code = m[1].trim();
  if (code.length < 3)
    return "";
  if (REFUSAL_RE.test(code))
    return "";
  if (!CODE_TOKEN_RE.test(code))
    return "";
  if (!looksLikeCode(code))
    return "";
  return code;
}
function codegenPrompt(task, tag) {
  return `${task}
Respond with ONLY the code inside one \`\`\`${tag} code block. No prose.`;
}

// dist/env.js
function envNumber(name, fallback) {
  const raw = process.env[name];
  if (raw === void 0 || raw === "")
    return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}
function envString(name, fallback) {
  const v = process.env[name];
  return v === void 0 || v === "" ? fallback : v;
}

// dist/stages/router.js
var CODEGEN_TIMEOUT_MS = envNumber("PICODE_CODEGEN_TIMEOUT_MS", 12e4);
var MAX_TASK_CHARS = envNumber("PICODE_MAX_TASK_CHARS", 4e3);
var CODER = envString("PICODE_CODER", "qwen2.5-coder:3b");
function safeNotify(ctx, msg, level) {
  try {
    ctx.ui.notify(msg, level);
  } catch {
  }
}
function router_default(pi) {
  pi.on("input", async (event, ctx) => {
    try {
      if (event.source === "extension")
        return { action: "continue" };
      if (event.streamingBehavior)
        return { action: "continue" };
      if (event.images?.length)
        return { action: "continue" };
      const task = event.text.trim();
      if (!task || task.startsWith("/"))
        return { action: "continue" };
      if (task.length > MAX_TASK_CHARS)
        return { action: "continue" };
      let decision;
      let pAgentic = 1;
      let routeOk = false;
      try {
        const r = await routeTask(task, {
          agenticThreshold: envNumber("PICODE_AGENTIC_THRESHOLD", 0.5),
          escalateBand: envNumber("PICODE_ESCALATE_BAND", 0)
        });
        decision = r.decision;
        pAgentic = r.pAgentic;
        routeOk = r.ok;
      } catch (e) {
        safeNotify(ctx, `[stage1] route failed (${String(e)}); full loop`, "warning");
        return { action: "continue" };
      }
      safeNotify(ctx, `[stage1] route: ${decision} (p_agentic=${pAgentic.toFixed(2)}${routeOk ? "" : ", no-signal"})`, "info");
      if (decision === "AGENTIC")
        return { action: "continue" };
      const { tag, ext } = detectLang(task);
      let code = "";
      try {
        const resp = await ollamaGenerate(codegenPrompt(task, tag), { model: CODER, timeoutMs: CODEGEN_TIMEOUT_MS });
        code = extractFencedCode(resp);
      } catch (e) {
        safeNotify(ctx, `[stage1] fast path failed (${String(e)}); full loop`, "warning");
        return { action: "continue" };
      }
      if (!code) {
        safeNotify(ctx, "[stage1] no fenced code returned; full loop", "warning");
        return { action: "continue" };
      }
      let out = process.env.PICODE_OUT || `picode_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`;
      let wroteOk = false;
      try {
        writeFileSync(out, code + "\n");
        wroteOk = true;
      } catch {
      }
      if (!wroteOk) {
        try {
          const tmp = join(tmpdir(), `picode_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`);
          writeFileSync(tmp, code + "\n");
          out = tmp;
          wroteOk = true;
        } catch {
        }
      }
      try {
        pi.sendMessage({ customType: "harness-fastpath", content: "```" + tag + "\n" + code + "\n```", display: true, details: { out: wroteOk ? out : null, wroteOk, lang: tag } }, { triggerTurn: false });
      } catch {
      }
      let shownFullInline = false;
      if (!wroteOk) {
        const short = code.length <= 1500;
        try {
          ctx.ui.notify(short ? code : code.slice(0, 1500) + "\n\u2026(truncated \u2014 see full loop)", "info");
          shownFullInline = short;
        } catch {
        }
      }
      if (!wroteOk && !shownFullInline) {
        return { action: "continue" };
      }
      safeNotify(ctx, `[stage1] fast path done${wroteOk ? ` (wrote ${out})` : " (shown inline)"}`, "info");
      return { action: "handled" };
    } catch (e) {
      safeNotify(ctx, `[stage1] error (${String(e)}); full loop`, "warning");
      return { action: "continue" };
    }
  });
}

// dist/complexity.js
var LABELS2 = { small: "1", medium: "2", large: "3" };
function complexityPrompt(task) {
  return `Rate how hard this coding task is for a small language model to solve correctly in one shot. Answer with a SINGLE digit and nothing else:
1 = trivial: a short well-known function (factorial, gcd, palindrome, string helpers).
2 = moderate: a standard algorithm or data structure, or a function with a few edge cases.
3 = hard: concurrency, subtle correctness, parsers, multiple interacting pieces, or tricky invariants.
Task: ${task}
Answer (1, 2, or 3):`;
}
async function classifyComplexity(task, opts = {}) {
  const r = await classifyLabels(complexityPrompt(task), LABELS2, opts);
  return { tier: r.label, confidence: r.confidence, probs: r.probs, ok: r.ok };
}
function modelForTier(tier) {
  const small = process.env.PICODE_MODEL_SMALL || "qwen2.5-coder:3b";
  const medium = process.env.PICODE_MODEL_MEDIUM || "qwen2.5-coder:7b";
  const large = process.env.PICODE_MODEL_LARGE || "qwen2.5-coder:7b";
  return tier === "small" ? small : tier === "medium" ? medium : large;
}

// dist/stages/model-tier.js
var PROVIDER = envString("PICODE_PROVIDER", "ollama");
var GATE = envString("PICODE_GATE", "qwen2.5-coder:3b");
var SMALL = envString("PICODE_MODEL_SMALL", "qwen2.5-coder:3b");
function safeNotify2(ctx, msg, level) {
  try {
    ctx.ui.notify(msg, level);
  } catch {
  }
}
function resolve(ctx, id) {
  try {
    return ctx.modelRegistry.find(PROVIDER, id) ?? void 0;
  } catch {
    return void 0;
  }
}
function lastUserText(messages) {
  const content = messages.filter((m) => m.role === "user").at(-1)?.content ?? "";
  if (typeof content === "string")
    return content;
  return content.flatMap((b) => b.type === "text" ? [b.text] : []).join("\n");
}
function model_tier_default(pi) {
  pi.registerVirtualModel({
    provider: "harness",
    id: "auto",
    name: "Auto (harness)",
    async route(request, ctx) {
      let desiredId = SMALL;
      let state;
      try {
        if (request.reason === "direct") {
          desiredId = SMALL;
        } else if (request.state) {
          desiredId = request.state.model;
          state = request.state;
        } else {
          const { tier, ok } = await classifyComplexity(lastUserText(request.messages).slice(0, 16e3), { model: GATE });
          if (ok)
            desiredId = modelForTier(tier);
          state = { model: desiredId };
        }
      } catch {
        desiredId = SMALL;
        state = { model: SMALL };
      }
      for (const id of [desiredId, SMALL]) {
        const m = resolve(ctx, id);
        if (m)
          return { model: m, thinkingLevel: request.thinkingLevel, state: state ?? { model: id } };
      }
      if (request.previous?.model) {
        safeNotify2(ctx, `[stage2] model '${desiredId}' not in catalog; keeping current model`, "warning");
        return { model: request.previous.model, thinkingLevel: request.thinkingLevel, state };
      }
      const msg = `[stage2] no configured model resolved (provider=${PROVIDER}, tried '${desiredId}' and '${SMALL}'); check PICODE_PROVIDER/PICODE_MODEL_*`;
      safeNotify2(ctx, msg, "error");
      throw new Error(msg);
    }
  });
}

// dist/index.js
function dist_default(pi) {
  router_default(pi);
  if (typeof pi.registerVirtualModel === "function") {
    try {
      model_tier_default(pi);
    } catch {
    }
  }
}
export {
  dist_default as default
};
