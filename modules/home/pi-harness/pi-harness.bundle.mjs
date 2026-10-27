// GENERATED from sammasak/pi-harness src/ — regenerate with: npm run bundle

// dist/stages/router.js
import { unlinkSync, writeFileSync, writeSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

// dist/env.js
function envNumber(name, fallback) {
  const raw = process.env[name]?.trim();
  if (!raw)
    return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}
function envTimeoutMs(name, fallback) {
  const n = envNumber(name, fallback);
  return Number.isInteger(n) && n > 0 && n <= 2 ** 31 - 1 ? n : fallback;
}
function envString(name, fallback) {
  const v = process.env[name];
  return v === void 0 || v === "" ? fallback : v;
}
var endpoint = () => envString("PICODE_EP", "http://localhost:8080").replace(/\/+$/, "");
var SMALL_MODEL = "qwen2.5-coder:3b";
var LARGE_MODEL = "qwen2.5-coder:7b";
var gateModel = () => envString("PICODE_GATE", SMALL_MODEL);
function errorText(e) {
  const cause = e?.cause;
  return cause ? `${String(e)}: ${cause.code ?? cause.message ?? String(cause)}` : String(e);
}
function deadline(timeoutMs, signal) {
  const t = AbortSignal.timeout(timeoutMs);
  return signal ? AbortSignal.any([t, signal]) : t;
}

// dist/classify.js
var MIN_LABEL_MASS = 0.5;
var norm = (s) => s.trim().replace(/[^\p{L}\p{N}]+$/u, "").toUpperCase();
async function classifyLabels(prompt, labels, opts = {}) {
  const keys = Object.keys(labels);
  const bySurface = /* @__PURE__ */ new Map();
  for (const k of keys)
    bySurface.set(norm(labels[k]), k);
  if (bySurface.has("") || bySurface.size !== keys.length)
    return { ok: false, reason: "empty or colliding label surfaces" };
  try {
    const r = await (opts.fetchImpl ?? fetch)(`${endpoint()}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: opts.model ?? gateModel(),
        messages: [{ role: "user", content: prompt }],
        max_tokens: 1,
        temperature: 0,
        logprobs: true,
        top_logprobs: 20
      }),
      signal: deadline(envTimeoutMs("PICODE_GATE_TIMEOUT_MS", 8e3), opts.signal)
    });
    if (!r.ok) {
      const detail = (await r.text().catch(() => "")).slice(0, 200);
      return { ok: false, reason: `http ${r.status}${detail ? `: ${detail}` : ""}` };
    }
    const j = await r.json();
    const top = j?.choices?.[0]?.logprobs?.content?.[0]?.top_logprobs;
    if (!Array.isArray(top))
      return { ok: false, reason: "no top_logprobs in response" };
    const mass = {};
    for (const k of keys)
      mass[k] = 0;
    let total = 0;
    for (const cand of top) {
      const { token, logprob } = cand ?? {};
      if (typeof token !== "string" || typeof logprob !== "number" || !(logprob <= 0))
        continue;
      const k = bySurface.get(norm(token));
      if (k === void 0)
        continue;
      const p = Math.exp(logprob);
      mass[k] += p;
      total += p;
    }
    if (!(total >= MIN_LABEL_MASS))
      return { ok: false, reason: `label mass ${total.toFixed(2)} < ${MIN_LABEL_MASS}` };
    const probs = {};
    for (const k of keys)
      probs[k] = mass[k] / total;
    let label = keys[0];
    for (const k of keys)
      if (probs[k] > probs[label])
        label = k;
    return { ok: true, label, probs };
  } catch (e) {
    const name = e?.name;
    return { ok: false, reason: name === "TimeoutError" ? "timeout" : name === "AbortError" ? "aborted" : errorText(e) };
  }
}

// dist/route.js
var LABELS = { SIMPLE: "S", AGENTIC: "A" };
var DEFAULT_THRESHOLD = 0.46;
function routePrompt(task) {
  return `You are a fast router for a coding agent. Answer with a SINGLE letter and nothing else:
S = the task is to write ONE new self-contained function, file, or script FROM SCRATCH (no existing project code, no tools, no tests to run).
A = the task requires reading or editing EXISTING code, running commands or tests, debugging, or multiple dependent steps.
Task: ${task}
Answer (S or A):`;
}
function routeConfig() {
  const t = envNumber("PICODE_AGENTIC_THRESHOLD", DEFAULT_THRESHOLD);
  const b = envNumber("PICODE_ESCALATE_BAND", 0);
  return {
    gate: gateModel(),
    escalate: envString("PICODE_ESCALATE", LARGE_MODEL),
    threshold: t >= 0 && t <= 1 ? t : DEFAULT_THRESHOLD,
    band: b >= 0 && b <= 1 ? b : 0
  };
}
async function routeTask(task, opts = {}) {
  const { gate, escalate, threshold, band } = routeConfig();
  const prompt = routePrompt(task);
  const first = await classifyLabels(prompt, LABELS, { ...opts, model: gate });
  if (!first.ok)
    return { decision: "AGENTIC", escalated: false, ok: false, reason: first.reason };
  let pAgentic = first.probs.AGENTIC;
  let escalated = false;
  if (band > 0 && Math.abs(pAgentic - threshold) <= band) {
    const second = await classifyLabels(prompt, LABELS, { ...opts, model: escalate });
    if (!second.ok)
      return { decision: "AGENTIC", escalated: false, ok: false, reason: `escalation: ${second.reason}` };
    pAgentic = second.probs.AGENTIC;
    escalated = true;
  }
  return { decision: pAgentic >= threshold ? "AGENTIC" : "SIMPLE", escalated, ok: true, pAgentic };
}

// dist/codegen.js
var MAX_CODEGEN_TOKENS = 1024;
async function ollamaGenerate(prompt, opts) {
  const r = await fetch(`${endpoint()}/api/generate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: opts.model, prompt, stream: false, options: { temperature: 0, num_predict: MAX_CODEGEN_TOKENS } }),
    signal: deadline(opts.timeoutMs, opts.signal)
  });
  if (!r.ok) {
    const body = await r.text().catch(() => "");
    throw new Error(`ollama /api/generate ${r.status}: ${body.slice(0, 200)}`);
  }
  const j = await r.json().catch((e) => {
    throw e?.name === "TimeoutError" || e?.name === "AbortError" ? e : new Error("ollama /api/generate: invalid JSON", { cause: e });
  });
  if (typeof j?.response !== "string") {
    throw new Error(`ollama /api/generate: unexpected payload${j?.error ? `: ${String(j.error).slice(0, 200)}` : ""}`);
  }
  return j.response;
}
var LANGS = [
  [/\bpython\b|\.py\b/i, "python", "py"],
  [/\b(rust|rustlang|\.rs\b)\b/i, "rust", "rs"],
  [/\b(?:bash|zsh|shell script|sh script|posix sh)\b|\bin (?:sh|shell)\b/i, "bash", "sh"],
  [/\b(typescript|ts|\.ts\b)\b/i, "typescript", "ts"],
  [/\b(javascript|js|node\.?js|\.js\b)\b/i, "javascript", "js"],
  [/\b(?:golang|go (?:language|program|function|code|routine))\b|\bin go\b/i, "go", "go"],
  // A trailing \b can never follow the non-word chars in "c++"/"c#", so match
  // those symbol forms without it (word boundary only on the leading side).
  [/\bc\+\+|\bcpp\b/i, "cpp", "cpp"],
  [/\bc#|\bcsharp\b|\.cs\b/i, "csharp", "cs"],
  [/\b(?:ansi c|c (?:program|function|code|routine))\b|\bin c\b(?![+#])/i, "c", "c"],
  [/\b(java|\.java\b)\b/i, "java", "java"],
  [/\b(kotlin|\.kt\b)\b/i, "kotlin", "kt"],
  [/\b(ruby|\.rb\b)\b/i, "ruby", "rb"],
  [/\b(php|\.php\b)\b/i, "php", "php"],
  [/\b(swift|\.swift\b)\b/i, "swift", "swift"],
  [/\blua\b/i, "lua", "lua"],
  [/\bhaskell\b/i, "haskell", "hs"],
  [/\bscala\b/i, "scala", "scala"],
  [/\belixir\b/i, "elixir", "ex"],
  [/\bdart\b/i, "dart", "dart"],
  [/\bzig\b/i, "zig", "zig"],
  [/\bperl\b/i, "perl", "pl"],
  [/\b(?:sql|postgres(?:ql)?|sqlite|mysql) (?:query|queries|statement|script|schema|view)\b|\bin (?:sql|postgres(?:ql)?)\b/i, "sql", "sql"]
];
var NAMED_LANG_RE = /\b(?:an?|in|using) ([A-Z][a-z][\w+#]*)(?= (?:function|script|program)\b|\s*(?:[,;:!?]|\.?\s*$))/;
function detectLang(task) {
  let best;
  let at = Infinity;
  for (const [re, tag, ext] of LANGS) {
    const i = task.search(re);
    if (i >= 0 && i < at)
      [best, at] = [{ tag, ext }, i];
  }
  if (best)
    return best;
  const named = NAMED_LANG_RE.exec(task);
  return named ? { reason: `unsupported language '${named[1]}'` } : { tag: "python", ext: "py" };
}
var REFUSAL_RE = /^\s*(?:#|\/\/|--|;)?\s*(?:i (?:can'?t|cannot|am unable|won'?t|do not|don'?t)|i'?m (?:sorry|unable|afraid)|sorry|as an ai|unable to|cannot (?:help|assist)|there is no|no code|please provide|could you (?:clarify|provide))/i;
var CODE_TOKEN_RE = /[{}()=;]|=>|\b(?:def|class|import|from|return|for|while|if|lambda|fn|let|struct|impl|use|pub|mut|func|package|var|const|function|async|echo|print|printf)\b/;
var CODE_STRUCT_RE = /(?:^|\n)\s*(?:def |fn |func |function |class |struct |impl |interface |enum |public |private |protected |static |const |let |var |import |from |package |use |namespace |#include|#!|@\w)/;
var CODE_LINE_RE = /[;{}:)\]]$|^[}\])]|^[\w.[\]]+\s*[-+*/]?=\s*\S/;
function looksLikeCode(code) {
  if (CODE_STRUCT_RE.test(code))
    return true;
  const lines = code.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0)
    return false;
  return lines.filter((l) => CODE_LINE_RE.test(l)).length / lines.length >= 0.5;
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

// dist/stages/pi-helpers.js
function safeNotify(ctx, msg, level) {
  try {
    ctx.ui.notify(msg, level);
  } catch {
  }
}
function messageText(m) {
  const content = m?.content ?? "";
  if (typeof content === "string")
    return content;
  return content.flatMap((b) => b.type === "text" && typeof b.text === "string" ? [b.text] : []).join("\n");
}

// dist/stages/router.js
var CODEGEN_TIMEOUT_MS = envTimeoutMs("PICODE_CODEGEN_TIMEOUT_MS", 3e4);
var MAX_TASK_CHARS = envNumber("PICODE_MAX_TASK_CHARS", 4e3);
var CODER = envString("PICODE_CODER", SMALL_MODEL);
var MAX_INLINE_CODE_CHARS = 1500;
function fastPathTask(event) {
  if (event.source === "extension")
    return;
  if (event.streamingBehavior)
    return;
  if (event.images?.length)
    return;
  const task = event.text.trim();
  if (!task || task.startsWith("/"))
    return;
  if (task.length > MAX_TASK_CHARS)
    return;
  return task;
}
function writeFirstNew(paths, data) {
  let firstError;
  for (const path of paths) {
    try {
      writeFileSync(path, data, { flag: "wx", mode: 384 });
      return { path, firstError };
    } catch (e) {
      firstError ??= e.code ?? String(e);
    }
  }
  return { firstError };
}
var RETRYABLE = /* @__PURE__ */ new Set(["EAGAIN", "EWOULDBLOCK", "ENOBUFS"]);
var SLEEP = new Int32Array(new SharedArrayBuffer(4));
function writeFd1(buf) {
  let off = 0;
  for (let retries = 0; off < buf.length; ) {
    try {
      off += writeSync(1, buf, off);
    } catch (e) {
      if (!RETRYABLE.has(e.code ?? "") || ++retries > 100)
        break;
      Atomics.wait(SLEEP, 0, 0, 10);
    }
  }
  return off;
}
function deliver(pi, ctx, code, tag, ext) {
  const name = `picode_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.${ext}`;
  const { path, firstError } = writeFirstNew([resolve(ctx.cwd ?? "", envString("PICODE_OUT", name)), join(tmpdir(), name)], code + "\n");
  const inline = !path && ctx.hasUI && code.length <= MAX_INLINE_CODE_CHARS;
  if (!path && !inline)
    return false;
  const block = "```" + tag + "\n" + code + "\n```";
  const where = path ? `wrote ${path}${firstError ? ` (first choice unusable: ${firstError})` : ""}` : "shown inline";
  const mode = ctx.mode;
  if (path && (mode === "print" || mode === void 0 && !ctx.hasUI)) {
    if (mode === void 0 || writeFd1(Buffer.from(`${where}
${block}
`)) === 0) {
      try {
        unlinkSync(path);
      } catch {
      }
      return false;
    }
  }
  if (inline) {
    try {
      ctx.ui.notify(code, "info");
    } catch {
      return false;
    }
  }
  try {
    pi.sendMessage({ customType: "harness-fastpath", content: block, display: true }, { triggerTurn: false });
  } catch {
  }
  safeNotify(ctx, `[stage1] fast path done (${where})`, "info");
  return true;
}
async function generate(ctx, task, tag) {
  const status = (text) => {
    try {
      ctx.ui.setStatus("pi-harness", text);
    } catch {
    }
  };
  status("fast path: generating code");
  try {
    const resp = await ollamaGenerate(codegenPrompt(task, tag), { model: CODER, timeoutMs: CODEGEN_TIMEOUT_MS, signal: ctx.signal });
    return extractFencedCode(resp);
  } finally {
    status(void 0);
  }
}
function router_default(pi) {
  pi.on("input", async (event, ctx) => {
    try {
      const task = fastPathTask(event);
      if (task === void 0)
        return { action: "continue" };
      const route = await routeTask(task, { signal: ctx.signal });
      safeNotify(ctx, `[stage1] route: ${route.decision} (${route.ok ? `p_agentic=${route.pAgentic.toFixed(2)}` : `no-signal: ${route.reason}`})`, route.ok ? "info" : "warning");
      if (route.decision === "AGENTIC")
        return { action: "continue" };
      const lang = detectLang(task);
      if ("reason" in lang) {
        safeNotify(ctx, `[stage1] ${lang.reason}; full loop`, "info");
        return { action: "continue" };
      }
      let code;
      try {
        code = await generate(ctx, task, lang.tag);
      } catch (e) {
        safeNotify(ctx, `[stage1] fast path failed (${errorText(e)}); full loop`, "warning");
        return { action: "continue" };
      }
      if (!code) {
        safeNotify(ctx, "[stage1] no fenced code returned; full loop", "warning");
        return { action: "continue" };
      }
      return deliver(pi, ctx, code, lang.tag, lang.ext) ? { action: "handled" } : { action: "continue" };
    } catch (e) {
      safeNotify(ctx, `[stage1] error (${errorText(e)}); full loop`, "warning");
      return { action: "continue" };
    }
  });
}

// dist/complexity.js
var LABELS2 = { small: "1", medium: "2", large: "3" };
function complexityPrompt(task) {
  return `Rate how hard this coding task is for a small language model to solve correctly in one shot. Answer with a SINGLE digit and nothing else:
1 = trivial: a short well-known function (absolute value, maximum of three numbers, repeating a string).
2 = moderate: a standard algorithm or data structure, or a function with a few edge cases.
3 = hard: concurrency, subtle correctness, parsers, multiple interacting pieces, or tricky invariants.
Task: ${task}
Answer (1, 2, or 3):`;
}
function classifyComplexity(task, opts = {}) {
  return classifyLabels(complexityPrompt(task), LABELS2, opts);
}
function modelForTier(tier) {
  if (tier === "small")
    return envString("PICODE_MODEL_SMALL", SMALL_MODEL);
  return envString(tier === "medium" ? "PICODE_MODEL_MEDIUM" : "PICODE_MODEL_LARGE", LARGE_MODEL);
}

// dist/stages/model-tier.js
var PROVIDER = envString("PICODE_PROVIDER", "ollama");
var SMALL = modelForTier("small");
function resolve2(ctx, id, errors) {
  try {
    const m = ctx.modelRegistry.find(PROVIDER, id);
    return m && ctx.modelRegistry.hasConfiguredAuth(m) ? m : void 0;
  } catch (e) {
    errors.push(String(e));
    return void 0;
  }
}
function model_tier_default(pi) {
  pi.registerVirtualModel({
    provider: "harness",
    id: "auto",
    name: "Auto (harness)",
    async route(request, ctx) {
      let desiredId = SMALL;
      let sticky = false;
      if (request.reason !== "direct" && request.state) {
        desiredId = request.state.model;
        sticky = true;
      } else if (request.reason === "user") {
        const task = messageText(request.messages.filter((m) => m.role === "user").at(-1)).slice(0, 16e3);
        const r = await classifyComplexity(task, { signal: request.signal });
        if (r.ok) {
          desiredId = modelForTier(r.label);
          sticky = true;
        } else if (!request.signal?.aborted) {
          safeNotify(ctx, `[stage2] complexity no-signal (${r.reason}); using '${SMALL}'`, "warning");
        }
      }
      const retryingChoice = request.reason === "retry" && request.failed?.model.id === desiredId;
      const candidates = [...new Set(retryingChoice ? [SMALL] : [desiredId, SMALL])];
      const errors = [];
      for (const id of candidates) {
        const m = resolve2(ctx, id, errors);
        if (!m)
          continue;
        if (retryingChoice)
          safeNotify(ctx, `[stage2] '${desiredId}' failed; retrying on '${id}'`, "warning");
        else if (id !== desiredId)
          safeNotify(ctx, `[stage2] model '${desiredId}' unavailable (provider=${PROVIDER}); using '${id}'`, "warning");
        const state = !sticky || retryingChoice || request.state?.model === id ? request.state : { model: id };
        return { model: m, thinkingLevel: request.thinkingLevel, state };
      }
      const tried = `provider=${PROVIDER}, tried ${candidates.map((c) => `'${c}'`).join(", ")}${errors.length ? `; registry error: ${errors[0]}` : ""}`;
      if (request.previous?.model) {
        safeNotify(ctx, `[stage2] no model resolved (${tried}); keeping current model`, "warning");
        return { model: request.previous.model, thinkingLevel: request.thinkingLevel, state: request.state };
      }
      const msg = `[stage2] no configured model resolved (${tried}); check PICODE_PROVIDER/PICODE_MODEL_* and provider auth`;
      safeNotify(ctx, msg, "error");
      throw new Error(msg);
    }
  });
}

// dist/index.js
function index_default(pi) {
  router_default(pi);
  if (typeof pi.registerVirtualModel === "function") {
    try {
      model_tier_default(pi);
    } catch (e) {
      console.error(`[stage2] disabled: ${String(e)}`);
    }
  }
}
export {
  index_default as default
};
