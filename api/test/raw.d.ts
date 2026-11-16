// Vite's `?raw` suffix imports a file's text. Used for the feed and page fixtures.
declare module "*.xml?raw" {
  const text: string;
  export default text;
}
// Used by test/rate-limit.test.ts to read api/wrangler.jsonc.
declare module "*.jsonc?raw" {
  const text: string;
  export default text;
}
declare module "*.html?raw" {
  const text: string;
  export default text;
}
