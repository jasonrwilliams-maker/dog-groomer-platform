// True in the browser demo build (npm run build:demo): the screens talk to a
// Postgres running in the visitor's own tab (lib/demo/backend.ts) instead of
// the shop's backend, and the parts that need a server are left out.
export const DEMO = process.env.NEXT_PUBLIC_DEMO === "1";
