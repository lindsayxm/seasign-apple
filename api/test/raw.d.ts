// Vite's `?raw` suffix imports a file's text. Used for the feed and page fixtures.
declare module "*.xml?raw" {
  const text: string;
  export default text;
}
declare module "*.html?raw" {
  const text: string;
  export default text;
}
