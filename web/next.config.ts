import type { NextConfig } from "next";

// The browser only ever talks to this app. Requests to /api/* are passed to
// the backend (the `api` service), so there is one origin, no CORS, and the
// backend never has to be reachable from outside the machine.
const API_URL = process.env.API_URL ?? "http://localhost:8000";

// The browser demo (npm run build:demo) is plain files for GitHub Pages: no
// server, no backend, the database in the visitor's tab (lib/demo/backend.ts).
const DEMO = process.env.NEXT_PUBLIC_DEMO === "1";
const BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

const config: NextConfig = DEMO
  ? { output: "export", basePath: BASE_PATH || undefined, images: { unoptimized: true } }
  : {
      // "Have the AI read it" can take a minute or two; the proxy's default is 30 seconds.
      experimental: { proxyTimeout: 300_000 },
      async rewrites() {
        return [{ source: "/api/:path*", destination: `${API_URL}/:path*` }];
      },
    };

export default config;
