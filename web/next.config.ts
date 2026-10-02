import type { NextConfig } from "next";

// The browser only ever talks to this app. Requests to /api/* are passed to
// the backend (the `api` service), so there is one origin, no CORS, and the
// backend never has to be reachable from outside the machine.
const API_URL = process.env.API_URL ?? "http://localhost:8000";

const config: NextConfig = {
  async rewrites() {
    return [{ source: "/api/:path*", destination: `${API_URL}/:path*` }];
  },
};

export default config;
