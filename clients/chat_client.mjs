// N chat calls on one kept connection through a JavaScript client library, checked and summed the way the load
// tool does. Usage: node chat_client.mjs vercel-ai|tokenjs|tanstack-ai|pi-ai URL N [--stream]
// URL is the stand-in's base, such as http://127.0.0.1:9000/v1. The script is copied beside the node_modules
// folder that holds the libraries before it runs, since some of them can only be imported by name.
const [lib, base, count] = process.argv.slice(2);
const n = Number(count);
const stream = process.argv.includes("--stream");
const key = process.env.LLM_KEY || "local";
const load = (name) => import(name);
const MASK = (1n << 64n) - 1n;
const fnv = (text) => {
  let h = 0xcbf29ce484222325n;
  for (const b of Buffer.from(text)) h = ((h ^ BigInt(b)) * 0x100000001b3n) & MASK;
  return h;
};

const tImport = performance.now();
let call;
if (lib === "vercel-ai") {
  const { generateText, streamText } = await load("ai");
  const { createOpenAICompatible } = await load("@ai-sdk/openai-compatible");
  const model = createOpenAICompatible({ name: "standin", baseURL: base, apiKey: key })("mock");
  call = async (i) => {
    if (!stream) return (await generateText({ model, prompt: `call ${i}`, maxRetries: 0 })).text;
    let text = "";
    for await (const piece of streamText({ model, prompt: `call ${i}`, maxRetries: 0 }).textStream) text += piece;
    return text;
  };
} else if (lib === "tokenjs") {
  const { TokenJS } = await load("token.js");
  const client = new TokenJS({ baseURL: base, apiKey: key });
  call = async (i) => {
    const r = await client.chat.completions.create({ provider: "openai-compatible", model: "mock", messages: [{ role: "user", content: `call ${i}` }], stream });
    if (!stream) return r.choices[0].message.content;
    let text = "";
    for await (const c of r) text += c.choices?.[0]?.delta?.content || "";
    return text;
  };
} else if (lib === "tanstack-ai") {
  const { chat } = await load("@tanstack/ai");
  const { createOpenaiChatCompletions } = await load("@tanstack/ai-openai");
  const adapter = createOpenaiChatCompletions("mock", key, { baseURL: base });
  call = async (i) => {
    const r = chat({ adapter, threadId: `arena-${i}`, messages: [{ role: "user", content: `call ${i}` }], stream });
    if (!stream) return (await r).text;
    let text = "";
    for await (const c of r) if (c.type === "TEXT_MESSAGE_CONTENT" || c.type === "content") text += c.delta || "";
    return text;
  };
} else if (lib === "pi-ai") {
  const { complete, stream: piStream } = await load("@mariozechner/pi-ai");
  const model = { id: "mock", name: "mock", api: "openai-completions", provider: "standin", baseUrl: base, reasoning: false, input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 32000 };
  call = async (i) => {
    const context = { messages: [{ role: "user", content: `call ${i}` }] };
    if (!stream) return (await complete(model, context, { apiKey: key })).content.filter((p) => p.type === "text").map((p) => p.text).join("");
    let text = "";
    for await (const event of piStream(model, context, { apiKey: key })) if (event.type === "text_delta") text += event.delta;
    return text;
  };
} else {
  console.error(`no library ${lib}`);
  process.exit(2);
}
const importMs = performance.now() - tImport;

let ok = 0, bad = 0, total = 0n;
const lat = [];
const t0 = performance.now();
for (let i = 0; i < n; i++) {
  const t = performance.now();
  const text = String(await call(i));
  lat.push((performance.now() - t) * 1000);
  if (text.startsWith(`echo: call ${i}`)) ok++; else bad++;
  total ^= (fnv(text) * BigInt(i + 1)) & MASK;
}
const s = (performance.now() - t0) / 1000;
console.log(`ok ${ok}\nbad ${bad}\nchecksum ${total.toString(16).padStart(16, "0")}`);
lat.sort((a, b) => a - b);
console.error(`metric calls_per_s=${(n / s).toFixed(1)}\nmetric p50_us=${lat[lat.length >> 1].toFixed(0)}\nmetric import_ms=${importMs.toFixed(1)}`);
process.exit(bad ? 1 : 0);
