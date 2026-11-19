// The Worker's secrets (npx wrangler secret put NAME), next to the bindings and vars that `npm run types` generates
// from wrangler.jsonc. Without ANTHROPIC_API_KEY the show agent runs in mock mode.
interface Env {
  SHOW_AGENT_KEY: string;
  TURNSTILE_SECRET: string;
  IP_SALT: string;
  ANTHROPIC_API_KEY?: string;
}
