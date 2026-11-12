// ClawRouter's local scorer on a list of prompts: reads a JSON array of prompts on stdin, writes a JSON object
// with one score per prompt and the nanoseconds a decision took. It runs beside ClawRouter's node_modules.
import { classifyByRules, DEFAULT_ROUTING_CONFIG, estimateTokens } from "@blockrun/clawrouter/router";

const prompts = JSON.parse(await new Response(process.stdin).text());
const scoreOf = (p) => classifyByRules(p, undefined, estimateTokens(p), DEFAULT_ROUTING_CONFIG.scoring).score;
scoreOf(prompts[0]);
const t = process.hrtime.bigint();
const scores = prompts.map(scoreOf);
const ns = Number(process.hrtime.bigint() - t) / prompts.length;
process.stdout.write(JSON.stringify({ scores, ns }));
